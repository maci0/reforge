# ReForge OTA / release channel — design

**Status:** Design (approved in brainstorming 2026-06-01)
**Depends on:** P1–P3 (core stack builds/boots/serves in qemu). Independent of Plan 4 (MCU)
and Plan 5 (mainline image).

## Goal

In-place, **git-free** over-the-air updates of the ReForge application + overlay layer, using
Moonraker's `update_manager` against **self-published prebuilt release bundles**. The device
ships no `git`, no `pip`, no compiler; updates must work with none of them.

## Why git is out

Established this session (see `docs/BACKLOG.md`): Moonraker's `git_repo` updater shells out to
the full `git` CLI (clone/fetch/checkout/reset/describe/rev-parse/rev-list/for-each-ref/
cat-file/merge-base/fsck/…, incl. `--filter=blob:none` partial clone). Even shipping git
wouldn't enable host OTA on a buildroot image: `/opt/*` aren't git checkouts, there's no `pip`
for Moonraker deps, and no `gcc` (klipper's chelper recompiles when `chelper.c` is newer than
the `.so`). The clean path is **`zip`/`web` updaters against our own prebuilt artifacts**,
which need only Moonraker's HTTP client + stdlib `zipfile`.

## Scope

**OTA-able** (all under the writable `/data/.reforge` chroot; kernel stays fixed so loadable
modules remain vermagic-valid):
- `/opt/klipper`, `/opt/moonraker`, `/opt/guppyscreen` (prebuilt, klipper incl. its built
  `c_helper.so` so the gcc-less device never recompiles)
- ReForge overlay: init scripts, `/etc/reforge/*.conf`, the fire/ember banner, boot hook
- zram `.ko` + `swapon_prio` (loadable modules in mod space, insmod'd at boot)
- `/var/www/mainsail` (upstream `web` updater)

**`.tgz` reflash only (policy, not a filesystem limit):** base rootfs (busybox/glibc), kernel,
U-Boot. In-place libc/busybox/kernel swaps under a running system are unsafe; a base/kernel
change ships as a full USB `.tgz`.

## Three independent layers

| layer | design |
|---|---|
| **source/patches** | the `reforge` repo: pin upstream by commit (`pins.lock`) + small `.patch` series (klipper 2, guppyscreen 3, moonraker/mainsail vanilla). **No component forks** — YAGNI until a patch series grows large; promote a single component then. |
| **release artifacts** | one repo `maci0/reforge`. One version tag = one GitHub Release carrying N zip assets + the USB `.tgz`. Atomic lockstep version. |
| **device** | per-component `[update_manager X]` (forge-x shape): `zip` for our components, `web` for Mainsail. |

## Device — `[update_manager]` config

`[update_manager]` core: `enable_auto_refresh: False`, `enable_system_updates: False`
(manual updates, like forge-x).

| component | type | asset_name | path | payload |
|---|---|---|---|---|
| `klipper` | zip | `klipper.zip` | `/opt/klipper` | upstream + patches **+ `c_helper.so`** |
| `moonraker` | zip | `moonraker.zip` | `/opt/moonraker` | upstream |
| `guppyscreen` | zip | `guppyscreen.zip` | `/opt/guppyscreen` | prebuilt LVGL binary |
| `reforge` | zip | `reforge.zip` | mod home (e.g. `/data/.reforge/mod`) | init scripts, `/etc/reforge`, zram `.ko` + `swapon_prio`, banner, boot hook |
| `mainsail` | web | — | `/var/www/mainsail` | upstream `mainsail-crew/mainsail` |

All `zip` components set `repo: maci0/reforge` and a distinct `asset_name`, so they resolve the
same `releases/latest` → identical version → atomic. Each zip carries **`release_info.json`**
at its path root with **all four** keys `{project_name, project_owner, version, asset_name}`
(verified against `net_deploy.py:114-118` — a missing `project_owner` throws and marks the
install invalid, making the component permanently un-updatable). For `zip` components Moonraker
reads the current version from `release_info.json` (not `.version`). The config `repo:` must
equal `project_owner/project_name` or the updater logs a repo-mismatch anomaly
(`net_deploy.py:124-132`). `persistent_files` per component preserves anything that must
survive an update (user configs live in `printer_data`, outside these paths).

## Apply model — all reboot-to-apply

Moonraker runs with `provider: none` (no systemd; there is **no init.d/sysv service provider**
in Moonraker — only `systemd_cli`/`supervisord_cli`, `machine.py:111-116`). So Moonraker
**cannot restart any service** — `do_service_action` raises `503` for all of them
(`machine.py:959-963`), klipper included (the zip updater has **no** `FIRMWARE_RESTART` path; it
calls `managed_services` restart, which 503s). Therefore **every component applies on the next
reboot**, where the new version boots under the trial/LKG guard. This is uniform and safer than
live-swapping init/overlay. (Optional future optimization, out of scope here: a Moonraker
post-update hook could issue a Klipper `FIRMWARE_RESTART` over `/tmp/klippy_uds` to apply klipper
without a reboot — but the baseline is reboot-to-apply for all.)

## Overlay deploy step (the `reforge` component)

`/opt/{klipper,moonraker,guppyscreen}` run directly from their paths, so Moonraker's extract
makes them live on reboot with no extra step. The **`reforge` component is different**:
Moonraker extracts it to a staging dir `/data/.reforge/mod` (it `rmtree`s + re-extracts only
`self.path`, `net_deploy.py:325-350` — it never writes to `/etc/init.d` or `/etc/reforge`). So
`mod/` is the **source of truth**, and **`reforge-boot` deploys it into the live chroot** early
each boot, before running the S-scripts:
- `mod/etc/init.d/*` → chroot `/etc/init.d/` (the live S-scripts)
- `mod/etc/reforge/*` → chroot `/etc/reforge/` (default configs; user overrides in `printer_data` untouched)
- `mod/modules/*.ko` + `swapon_prio` stay in `mod/` (S35zram insmods them from there)
Deploy is an idempotent mirror (rsync-style copy) gated by the trial logic below.

## Safety — boot LKG is the rollback

Moonraker's built-in rollback is **unreliable for our multi-asset single-release design**: its
rollback always grabs `assets[0]` ignoring `asset_name` (`net_deploy.py:481`), so rolling back
one component could fetch another's zip. We therefore do **not** rely on it; the **boot LKG is
the rollback mechanism**, and it also covers the case Moonraker can't (a broken init/overlay
that prevents Moonraker from even starting).

**Integrity / trust model:** the `zip`/`web` updater performs **no** content hash/signature
check — it validates only the HTTP status (`http_client.py:243-279`); a truncated-but-200 asset
extracts silently. This matches the entire Klipper-ecosystem updater (no mod verifies asset
content). OTA therefore trusts **GitHub's TLS transport + the asset bytes**, with the **boot
trial/LKG as the corruption-and-breakage backstop** (a corrupt/bad update fails the trial boot
and is rolled back). No custom manifest verification — YAGNI given the LKG net.

**Boot trial / LKG mechanism (precise):**
- **State dir** `/data/.reforge/state/` on writable `/data`. Counter file `trial.count` written
  atomically (write temp + `rename`) to survive power-cuts.
- **LKG** = `/data/.reforge/lkg/` — a copy of the last `mod/` that reached services-up.
- `reforge-boot` flow (early, before deploy + chroot):
  1. If a `SKIP_MOD` marker is present → boot stock; **do not touch trial state** (orthogonal).
  2. New-update detection: if `mod/release_info.json` version ≠ `lkg/release_info.json` version,
     this is a **trial boot**. Increment `trial.count` **atomically before deploying** (so a
     brick during deploy/boot is counted).
  3. If `trial.count ≥ N` (**N = 3**): the new `mod` is failing → **restore LKG** (atomic:
     `mv mod mod.bad`; `cp -a lkg mod`), reset `trial.count = 0`, continue booting LKG.
  4. Deploy `mod` → live chroot dirs; exec the S-script chain.
- **Services-up sentinel = a single `S99ok` script** (the last init script, after
  klipper/moonraker/httpd/guppyscreen have started). On reaching it: **promote** current `mod`
  → `lkg` (atomic: `cp -a mod lkg.new && rm -rf lkg && mv lkg.new lkg`) and reset
  `trial.count = 0`. One sentinel, not two.
- `SKIP_MOD` is the final manual escape (boot stock entirely); it never counts as a trial
  failure and never resets the counter.

**Error handling:** download failure → Moonraker aborts, keeps current `mod`; corrupt or
boot-breaking update → trial fails → LKG restore; total wedge → `SKIP_MOD`.

## CI release pipeline

A `tools/release/build-release.sh` (runnable locally + from CI) holds the slicing logic; CI
calls it. On a version-tag push to `maci0/reforge`:

1. Checkout (submodules), `./vendor/fetch.sh`, `make rootfs` → `build/output`.
2. Slice `target/` into per-component trees, zip each:
   `klipper.zip`←`target/opt/klipper`, `moonraker.zip`←`target/opt/moonraker`,
   `guppyscreen.zip`←`target/opt/guppyscreen`, `reforge.zip`← the reforge mod files
   (overlay init scripts, `/etc/reforge`, `modules/zram-bsp/dist/*.ko` + `swapon_prio`, banner, hook).
3. Inject `release_info.json` with all four keys
   `{project_name, project_owner:"maci0", version:<tag>, asset_name}` at each zip root.
4. `make tgz` → `reforge-<ver>.tgz` (full base, USB flash).
5. **Publish as draft, upload all assets, then flip to published** (`gh release create <tag>
   --draft` → upload → `gh release edit <tag> --draft=false`). This avoids the race where a
   device refreshes after the tag is visible but before the last asset finishes uploading
   (the updater would find the tag, fail the asset lookup, and abort — `net_deploy.py:291-292`).

Cost: buildroot-from-scratch in CI (~30–60 min) — mitigate with buildroot dl-dir + ccache
caching. Deterministic via `pins.lock`.

## Testing (qemu, no device)

1. **Release-builder unit test** (host): run `build-release.sh` against `build/output`; assert
   the 4 zips + `.tgz` exist; unzip and verify structure + the injected `release_info.json`
   (all four keys) (`klipper.zip` has `c_helper.so`; `reforge.zip` has the `.ko` + init scripts).
   CI-friendly.
2. **End-to-end OTA** (`tests/qemu-harness/ota-test.sh`): boot the full rootfs with the
   `update_manager` config under the virt kernel + virtio-net; seed an **older
   `release_info.json` version** in each zip-component path; drive `POST /machine/update/<component>`;
   assert download → extract → the path's `release_info.json` version bumps (via
   `GET /machine/update/status`). **All components reboot-to-apply** (provider:none cannot
   restart services), so the test asserts the files + version updated, then validates a reboot
   into the new version. Backed by a
   **local mock of the GitHub releases API** (serves `releases/latest` JSON + zip assets via an
   `/etc/hosts` override) for offline CI; a real published test release is the opt-in authentic check.
3. **Boot LKG / rollback test** (critical): inject a broken `reforge.zip` (init script that
   fails/hangs) → apply → reboot → assert the trial counter fires → LKG restored → good version boots.
4. **Mainsail web updater**: assert `/var/www/mainsail/manifest.json` (with `name: mainsail`)
   is present — the `web` updater's version detection reads it (`net_deploy.py:160-191`); without
   it, detection silently fails — then assert Moonraker resolves the upstream `mainsail-crew`
   latest + the dry-run update path.

## Components / files (new)

- `tools/release/build-release.sh` — slice `build/output` → per-component zips + `release_info.json` + `.tgz`; publish via `gh`.
- `.github/workflows/release.yml` — tag-triggered, calls `build-release.sh`.
- `br-external/package/moonraker/moonraker.conf` — add the `[update_manager]` block.
- `br-external/board/reforge/rootfs-overlay/.shell/reforge-boot` — add the **overlay deploy
  step** (mirror `mod/` → live `/etc/init.d` + `/etc/reforge`) + the **trial/LKG logic** (atomic
  `state/trial.count`, new-update detection via `release_info.json` version, N=3, restore-LKG).
- `S99ok` init script (services-up sentinel) — promotes `mod`→`lkg` + resets the counter.
- `tests/qemu-harness/ota-test.sh` + the local mock release server.

## Out of scope (this spec)

MCU firmware version coupling (Plan 4) — OTA of the klipper *host* assumes the running MCU
firmware stays compatible; mixed host/MCU versions are a Plan 4 concern. Mainline kernel/U-Boot
OTA (Plan 5) — kernel changes ship via `.tgz`, never OTA.
