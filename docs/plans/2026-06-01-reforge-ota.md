# ReForge OTA / Release Channel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Git-free in-place OTA of the ReForge app + overlay layer via Moonraker's `update_manager`, fed by self-published prebuilt release bundles, with a boot last-known-good safety net.

**Architecture:** CI builds the rootfs (buildroot) and slices it into per-component zips (`klipper`, `moonraker`, `guppyscreen`, `reforge`) each carrying a 4-key `release_info.json`, published as one multi-asset GitHub Release on `maci0/reforge`. The device's Moonraker `update_manager` pulls each component's asset; `/opt/*` components go live on reboot, and the `reforge` component (init scripts + configs + zram `.ko`) is extracted to a staging `mod/` dir that `reforge-boot` deploys into the live chroot, guarded by a trial-boot + last-known-good (LKG) rollback.

**Tech Stack:** POSIX sh / bash, Buildroot, Moonraker `update_manager` (`zip`/`web` updaters), `qemu-system-arm` test harness, GitHub Actions + `gh` CLI.

**Spec:** `docs/specs/2026-06-01-reforge-ota-design.md` — read it first. Verify every `update_manager` claim against the Moonraker source at `build/output/target/opt/moonraker/moonraker/components/update_manager/` before relying on it.

---

## File Structure

| file | responsibility |
|---|---|
| `tools/release/build-release.sh` | **Create.** Slice `build/output/target` → per-component zips with 4-key `release_info.json`; build the USB `.tgz`; (CI) publish. Pure packaging, runnable locally. |
| `tools/release/release-info.sh` | **Create.** Tiny helper: emit a `release_info.json` given component name + version. Sourced/called by `build-release.sh`. DRY. |
| `.github/workflows/release.yml` | **Create.** Tag-triggered: build → `build-release.sh` → draft-then-publish via `gh`. |
| `br-external/package/moonraker/0001-add-simple-service-provider.patch` | **Create.** Port forge-x's `SimpleProvider` so `provider: simple` can live-restart init.d services. |
| `br-external/board/reforge/rootfs-overlay/.shell/reforge-boot` | **Modify.** chroot + exec the mod dir's init **in place** (no mirror) + trial/LKG logic. |
| mod-dir service-control scripts (`klipper`/`moonraker`/`guppyscreen`/`reforge`) | **Create.** Thin wrappers over the `Sxx` scripts, for `SimpleProvider`'s `script_path`. |
| `br-external/board/reforge/rootfs-overlay/.shell/reforge-lkg.sh` | **Create.** LKG helpers sourced by `reforge-boot`: `lkg_counter_get/inc/reset`, `lkg_promote`, `lkg_restore` (atomic). Keeps `reforge-boot` readable + unit-testable. |
| `br-external/board/reforge/rootfs-overlay/etc/init.d/S99ok` | **Create.** Services-up sentinel: on success, promote `mod`→`lkg` + reset counter. |
| `br-external/package/moonraker/moonraker.conf` | **Modify.** Add `[update_manager]` + per-component sections. |
| `br-external/board/reforge/post-build.sh` | **Modify.** Assemble the `mod/` staging tree in the image (so the device ships with `mod/` populated + an LKG seed). |
| `tests/release/build-release-test.sh` | **Create.** Host unit test for the release builder (no qemu). |
| `tests/release/lkg-unit-test.sh` | **Create.** Host unit test for `reforge-lkg.sh` (no qemu) — counter atomicity, promote/restore. |
| `tests/qemu-harness/mock-github-release.sh` | **Create.** Local mock of the GitHub releases API + asset server. |
| `tests/qemu-harness/ota-test.sh` | **Create.** qemu e2e: update a component + the critical LKG/rollback test. |

**Decomposition note:** the `mod/` staging layout (Task 3) is the structural keystone — every other piece depends on the device shipping a `mod/` source-of-truth that `reforge-boot` deploys. Do Task 3 before the trial/LKG (Task 4) and the e2e (Task 6).

---

## Task 1: Release builder — per-component zips + `release_info.json`

**Files:**
- Create: `tools/release/release-info.sh`
- Create: `tools/release/build-release.sh`
- Test: `tests/release/build-release-test.sh`

The builder slices `build/output/target` into four zips. Each zip's tree root gets a
`release_info.json` (4 keys) so Moonraker can read the current version on-device.

- [ ] **Step 1: Write `release-info.sh`** (the DRY helper)

```bash
# tools/release/release-info.sh
# emit_release_info <project_name> <version> <asset_name>  -> prints release_info.json
emit_release_info() {
    printf '{\n  "project_name": "%s",\n  "project_owner": "maci0",\n  "version": "%s",\n  "asset_name": "%s"\n}\n' \
        "$1" "$2" "$3"
}
```

- [ ] **Step 2: Write the failing test** `tests/release/build-release-test.sh`

The test runs the builder against the real `build/output` (skips with a clear message if absent) and asserts structure. Key assertions:

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$REPO/build/output/images/rootfs.tar" ] || { echo "SKIP: no build/output — run 'make rootfs'"; exit 0; }
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
VER=9.9.9 DIST_DIR="$OUT" "$REPO/tools/release/build-release.sh" --no-publish
for a in klipper moonraker guppyscreen reforge; do
    [ -f "$OUT/$a.zip" ] || { echo "FAIL: $a.zip missing"; exit 1; }
    # release_info.json must be at the ZIP ROOT (not nested in a wrapper dir, or the
    # component is silently invalid — net_deploy.py reads <path>/release_info.json)
    unzip -l "$OUT/$a.zip" | awk '{print $NF}' | grep -qx 'release_info.json' \
        || { echo "FAIL: $a.zip release_info.json not at zip root (nested wrapper?)"; exit 1; }
    # all 4 keys + correct version
    unzip -p "$OUT/$a.zip" release_info.json | grep -q '"project_owner": "maci0"' || { echo "FAIL: $a release_info missing project_owner"; exit 1; }
    unzip -p "$OUT/$a.zip" release_info.json | grep -q '"version": "9.9.9"' || { echo "FAIL: $a version wrong"; exit 1; }
done
# component payload spot-checks
unzip -l "$OUT/klipper.zip" | grep -q 'klippy/chelper/c_helper.so' || { echo "FAIL: klipper.zip missing c_helper.so"; exit 1; }
unzip -l "$OUT/reforge.zip" | grep -qE 'etc/init.d/S60klipper' || { echo "FAIL: reforge.zip missing init scripts"; exit 1; }
unzip -l "$OUT/reforge.zip" | grep -qE 'modules/zram\.ko|modules/.*zram\.ko' || { echo "FAIL: reforge.zip missing zram.ko"; exit 1; }
[ -f "$OUT"/reforge-9.9.9.tgz ] || { echo "FAIL: USB .tgz missing"; exit 1; }
echo "PASS: build-release"
```

- [ ] **Step 3: Run it — expect FAIL** (`build-release.sh` not created yet).

`Run: tests/release/build-release-test.sh` → Expected: FAIL ("build-release.sh: No such file") or SKIP if no build/output (build first with `make rootfs`).

- [ ] **Step 4: Write `build-release.sh`**

Behavior (full code in the implementer's hands; spec exactly):
- Args: `--no-publish` (default for local/tests) vs `--publish <tag>` (CI). `VER` env or `packaging/VERSION`. `DIST_DIR` env (default `packaging/dist`).
- Source `release-info.sh`.
- For each `/opt` component: stage `cp -a build/output/target/opt/<c> <stage>/<c>`, write `<stage>/<c>/release_info.json` via `emit_release_info <c> <VER> <c>.zip`, `(cd <stage>/<c> && zip -rq <DIST_DIR>/<c>.zip .)`. (klipper includes the already-built `klippy/chelper/c_helper.so` from the target — verify it's present, else `die`.)
- For `reforge`: stage the **mod tree** (the same layout Task 3 ships): `etc/init.d/*`, `etc/reforge/*`, `modules/*.ko` + `swapon_prio`, `usr/bin/reforge-banner`, `.shell/reforge-boot`, `.shell/reforge-lkg.sh`. Add `release_info.json`. Zip.
- `make tgz` (or call `packaging/build-tgz.sh`) → copy `reforge-<VER>.tgz` to `DIST_DIR`.
- If `--publish <tag>`: `gh release create <tag> --draft`, upload all assets, `gh release edit <tag> --draft=false` (the race fix from the spec).

- [ ] **Step 5: Run the test — expect PASS.** `Run: tests/release/build-release-test.sh` → Expected: `PASS: build-release` (or SKIP if no build).

- [ ] **Step 6: Commit**

```bash
git add tools/release/ tests/release/build-release-test.sh
git commit -m "ota: release builder — per-component zips + 4-key release_info"
```

---

## Task 2: Moonraker `SimpleProvider` patch + `[update_manager]` config

Follow forge-x: a `SimpleProvider` lets `provider: simple` restart init.d services live, so
updates apply without a reboot. Port forge-x's class (GPLv3; `forge-x/.root/moonraker/components/machine.py:1612`).

**Files:**
- Create: `br-external/package/moonraker/0001-add-simple-service-provider.patch`
- Modify: `br-external/package/moonraker/moonraker.mk` (add the patch to the patch list, if not auto-applied)
- Modify: `br-external/package/moonraker/moonraker.conf`

- [ ] **Step 1: Port `SimpleProvider`.** Create the patch adding to `machine.py`: a
  `SimpleProvider(BaseProvider)` whose `do_service_action(action, service_name)` runs
  `<script_path>/<service_name> <action>` via the shell command helper (mirror forge-x's ~42-line
  class), and register `"simple": SimpleProvider` in the `providers` dict. Buildroot auto-applies
  `br-external/package/moonraker/*.patch`; confirm via a rebuild.
- [ ] **Step 2: Rebuild + verify the provider exists AND is registered.** `make rootfs` (or
  rebuild just moonraker), then grep the built `machine.py` for **both** `class SimpleProvider`
  **and** the registration `"simple": SimpleProvider` in the `providers` dict (the class alone,
  unregistered, falls through to `Invalid Provider`). Expected: both present. (TDD: the greps are the test.)
- [ ] **Step 3: Add the config.** Set `[machine] provider: simple` (keep `validate_service:
  false`, `validate_config: false`). Append the `[update_manager]` block:

```ini
[update_manager]
enable_auto_refresh: False
enable_system_updates: False

[update_manager klipper]
type: zip
channel: stable
repo: maci0/reforge
path: /opt/klipper
managed_services: klipper
persistent_files:
    klippy/chelper/__pycache__

[update_manager moonraker]
type: zip
channel: stable
repo: maci0/reforge
path: /opt/moonraker
managed_services: moonraker

[update_manager guppyscreen]
type: zip
channel: stable
repo: maci0/reforge
path: /opt/guppyscreen
managed_services: guppyscreen

[update_manager reforge]
type: zip
channel: stable
repo: maci0/reforge
path: /data/.mod/.reforge/mod
managed_services: reforge

[update_manager mainsail]
type: web
channel: stable
repo: mainsail-crew/mainsail
path: /var/www/mainsail
```

Set `[machine] script_path: /mod/services` (the wrappers from Task 3). `asset_name` is read
from each path's `release_info.json` (not set here).

- [ ] **Step 3b: Seed `moonraker.asvc` (REQUIRED — else guppyscreen/reforge never restart).**
  `managed_services` only takes effect for services Moonraker *allows*: `is_service_allowed`
  auto-matches `klipper*`/`moonraker*` (regex) but **clears** any other name unless it's listed in
  `<data>/moonraker.asvc`. So `managed_services: klipper`/`moonraker` work, but `guppyscreen` and
  `reforge` would silently update-without-restart. Ship
  `br-external/board/reforge/rootfs-overlay/var/lib/moonraker/moonraker.asvc` (Moonraker's data dir
  is `-d /var/lib/moonraker`) containing one name per line: `klipper`, `moonraker`, `guppyscreen`,
  `reforge`. Verify on-device: `GET /machine/system_info` / the update flow restarts guppyscreen
  + reforge (covered by the Task 6 e2e).

- [ ] **Step 4: Validate it parses + paths resolve.** `Run: make integration` → Expected: still
  `PASS`. The `[update_manager]` paths are **chroot-relative** (Moonraker runs inside the
  `/data/.mod/.reforge` chroot), so `/opt/klipper`, `/opt/moonraker`, `/opt/guppyscreen`, `/mod` must
  exist at Moonraker's runtime root — `net_deploy`/`app_deploy` hard-fail config parse if a `path`
  is missing. Assert Moonraker starts and `GET /machine/update/status` lists all 5 updaters (no
  "path does not exist" error). Deeper update test in Task 6.
- [ ] **Step 5: Commit**

```bash
git add br-external/package/moonraker/
git commit -m "ota: moonraker SimpleProvider patch + [update_manager] (provider: simple)"
```

---

## Task 3: Self-contained `mod/` dir + run-init-in-place (forge-x style)

The keystone. Make the reforge-authored files a **self-contained dir** that IS the OTA path
(`/data/.mod/.reforge/mod`); `reforge-boot` chroots and runs the mod dir's init **in place** — no
mirror. A zip update of the dir is live on the next `SimpleProvider` restart/boot.

**Files:**
- Modify: `br-external/board/reforge/post-build.sh` (assemble the self-contained `mod/` + seed LKG)
- Create: mod-dir service-control scripts `klipper`/`moonraker`/`guppyscreen`/`reforge`
- Modify: `br-external/board/reforge/rootfs-overlay/.shell/reforge-boot` (chroot+exec mod init in place)

**The chroot model (read this — resolves the keystone ambiguity).** Today
`/data/.mod/.reforge` IS the entire chroot rootfs (a full busybox/glibc tree built by Buildroot), and
`reforge-boot` does `exec chroot /data/.mod/.reforge /etc/init.d/rcS start`. That **does not change**:
- **chroot root** = `/data/.mod/.reforge` (full base rootfs: busybox/glibc, `/opt/*`, `/var/www`).
  The base is **OTA-out-of-scope** (USB `.tgz` only).
- The reforge-authored files (init scripts, configs, `.ko`, banner, service scripts, start/stop)
  move into a **subdir** `/data/.mod/.reforge/mod` — *inside* the chroot this is `/mod` (and also
  `/data/.mod/.reforge/mod` via the existing `/data` bind-mount). `mod/` holds **only reforge files**
  (no busybox/glibc/`/opt`), so the zip updater's `rmtree(mod)`+extract is safe.
- **`reforge-boot` now execs the mod's init**: `exec chroot /data/.mod/.reforge /mod/start.sh`, where
  `start.sh` runs `/mod/init.d/S*` in order. The `Sxx` reference `/opt/klipper` etc — resolved
  against the chroot rootfs, unchanged. **No `/etc/init.d` mirror.**
- **`[update_manager]` paths are chroot-relative** (Moonraker runs *inside* the chroot): `/opt/klipper`,
  `/opt/moonraker`, `/opt/guppyscreen`, and the reforge component path = `/mod`.

**Self-contained `mod/` layout (chroot-internal `/mod`):**
```
mod/
  release_info.json
  start.sh stop.sh           # run/stop the S* chain (forge-x pattern)
  init.d/{S00cloudblock,S35zram,S60klipper,S65moonraker,S70httpd,S75guppyscreen,S99ok}
  etc/reforge/{printer.cfg,printer.base.cfg,zram.conf}   # default configs (-> /etc/reforge symlink or sourced from here)
  modules/{zram.ko,zsmalloc.ko,swapon_prio}
  usr/bin/reforge-banner
  services/{klipper,moonraker,guppyscreen,reforge}       # SimpleProvider script_path wrappers
  .shell/{reforge-boot,reforge-lkg.sh}
```

- [ ] **Step 1: `post-build.sh` assembles `mod/` + seeds LKG.** Copy the reforge-authored files
  into `${TARGET_DIR}/data/.mod/.reforge/mod/...` per the layout; write a default `release_info.json`
  (4 keys, version from `packaging/VERSION`); seed `cp -a mod lkg`. Base rootfs stays in
  `/data/.mod/.reforge` as today (NOT inside `mod/`). The `etc/reforge` configs are sourced from `mod/`
  (klipper/moonraker already read `/etc/reforge/*` — symlink `/etc/reforge` → `/mod/etc/reforge`
  in `start.sh`, or point the daemons at `/mod/etc/reforge`).
- [ ] **Step 2: Service-control scripts** (`mod/services/<name>`) for `SimpleProvider`
  (`<script_path>/<name> <action>`). The service **name** must equal Moonraker's `unit_name`
  (defaults to `klipper`/`moonraker`/etc with `validate_service: false`):

```sh
#!/bin/sh
# mod/services/klipper  — start|stop|restart, delegates to the Sxx init script
exec /mod/init.d/S60klipper "$1"
```
(`klipper`→S60, `moonraker`→S65, `guppyscreen`→S75; `reforge`→`start.sh`/`stop.sh`). Set
`[machine] script_path: /mod/services` in Task 2. **Verify** the restart actually shells
`<script_path>/klipper restart` (not `klipper.service`) — see Notes.

- [ ] **Step 3: `reforge-boot` execs the mod init in place.** Change the final exec from
  `chroot $DIR /etc/init.d/rcS start` to `chroot $DIR /mod/start.sh`; `start.sh` runs `/mod/init.d/S*`
  in order. No mirror.
- [ ] **Step 4: First-boot LKG seed (handles the `.tgz` install too).** The image is seeded by
  post-build, but a USB `.tgz` install (`packaging/flashforge_init.sh`) extracts to
  `/data/.mod/.reforge` and creates no `lkg`. Fix **both**: (a) `flashforge_init.sh` seeds
  `cp -a /data/.mod/.reforge/mod /data/.mod/.reforge/lkg` after extract, **and** (b) `is_trial()` treats a
  missing `lkg` as *not a trial* (`[ -d "$LKG" ] || return 1`) so a fresh boot never phantom-trials.
- [ ] **Step 5: Loopback test.** Point `REFORGE_DATA_ROOT` at a scratch dir with a `mod/` tree
  (+ a seeded `lkg`); run `reforge-boot` (test mode); assert it execs `/mod/start.sh` (a sentinel
  S-script wrote its marker), created **no** `/etc/init.d` mirror, and (no-lkg case) did not
  increment the trial counter.

`Run: sudo make validate-loopback` (or the focused test) → Expected: PASS; init ran from `mod/`.

- [ ] **Step 6: Commit**

```bash
git add br-external/board/reforge/post-build.sh \
        br-external/board/reforge/rootfs-overlay/.shell/reforge-boot \
        br-external/board/reforge/rootfs-overlay/var/lib/moonraker/moonraker.asvc
git commit -m "ota: self-contained mod/ dir + run-init-in-place (no deploy mirror)"
```

---

## Task 4: Trial / LKG mechanism + `S99ok` sentinel

**Files:**
- Create: `br-external/board/reforge/rootfs-overlay/.shell/reforge-lkg.sh`
- Create: `br-external/board/reforge/rootfs-overlay/etc/init.d/S99ok`
- Modify: `reforge-boot` (call the trial logic around `deploy_mod`)
- Test: `tests/release/lkg-unit-test.sh` (host, no qemu)

**`reforge-lkg.sh` contract** (atomic, POSIX sh):

```sh
# state on writable /data
STATE="${DATA}/.reforge/state"; CNT="${STATE}/trial.count"
LKG="${DATA}/.reforge/lkg"; MOD="${DATA}/.reforge/mod"; N=3

_atomic_write() { tmp="$1.tmp.$$"; printf '%s' "$2" > "$tmp" && mv "$tmp" "$1"; }
lkg_counter_get()   { [ -f "$CNT" ] && cat "$CNT" || echo 0; }
lkg_counter_inc()   { mkdir -p "$STATE"; _atomic_write "$CNT" "$(( $(lkg_counter_get) + 1 ))"; }
lkg_counter_reset() { mkdir -p "$STATE"; _atomic_write "$CNT" 0; }
mod_version() { grep -o '"version"[^,]*' "$1/release_info.json" 2>/dev/null | sed 's/.*: *"//;s/"//'; }
# is this a trial boot? (mod version differs from lkg version)
# A missing LKG (fresh device / first boot) is NOT a trial (S4 guard).
is_trial() { [ -d "$LKG" ] || return 1; [ "$(mod_version "$MOD")" != "$(mod_version "$LKG")" ]; }
lkg_promote() { rm -rf "$LKG.new"; cp -a "$MOD" "$LKG.new" && rm -rf "$LKG" && mv "$LKG.new" "$LKG"; lkg_counter_reset; }
lkg_restore() { rm -rf "$MOD.bad"; mv "$MOD" "$MOD.bad" 2>/dev/null; cp -a "$LKG" "$MOD"; lkg_counter_reset; }
```

**`reforge-boot` trial flow** (replace the bare `deploy_mod` call), BEFORE deploy/chroot:

```sh
. "${DEST}/.shell/reforge-lkg.sh"
if is_trial; then
    if [ "$(lkg_counter_get)" -ge "$N" ]; then
        echo "[reforge-boot] trial failed ${N}x — restoring LKG"
        lkg_restore
    else
        lkg_counter_inc          # count BEFORE deploy (a brick during boot is counted)
    fi
fi
deploy_mod
# ... continue to rcS; S99ok will promote on success
```

**`S99ok`** (last init script, after S75guppyscreen):

```sh
#!/bin/sh
[ "$1" = start ] || exit 0
. "${REFORGE_DATA_ROOT:-/data}/.reforge/.shell/reforge-lkg.sh"
# Reached here => all prior S-scripts started. Promote current mod as last-known-good.
is_trial && echo "[S99ok] services up — promoting mod -> LKG"
lkg_promote
touch /tmp/reforge-ok
```

- [ ] **Step 1: Write `lkg-unit-test.sh`** (failing): set up a scratch `DATA` with `mod` (v2) + `lkg` (v1); assert `is_trial` true; **assert `is_trial` is FALSE when `lkg` is absent** (first-boot guard, S4); `lkg_counter_inc` thrice → `lkg_restore` swaps mod←lkg; `lkg_promote` makes versions equal + resets counter; counter writes are atomic (no partial file). Run → FAIL (helpers absent).
- [ ] **Step 2: Write `reforge-lkg.sh`** per the contract. Run test → PASS.
- [ ] **Step 3: Write `S99ok`** in `mod/init.d/` (chroot-relative `/mod/init.d/S99ok`), `chmod +x`.
  It is the **last** script `start.sh` runs, so reaching it just means "the init chain completed"
  — it runs **unconditionally** (it's the last script `start.sh` runs). `S75guppyscreen` exits 0
  whether or not it launches the GUI (it self-skips when `/dev/fb0` is absent), so `S99ok` always
  runs after it. It sources `/mod/.shell/reforge-lkg.sh` and calls `lkg_promote`. (Don't tie the
  sentinel to guppyscreen having started.)
- [ ] **Step 4: Wire the trial flow into `reforge-boot`.** Re-run `lkg-unit-test.sh` + `make validate-loopback`. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add br-external/board/reforge/rootfs-overlay/.shell/reforge-lkg.sh \
        br-external/board/reforge/rootfs-overlay/etc/init.d/S99ok \
        br-external/board/reforge/rootfs-overlay/.shell/reforge-boot \
        tests/release/lkg-unit-test.sh
git commit -m "ota: trial/LKG mechanism (atomic counter, N=3) + S99ok sentinel"
```

---

## Task 5: Local GitHub-releases-API mock

**Files:**
- Create: `tests/qemu-harness/mock-github-release.sh`

A tiny HTTP server the qemu guest reaches via an `/etc/hosts` override (`api.github.com` and the asset host → the mock). It serves:
- `GET /repos/maci0/reforge/releases/latest` → JSON `{tag_name, assets:[{name, browser_download_url}]}` pointing at local asset URLs.
- `GET /assets/<name>` → the zip bytes from `packaging/dist`.

- [ ] **Step 1:** Implement with `python3` (`http.server` + a small handler). Generate the
  `releases/latest` JSON from whatever zips are in `DIST_DIR`, asset URLs pointing back at the mock.
- [ ] **Step 2: TLS (resolved).** Moonraker calls `https://api.github.com` (+ the asset host) and
  validates TLS — plain http won't work. So the mock runs **HTTPS with a self-signed cert** for
  `api.github.com` + `objects.githubusercontent.com`, and the test **injects that CA into the
  guest trust store** (append to the rootfs `etc/ssl/certs/ca-certificates.crt`) + adds an
  `/etc/hosts` override (`api.github.com` / asset host → the qemu host gateway `10.0.2.2`). Then
  Moonraker's TLS validates against the mock. Host self-test: `curl --cacert <ca> https://…/repos/maci0/reforge/releases/latest`.
  **Alternative (authentic):** publish a real test release to `maci0/reforge` and let the guest
  hit real GitHub — no mock/TLS. The mock is for offline CI; the **critical LKG test (Task 6
  Step 2) needs neither** (it injects a broken `mod` directly).
- [ ] **Step 3: Commit**

```bash
git add tests/qemu-harness/mock-github-release.sh
git commit -m "ota: local github-releases-API mock for offline OTA tests"
```

---

## Task 6: qemu e2e OTA + the critical LKG/rollback test

**Files:**
- Create: `tests/qemu-harness/ota-test.sh`
- Modify: `Makefile` (add `qemu-ota` target)

- [ ] **Step 1: e2e update test** (needs the Task-5 mock **or** a real test release). Boot
  `build/output` rootfs (Task-2 config) under the virt kernel + virtio-net, mock reachable + its CA
  injected. Seed an **older** `release_info.json` version in a component path. Drive
  `POST /machine/update/{component}`; **poll `GET /machine/update/status` until done**, then assert
  the path's `release_info.json` version bumped + new files present + the service restarted live
  (`SimpleProvider`). **Caveat (S1):** updating `moonraker` restarts Moonraker itself
  *asynchronously* — the API call returns before the restart — so the test must **wait for
  Moonraker to drop and reconnect** (poll `/server/info`) rather than expect a synchronous result.
  For `reforge`, reboot once and assert `S99ok` promoted the new `mod`→`lkg`.
- [ ] **Step 2: the critical LKG/rollback test** (network-free — does **not** use the mock). Inject
  a deliberately-broken `mod` **directly** into the device's ext4 (e.g. `mod/init.d/S60klipper`
  that `exit 1`s / hangs) with a `release_info.json` version ≠ the seeded `lkg`. Reboot N=3 times;
  assert: the trial counter increments each boot, `S99ok` is never reached, and on the 3rd boot
  the LKG is restored → the good version boots + reaches `S99ok`. Proves the brick-mitigation
  independently of any download path.
- [ ] **Step 3: Mainsail web check.** Assert `/var/www/mainsail/manifest.json` (`name: mainsail`) exists; assert Moonraker resolves the upstream `mainsail-crew` latest (dry-run; needs real github or a second mock entry).
- [ ] **Step 4: `Makefile`** — `qemu-ota: ; sudo tests/qemu-harness/ota-test.sh`. Add to `.PHONY`.
- [ ] **Step 5: Run** `sudo make qemu-ota` → Expected: e2e update PASS + LKG-restore PASS.
- [ ] **Step 6: Commit**

```bash
git add tests/qemu-harness/ota-test.sh Makefile
git commit -m "ota: qemu e2e update + critical LKG/rollback test"
```

---

## Task 7: CI release workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1:** Tag-triggered (`on: push: tags: ['v*']`). Job: checkout (`submodules: recursive`), `./vendor/fetch.sh`, `make rootfs`, then `tools/release/build-release.sh --publish "${GITHUB_REF_NAME}"` (which does draft → upload assets → publish). Cache the buildroot dl-dir + ccache to cut the ~30–60 min build. Use `GITHUB_TOKEN` for `gh`.
- [ ] **Step 2:** Lint the workflow (`actionlint` if available) + a dry `build-release.sh --no-publish` in CI on PRs (no publish) to keep the slicer green.
- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ota: tag-triggered release workflow (draft-then-publish)"
```

---

## Final integration review

After all tasks: dispatch a final code-reviewer over the whole branch; verify the spec's acceptance criteria (per-component zips with 4-key release_info; `SimpleProvider` live-restart; init runs from the mod dir; LKG restores a bricked overlay update in qemu; CI publishes a multi-asset release). Then `superpowers:finishing-a-development-branch`.

## Notes / gotchas for the implementer

- **Verify Moonraker source before trusting config keys** — `net_deploy.py` (`AppType.ZIP/WEB`), `release_info.json` requires `project_owner` (a missing key marks the install invalid).
- **`reforge-boot` updating itself** is one-boot-delayed (the *current* boot uses the old `reforge-boot` to launch the new mod init); the trial/LKG covers a bad new `reforge-boot`.
- **Run-from-mod, no mirror**: the chroot runs `Sxx` directly from `mod/` (forge-x `start.sh` pattern), so a zip update of `mod/` is live with no copy step. The mod dir must be self-contained (init + configs + `.ko` + service-control scripts + start/stop) so the zip updater's `rmtree`+extract is safe.
- **SimpleProvider**: ported from forge-x; `script_path` = `/mod/services` (chroot-relative);
  `managed_services: X` → `/mod/services/X restart`.
- **Verify the service NAME matches** (S2): Moonraker shells `<script_path>/<unit_name> <action>`,
  where `unit_name` strips any `.service` suffix and defaults to the component name with
  `validate_service: false`. Confirm at runtime it runs `/mod/services/klipper restart` (not
  `klipper.service`) — an off-by-suffix name silently no-ops the restart. `moonraker` restarts
  itself **asynchronously**; tests must reconnect, not expect a synchronous result.
- **Chroot-relative paths everywhere**: Moonraker + the init run inside `/data/.mod/.reforge`; all
  `update_manager` paths, `script_path`, and `/mod/...` references are relative to that root.
- **No content-hash verification** in the updater (spec §integrity) — the trial/LKG is the corruption backstop; do not add a custom verifier (YAGNI).
- **`make integration` / `make qemu-*`** are the existing harnesses; reuse them, don't reinvent.
