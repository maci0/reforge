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
same `releases/latest` → identical version → atomic. Each zip carries `release_info.json`
(`{project_name, version, asset_name}`) + `.version` at its path root for current-vs-latest.
`persistent_files` per component preserves anything that must survive an update (user configs
live in `printer_data` and are not in these paths).

## Apply model

Moonraker runs with `provider: none` (no systemd) → it **cannot live-restart** services. So:
- **klipper** applies live via the klippy socket (`FIRMWARE_RESTART`).
- **moonraker / guppyscreen / reforge overlay** → files written, **applied on reboot**, where
  the new version boots under the trial/LKG guard (below). Safer than a live swap for init/overlay.

## Safety — two tiers

1. **App rollback (Moonraker built-in):** Moonraker keeps the prior downloaded version;
   `rollback` reverts klipper/moonraker/guppyscreen. For "update applied but regressed."
2. **Boot last-known-good (LKG) — ours, for overlay/init brick risk:**
   - Before an overlay-affecting update, snapshot mod state → `/data/.reforge/lkg`.
   - On reboot, `reforge-boot` sets a **trial flag + boot counter**. Reaching *services-up*
     (sentinel: Moonraker binds `:7125`, or an `S99ok` marker) **clears trial + promotes
     current → LKG**.
   - If N consecutive boots fail to reach services-up → **restore LKG** and boot it.
   - `SKIP_MOD` USB marker remains the final escape hatch (boot stock entirely).

**Error handling:** download failure / sha mismatch → Moonraker aborts, keeps current; broken
boot → LKG restore; total wedge → SKIP_MOD.

## CI release pipeline

A `tools/release/build-release.sh` (runnable locally + from CI) holds the slicing logic; CI
calls it. On a version-tag push to `maci0/reforge`:

1. Checkout (submodules), `./vendor/fetch.sh`, `make rootfs` → `build/output`.
2. Slice `target/` into per-component trees, zip each:
   `klipper.zip`←`target/opt/klipper`, `moonraker.zip`←`target/opt/moonraker`,
   `guppyscreen.zip`←`target/opt/guppyscreen`, `reforge.zip`← the reforge mod files
   (overlay init scripts, `/etc/reforge`, `modules/zram-bsp/dist/*.ko` + `swapon_prio`, banner, hook).
3. Inject `release_info.json` (`version:<tag>`) + `.version` at each zip root.
4. `make tgz` → `reforge-<ver>.tgz` (full base, USB flash).
5. `gh release create <tag>` with all assets.

Cost: buildroot-from-scratch in CI (~30–60 min) — mitigate with buildroot dl-dir + ccache
caching. Deterministic via `pins.lock`.

## Testing (qemu, no device)

1. **Release-builder unit test** (host): run `build-release.sh` against `build/output`; assert
   the 4 zips + `.tgz` exist; unzip and verify structure + injected `release_info.json`/`.version`
   (`klipper.zip` has `c_helper.so`; `reforge.zip` has the `.ko` + init scripts). CI-friendly.
2. **End-to-end OTA** (`tests/qemu-harness/ota-test.sh`): boot the full rootfs with the
   `update_manager` config under the virt kernel + virtio-net; seed an older `.version`; drive
   `POST /machine/update/<component>`; assert download → extract → `.version` bump (via
   `GET /machine/update/status`); klipper live-restart, others reboot-to-apply. Backed by a
   **local mock of the GitHub releases API** (serves `releases/latest` JSON + zip assets via an
   `/etc/hosts` override) for offline CI; a real published test release is the opt-in authentic check.
3. **Boot LKG / rollback test** (critical): inject a broken `reforge.zip` (init script that
   fails/hangs) → apply → reboot → assert the trial counter fires → LKG restored → good version boots.
4. **Mainsail web updater**: assert Moonraker detects the upstream `mainsail-crew` latest + the
   dry-run update path resolves.

## Components / files (new)

- `tools/release/build-release.sh` — slice `build/output` → per-component zips + `release_info.json` + `.tgz`; publish via `gh`.
- `.github/workflows/release.yml` — tag-triggered, calls `build-release.sh`.
- `br-external/package/moonraker/moonraker.conf` — add the `[update_manager]` block.
- `br-external/board/reforge/rootfs-overlay/.shell/reforge-boot` — add trial/LKG boot logic.
- A small services-up sentinel (e.g. `S99ok`) + the LKG snapshot/restore helper.
- `tests/qemu-harness/ota-test.sh` + the local mock release server.

## Out of scope (this spec)

MCU firmware version coupling (Plan 4) — OTA of the klipper *host* assumes the running MCU
firmware stays compatible; mixed host/MCU versions are a Plan 4 concern. Mainline kernel/U-Boot
OTA (Plan 5) — kernel changes ship via `.tgz`, never OTA.
