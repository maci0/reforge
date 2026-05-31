# ReForge Plan 2 — Core Stack (Klipper + Moonraker + Mainsail + GuppyScreen) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the printer software stack to the ReForge Buildroot rootfs — latest pinned **Klipper** (host klippy, with AD5M patches + NEON-tuned chelper + power-loss/collision plugins), **Moonraker** (trimmed), **Mainsail** (web UI), and **GuppyScreen** (on-device UI) — all on a **single shared Buildroot python3**, and verify the services start and talk to each other in a host chroot (no device flash in this plan).

**Architecture:** Each component is a Buildroot package in our `BR2_EXTERNAL` tree (`br-external/package/<name>`), carried as pristine upstream source + numbered `.mk` patches (NO forks). Klipper and Moonraker run as separate processes on **one** target `python3` (COW page sharing — see the §"Single Python" note). A new build variant `reforge_guppyscreen_defconfig` selects the full stack. Verification is build + a host-side chroot integration test: start klippy against a simulated MCU, start Moonraker, confirm Moonraker's API answers and serves Mainsail — all under qemu-user, before any device involvement.

**Tech Stack:** Buildroot 2026.02.2 (pinned), target python3 (single, modern e.g. 3.12), Klipper, Moonraker, Mainsail (prebuilt bundle), GuppyScreen (native LVGL/libhv), iproute2, nginx (static serve), qemu-user for the chroot test.

**Scope boundary:** Builds on Plan 1's foundation (merged to `main`). Does NOT include: the `.tgz` installer (Plan 3), MCU firmware build/flash (Plan 4), kernel/U-Boot/display/full-image (Plan 5), or any on-device flashing. The rootfs still rides the (future) stock kernel; here we only prove the userspace stack builds and self-integrates in a chroot.

**Reference (not forked):** `xblax/build_scripts/buildroot/package/{klipper,moonraker,mainsail,guppyscreen}` and `components/{klipper_extensions,moonraker_extensions,mcu_configs}` are proven `.mk`/patch recipes for THIS board — consult them as the model when writing each package, then write our own.

---

## Key design decisions baked into this plan

1. **Single shared python3.** Measured on the live unit, klippy (Python 3.7) and Moonraker (Python 3.11) run on *two different* interpreters → zero shared pages → wasted RAM on 128 MB. ReForge builds ONE Buildroot `python3` and runs both daemons on it: one `libpython.so` whose read-only pages are COW-shared across both processes, shared stdlib + C-extensions, one interpreter on flash. Klipper upstream supports modern Python, so klippy moves off 3.7. (Spec §10.7, §10.6.)
2. **chelper NEON flags.** Klipper's real hot path is `klippy/chelper/*.c` (compiled C, called via ctypes). Build it with `-O2 -mcpu=cortex-a7 -mfpu=neon-vfpv4` via the Buildroot toolchain (spec §10.6).
3. **Moonraker trimmed, not rewritten.** Disable unused components (`update_manager`, `spoolman`, `announcements`, `notifier`); ship upstream (spec §10.7). Requires real `iproute2` (`ip` with JSON), not busybox.
4. **No cloud.** No NetEase/VoxelShare/MQTT anything. The `/etc/hosts` cloud-block is added with the init scripts.
5. **glibc + 5.4.61 headers** (from Plan 1) unchanged.

---

## File Structure (new in this plan)

| Path | Responsibility |
|---|---|
| `br-external/package/Config.in` | MODIFY: source each new package's `Config.in` |
| `br-external/package/klipper/{Config.in,klipper.mk,0001..patch}` | Klipper host package + AD5M patches |
| `br-external/package/klipper/extensions/*.py` | klippy extensions installed into the klipper tree (resurrection, load_cell_tare, md5_checker, gcode_shell_command) |
| `br-external/package/moonraker/{Config.in,moonraker.mk}` | Moonraker package |
| `br-external/package/moonraker/extensions/*.py` | Moonraker components (timelapse) |
| `br-external/package/mainsail/{Config.in,mainsail.mk}` | Mainsail prebuilt web bundle |
| `br-external/package/guppyscreen/{Config.in,guppyscreen.mk,00xx..patch}` | GuppyScreen native UI |
| `br-external/configs/reforge_guppyscreen_defconfig` | full-stack variant defconfig |
| `br-external/board/reforge/rootfs-overlay/etc/init.d/S60klipper` | klipper init |
| `br-external/board/reforge/rootfs-overlay/etc/init.d/S65moonraker` | moonraker init |
| `br-external/board/reforge/rootfs-overlay/etc/init.d/S70nginx` | web server init |
| `br-external/board/reforge/rootfs-overlay/etc/init.d/S75guppyscreen` | guppyscreen init |
| `br-external/board/reforge/rootfs-overlay/etc/init.d/S00cloudblock` | `/etc/hosts` cloud-block |
| `br-external/board/reforge/config/{printer.base.cfg,moonraker.conf,nginx.conf}` | default service configs |
| `scripts/chroot_integration.sh` | host chroot test: start klippy(sim MCU)+moonraker, probe API |
| `pins.lock` | MODIFY: add klipper/moonraker/mainsail/guppyscreen pins |

---

## Task 1: Single shared python3 + Klipper host dependencies

**Files:** Modify `br-external/configs/reforge_guppyscreen_defconfig` (create by copying `reforge_defconfig`); no package yet.

Goal: prove the toolchain builds a target python3 + the Python C-extension deps Klipper needs (numpy, cffi, pyserial, greenlet, jinja2), on one interpreter. This de-risks the heaviest part (numpy cross-compile) before wiring Klipper.

- [ ] **Step 1: Create the variant defconfig** by copying `reforge_defconfig` to `br-external/configs/reforge_guppyscreen_defconfig`, then append:
```
# Single shared interpreter for klippy + moonraker (COW page sharing)
BR2_PACKAGE_PYTHON3=y
# Klipper host deps
BR2_PACKAGE_PYTHON_NUMPY=y
BR2_PACKAGE_PYTHON_CFFI=y
BR2_PACKAGE_PYTHON_SERIAL=y   # package is python-serial (NOT ..._PYSERIAL)
BR2_PACKAGE_PYTHON_GREENLET=y
BR2_PACKAGE_PYTHON_JINJA2=y
BR2_PACKAGE_PYTHON_MARKUPSAFE=y
# Fortran needed to build numpy/scipy from source (xblax enables this)
BR2_TOOLCHAIN_BUILDROOT_FORTRAN=y
```
(Verify each symbol name with `grep` in `buildroot/package/*/Config.in` before trusting it — package symbol names occasionally differ, e.g. `BR2_PACKAGE_PYTHON_NUMPY`. Fix any that olddefconfig reports unknown and note it.)

- [ ] **Step 2: Build the variant**
Run: `cd reforge && build_scripts/build.sh` won't take a variant arg yet — instead:
```
cd reforge/buildroot
make BR2_EXTERNAL=$(realpath ../br-external) O=$(realpath ../output-guppy) reforge_guppyscreen_defconfig
make BR2_EXTERNAL=$(realpath ../br-external) O=$(realpath ../output-guppy) -j$(nproc)
```
Expected (long — numpy/Fortran build): ends with a `rootfs.tar.xz` under `output-guppy/images/`. (Note: uses a separate `output-guppy/` dir so it doesn't clobber Plan 1's `output/`. Add `output-guppy/` to `.gitignore`.)

- [ ] **Step 3: Verify python3 + numpy import under qemu-user**
```
cd reforge && rm -rf /tmp/g && mkdir /tmp/g && tar -C /tmp/g -xf output-guppy/images/rootfs.tar.xz
QEMU_LD_PREFIX=/tmp/g qemu-arm-static /tmp/g/usr/bin/python3 -c "import sys,numpy,cffi,serial,greenlet,jinja2; print('py', sys.version.split()[0], 'numpy', numpy.__version__)"
```
Expected: prints the python version (modern 3.x) and a numpy version, no ImportError. This proves the single interpreter + the scientific stack cross-compiled and loads on ARM.

- [ ] **Step 4: Update `.gitignore` + commit**
```
cd reforge
grep -q '^output-guppy/' .gitignore || echo 'output-guppy/' >> .gitignore
git add br-external/configs/reforge_guppyscreen_defconfig .gitignore
git commit -m "P2: full-stack variant defconfig — single python3 + Klipper host deps"
```

---

## Task 2: Klipper host package (klippy) with NEON chelper

**Files:** Create `br-external/package/klipper/{Config.in,klipper.mk}`; modify `br-external/package/Config.in`; modify `pins.lock`.

- [ ] **Step 1: Pick + record the Klipper pin.** Choose a recent Klipper `master` commit. Record in `pins.lock`: `klipper  commit  master  <SHA>`. Compute the hash for the `.mk` (`make ... klipper-source` then `sha256sum`, or use a git download).

- [ ] **Step 2: Write `Config.in`**
```
config BR2_PACKAGE_KLIPPER
	bool "klipper"
	select BR2_PACKAGE_PYTHON3
	select BR2_PACKAGE_PYTHON_CFFI
	select BR2_PACKAGE_PYTHON_PYSERIAL
	select BR2_PACKAGE_PYTHON_GREENLET
	select BR2_PACKAGE_PYTHON_NUMPY
	help
	  Klipper 3D printer host (klippy) for the FlashForge AD5M.
```

- [ ] **Step 3: Write `klipper.mk`** (model on `xblax/.../package/klipper/klipper.mk`). It must:
  - set `KLIPPER_VERSION` to the pinned SHA and `KLIPPER_SITE` to the klipper git;
  - install `klippy/` to `$(TARGET_DIR)/opt/klipper/klippy`;
  - **build `chelper` with NEON flags**: ensure the chelper compile uses `$(TARGET_CC)` with `-O2 -mcpu=cortex-a7 -mfpu=neon-vfpv4` (pass via the chelper build invocation in a post-build or by pre-compiling `c_helper.so` in `KLIPPER_BUILD_CMDS` using `$(TARGET_CC)` and the target CFLAGS);
  - generate the klippy `.version` file (the upstream needs a version; carry the `0002-Retrieve-version-from-local-file` patch idea from xblax if git isn't present).
  - NOT install klippy's own python env — it uses the system python3.

- [ ] **Step 4: Wire into menuconfig** — add to `br-external/package/Config.in`:
```
source "$BR2_EXTERNAL_REFORGE_PATH/package/klipper/Config.in"
```
and enable in the variant defconfig: `BR2_PACKAGE_KLIPPER=y`.

- [ ] **Step 5: Build + verify klippy is present and imports**
```
cd reforge/buildroot && make BR2_EXTERNAL=$(realpath ../br-external) O=$(realpath ../output-guppy) -j$(nproc)
cd .. && rm -rf /tmp/g && mkdir /tmp/g && tar -C /tmp/g -xf output-guppy/images/rootfs.tar.xz
ls /tmp/g/opt/klipper/klippy/klippy.py
# chelper .so must be ARM
file /tmp/g/opt/klipper/klippy/chelper/*.so | grep ARM
# klippy imports (won't fully start without an MCU, but must import + parse args)
QEMU_LD_PREFIX=/tmp/g qemu-arm-static /tmp/g/usr/bin/python3 /tmp/g/opt/klipper/klippy/klippy.py --help 2>&1 | head
```
Expected: `klippy.py` present, chelper `.so` is ARM, and `--help`/arg-parse runs without ImportError.

- [ ] **Step 6: Commit**
```
git add br-external/package/klipper/ br-external/package/Config.in br-external/configs/reforge_guppyscreen_defconfig pins.lock
git commit -m "P2: Klipper host package (klippy) + NEON-tuned chelper"
```

---

## Task 3: Klipper AD5M patches + klippy extensions

**Files:** Create `br-external/package/klipper/0001-relax-TRSYNC_TIMEOUT-ffad5m.patch`, `0002-lookahead-flush-time.patch`, `0003-unicode-gcode-objectnames.patch`; create `br-external/package/klipper/extensions/{resurrection.py,load_cell_tare.py,md5_checker.py,gcode_shell_command.py}`; modify `klipper.mk` to apply extensions.

- [ ] **Step 1: Write the three AD5M patches** (port from forge-x/xblax; each with a one-line provenance comment):
  - `0001`: `mcu.py` `TRSYNC_TIMEOUT 0.025 → 0.05` (fixes E0011 comms timeout).
  - `0002`: `toolhead.py` `LOOKAHEAD_FLUSH_TIME 0.5 → 0.150` (fixes E0017 move-queue overflow).
  - `0003`: gcode unicode object-name handling (`gcode.py`).
  Buildroot auto-applies `NNNN-*.patch` in the package dir — confirm they apply cleanly against the pinned commit (`git apply --check` inside the extracted source during a build; if a patch is rejected because upstream moved, rebase it and note it).

- [ ] **Step 2: Add the klippy extensions** (copy the proven files; model on `xblax/.../components/klipper_extensions/`). In `klipper.mk` `KLIPPER_INSTALL` step, copy `extensions/*.py` into `$(TARGET_DIR)/opt/klipper/klippy/extras/`.

- [ ] **Step 3: Build + verify patches applied + extensions present**
```
cd reforge/buildroot && make BR2_EXTERNAL=$(realpath ../br-external) O=$(realpath ../output-guppy) klipper-rebuild -j$(nproc)
cd .. && rm -rf /tmp/g && mkdir /tmp/g && tar -C /tmp/g -xf output-guppy/images/rootfs.tar.xz
grep -q '0.05' /tmp/g/opt/klipper/klippy/mcu.py && echo "TRSYNC patch applied"
ls /tmp/g/opt/klipper/klippy/extras/resurrection.py /tmp/g/opt/klipper/klippy/extras/load_cell_tare.py
# each extension must be importable python (syntax check)
for f in resurrection load_cell_tare md5_checker gcode_shell_command; do
  QEMU_LD_PREFIX=/tmp/g qemu-arm-static /tmp/g/usr/bin/python3 -m py_compile /tmp/g/opt/klipper/klippy/extras/$f.py && echo "$f ok"; done
```
Expected: patch markers present, extension files present, all `py_compile` clean.

- [ ] **Step 4: Commit**
```
git add br-external/package/klipper/
git commit -m "P2: Klipper AD5M patches (E0011/E0017/unicode) + klippy extensions"
```

---

## Task 4: Moonraker package (trimmed) + iproute2

**Files:** Create `br-external/package/moonraker/{Config.in,moonraker.mk}`; modify `br-external/package/Config.in`, variant defconfig, `pins.lock`.

- [ ] **Step 1: Pin Moonraker** — record `moonraker  commit  master  <SHA>` in `pins.lock`.

- [ ] **Step 2a: Enumerate Moonraker deps up front and classify each** (do this BEFORE writing Config.in — it's the most likely place to stall). For the pinned Moonraker commit, read its `scripts/moonraker-requirements.txt` and split into three buckets:
  - **(A) In Buildroot** (select these): `python-tornado`, `python-lmdb`, `python-jinja2`, `python-distro`, `python-pillow` (thumbnails), `python-zeroconf`, `python-pip`. Verify each symbol via `grep -ri "<pkgname>" buildroot/package/*/Config.in`.
  - **(B) NOT in Buildroot, NOT in xblax** — known missing: `inotify-simple`, `streaming-form-data`, `preprocess-cancellation`, `libnacl`, and (component-dependent) `apprise`, `ldap3`, `importlib-metadata`. For EACH, choose: write a small `BR2_EXTERNAL` `python-<name>` package (preferred, reproducible), OR — only if the component that needs it is being **trimmed/disabled** anyway (`apprise`→notifier, `ldap3`→ldap auth) — drop it. Cross-pip into the target is the last resort (fragile under cross-compile; document if used).
  - **(C) Provided by stdlib / not needed.**
  Record the bucket decision for each dep in a comment block at the top of `moonraker.mk` so the next maintainer sees it. (xblax pins older Moonraker `v0.9.3`; recent `master` may add deps — re-derive from the actual pinned requirements file, don't trust this list blindly.)
- [ ] **Step 2b: Write `Config.in`** — `select BR2_PACKAGE_PYTHON3` + all bucket-(A) packages + **`select BR2_PACKAGE_IPROUTE2`** (Moonraker needs real `ip` with JSON). Model on `xblax/.../package/moonraker`.

- [ ] **Step 3: Write `moonraker.mk`** — install `moonraker/` to `$(TARGET_DIR)/opt/moonraker` (or `/usr/share/moonraker`), using the **system python3** (no venv). Install the default `moonraker.conf` (Task 7) that **disables unused components**.

- [ ] **Step 4: Wire in + enable** (`package/Config.in` source line; `BR2_PACKAGE_MOONRAKER=y` + `BR2_PACKAGE_IPROUTE2=y` in variant defconfig).

- [ ] **Step 5: Build + verify Moonraker imports + `ip` present**
```
cd reforge/buildroot && make BR2_EXTERNAL=$(realpath ../br-external) O=$(realpath ../output-guppy) -j$(nproc)
cd .. && rm -rf /tmp/g && mkdir /tmp/g && tar -C /tmp/g -xf output-guppy/images/rootfs.tar.xz
ls /tmp/g/usr/sbin/ip || ls /tmp/g/sbin/ip          # iproute2 real ip
QEMU_LD_PREFIX=/tmp/g qemu-arm-static /tmp/g/usr/bin/python3 -c "import tornado, lmdb; print('moonraker deps ok')"
QEMU_LD_PREFIX=/tmp/g qemu-arm-static /tmp/g/usr/bin/python3 /tmp/g/opt/moonraker/moonraker/moonraker.py --help 2>&1 | head
```
Expected: real `ip` present, tornado+lmdb import, moonraker arg-parse runs.

- [ ] **Step 6: Commit**
```
git add br-external/package/moonraker/ br-external/package/Config.in br-external/configs/reforge_guppyscreen_defconfig pins.lock
git commit -m "P2: Moonraker package (system python3, trimmed) + iproute2"
```

---

## Task 5: Mainsail web UI + nginx

**Files:** Create `br-external/package/mainsail/{Config.in,mainsail.mk}`; modify wiring; add `BR2_PACKAGE_NGINX` to variant; `pins.lock`.

- [ ] **Step 1: Pin Mainsail** — a release tag (e.g. `vX.Y.Z`); record `mainsail  tag  vX.Y.Z  <SHA256-of-zip>` in `pins.lock`.

- [ ] **Step 2: Write `mainsail.mk`** — download the prebuilt `mainsail.zip` release artifact, unzip into `$(TARGET_DIR)/var/www/mainsail` (a static bundle; no build). Model on `xblax/.../package/mainsail`.

- [ ] **Step 3: Enable nginx** (`BR2_PACKAGE_NGINX=y` in variant) to serve the static Mainsail bundle and proxy `/websocket` + `/server` + `/printer` to Moonraker :7125. The nginx.conf comes from Task 7.

- [ ] **Step 4: Build + verify the bundle + nginx present**
```
cd reforge/buildroot && make BR2_EXTERNAL=$(realpath ../br-external) O=$(realpath ../output-guppy) -j$(nproc)
cd .. && rm -rf /tmp/g && mkdir /tmp/g && tar -C /tmp/g -xf output-guppy/images/rootfs.tar.xz
ls /tmp/g/var/www/mainsail/index.html
ls /tmp/g/usr/sbin/nginx
```
Expected: `index.html` present, nginx binary present.

- [ ] **Step 5: Commit**
```
git add br-external/package/mainsail/ br-external/package/Config.in br-external/configs/reforge_guppyscreen_defconfig pins.lock
git commit -m "P2: Mainsail web UI bundle + nginx"
```

---

## Task 6: GuppyScreen on-device UI

**Files:** Create `br-external/package/guppyscreen/{Config.in,guppyscreen.mk,0001..patch...}`; wiring; `pins.lock`.

- [ ] **Step 1: Pin GuppyScreen** — record `guppyscreen  commit  <branch>  <SHA>` in `pins.lock`.

- [ ] **Step 2: Write the package** (model on `xblax/.../package/guppyscreen`, carrying the 3 build patches it uses as reference: buildroot makefile patch, libhv makefile patch, calibration-timer pointer fix). GuppyScreen is native C++/LVGL/libhv — it links against the framebuffer; build with the target toolchain (NEON flags too). Install the binary to `$(TARGET_DIR)/opt/guppyscreen`.

- [ ] **Step 3: Enable** in variant defconfig (`BR2_PACKAGE_GUPPYSCREEN=y`) + any libhv/lvgl deps it needs.

- [ ] **Step 4: Build + verify the binary is ARM**
```
cd reforge/buildroot && make BR2_EXTERNAL=$(realpath ../br-external) O=$(realpath ../output-guppy) -j$(nproc)
cd .. && rm -rf /tmp/g && mkdir /tmp/g && tar -C /tmp/g -xf output-guppy/images/rootfs.tar.xz
file /tmp/g/opt/guppyscreen/guppyscreen | grep ARM
```
Expected: GuppyScreen binary present and ARM. (It needs a real framebuffer to RUN — that's an on-device concern for a later plan; here we only build it.)

- [ ] **Step 5: Commit**
```
git add br-external/package/guppyscreen/ br-external/package/Config.in br-external/configs/reforge_guppyscreen_defconfig pins.lock
git commit -m "P2: GuppyScreen native UI package"
```

---

## Task 7: Init scripts + service configs + cloud-block

**Files:** Create the `S*` init scripts, `printer.base.cfg`, `moonraker.conf`, `nginx.conf` under `br-external/board/reforge/`; reference them from `klipper.mk`/`moonraker.mk`/overlay.

- [ ] **Step 1: Write `S00cloudblock`** — appends the full FlashForge/NetEase cloud host set (from spec §"Hosts blocked") to `/etc/hosts` pointing at `127.0.0.1`, idempotently, on every boot.

- [ ] **Step 2: Write `S60klipper`** — starts klippy on the **system python3**: `/usr/bin/python3 /opt/klipper/klippy/klippy.py /etc/reforge/printer.cfg -a /run/klippy.sock -l /var/log/klippy.log`. Background, pid-tracked. **Export `MALLOC_ARENA_MAX=2` before launch** — glibc otherwise creates up to `8×CPU` per-thread malloc arenas, inflating RSS (free memory win on 128 MB; spec §10b).

- [ ] **Step 3: Write `S65moonraker`** — starts moonraker on the **same system python3**, `-d /etc/reforge/printer_data`, listening on :7125. **Also export `MALLOC_ARENA_MAX=2`** (same rationale).

- [ ] **Step 4: Write `S70nginx`** — starts nginx with `nginx.conf` serving `/var/www/mainsail` and proxying to Moonraker.

- [ ] **Step 5: Write `S75guppyscreen`** — starts GuppyScreen (guarded so it no-ops when there is no framebuffer, e.g. in chroot/qemu).

- [ ] **Step 6: Write the configs** — `moonraker.conf` with unused components disabled (`update_manager`, `spoolman`, `announcements`, `notifier` off) + `[authorization]` for the LAN + `[server]` host/port; minimal `printer.base.cfg` (a generic config sufficient to let klippy start in sim mode); `nginx.conf` (static + proxy). Model `moonraker.conf` on `forge-x/moonraker.conf`.

- [ ] **Step 7: Build + verify the files land in the rootfs**
```
cd reforge/buildroot && make BR2_EXTERNAL=$(realpath ../br-external) O=$(realpath ../output-guppy) -j$(nproc)
cd .. && rm -rf /tmp/g && mkdir /tmp/g && tar -C /tmp/g -xf output-guppy/images/rootfs.tar.xz
ls /tmp/g/etc/init.d/S60klipper /tmp/g/etc/init.d/S65moonraker /tmp/g/etc/init.d/S00cloudblock
grep -q 'update_manager' /tmp/g/etc/reforge/moonraker.conf && echo "check update_manager is disabled in conf"
```
Expected: all init scripts present + executable; moonraker.conf disables the unused components.

- [ ] **Step 8: Commit**
```
git add br-external/board/reforge/
git commit -m "P2: init scripts, service configs, /etc/hosts cloud-block"
```

---

## Task 8: Chroot integration test (the real verification)

**Files:** Create `scripts/chroot_integration.sh`; add a `make integration` target.

This is the proof the stack self-integrates without a device: start klippy against a **simulated MCU**, start Moonraker, confirm Moonraker's HTTP API answers and that it reaches klippy.

- [ ] **Step 1: Write `scripts/chroot_integration.sh`** that:
  1. extracts `output-guppy/images/rootfs.tar.xz` to a working dir;
  2. copies `qemu-arm-static` into it and (with `sudo`) bind-mounts `/proc`,`/sys`,`/dev` OR runs binaries via `QEMU_LD_PREFIX` without chroot where possible;
  3. starts klippy in **batch/simulation**: Klipper ships `klippy/console.py` and supports a virtual MCU via `scripts/avrsim`/`simulavr`, but the lightest check is to run klippy pointed at a PTY pair with a simulated MCU, OR assert klippy reaches the "Loading config"/"MCU 'mcu' is_shutdown waiting" state (i.e. it parses config + starts its reactor). Accept "klippy started and is waiting for MCU" as success for this plan (full MCU sim is optional).
  4. starts Moonraker on the system python3 against a temp `printer_data`;
  5. **branch on a `FULL_API` flag** (set based on whether Moonraker actually started under qemu — decided in step 4):
     - **FULL_API=1:** `curl -s http://127.0.0.1:7125/server/info` → assert HTTP 200 + JSON `klippy_state`; `curl -s http://127.0.0.1/` (nginx) → assert Mainsail `index.html` served; print `PASS: core stack integrates (live moonraker API + mainsail)`.
     - **FULL_API=0 (documented fallback floor):** assert (a) `moonraker.py` imports + its config validates (config-check entrypoint or `--help` + a python `import moonraker` smoke), (b) nginx serves the static bundle (`curl http://127.0.0.1/` → index.html), (c) klippy parses config + reaches its reactor/"waiting for MCU". Print `PASS: core stack builds+self-checks (live API deferred to P3 on-device)`.
  The two paths must be coded as explicit branches so the script never half-runs a curl against a daemon that isn't up. Record in the commit which floor was achieved.
  6. tears everything down on exit (trap); a specific `FAIL: <what>` + exit 1 on any failed assertion.

- [ ] **Step 2: Run it BEFORE the stack is wired to confirm it fails clean** (e.g. against a Plan-1 minimal rootfs or with services absent) — expect a clear FAIL, exit 1.

- [ ] **Step 3: Run it against the full `output-guppy` rootfs**
Run: `cd reforge && make integration`
Expected: `PASS: core stack integrates (moonraker API up, mainsail served)`.
NOTE: running ARM Python daemons under qemu-user is slow; allow minutes. If full Moonraker startup under qemu-user proves too heavy/flaky, fall back to asserting: (a) Moonraker imports + its config validates (`moonraker.py --help` / a config-check entrypoint), (b) nginx serves the static bundle, and (c) klippy parses config + starts its reactor — and DOCUMENT that full live-API-under-qemu is deferred to the on-device P3 plan. Record exactly which level of verification was achieved.

- [ ] **Step 4: Commit**
```
git add scripts/chroot_integration.sh Makefile
git commit -m "P2: chroot integration test (klippy sim + moonraker API + mainsail)"
```

---

## Task 9: Wire the variant into the build wrapper + smoke

**Files:** Modify `build_scripts/build.sh`, `Makefile`, `scripts/smoke_rootfs.sh`.

- [ ] **Step 1: Teach `build.sh` about the variant** — add a verb/arg so `build.sh rootfs guppyscreen` builds `reforge_guppyscreen_defconfig` into `output-guppy/`, while the bare `rootfs` keeps building the Plan-1 minimal variant into `output/`. Keep both working.

- [ ] **Step 2: Extend `smoke_rootfs.sh`** (or add `smoke_guppy`) to smoke the full-stack rootfs: in addition to the Plan-1 checks, assert `/opt/klipper/klippy/klippy.py`, `/opt/moonraker`, `/var/www/mainsail/index.html`, `/opt/guppyscreen/guppyscreen`, and `/usr/bin/python3` all exist and the python imports numpy+tornado.

- [ ] **Step 3: Run both smokes**
```
cd reforge && make rootfs && make smoke            # Plan-1 minimal still green
build_scripts/build.sh rootfs guppyscreen && scripts/smoke_rootfs.sh guppy   # full stack
```
Expected: both PASS.

- [ ] **Step 4: Update CI** — add the `guppyscreen` variant build + its smoke to `.github/workflows/build.yml` (a second job or matrix). Validate YAML.

- [ ] **Step 5: Commit**
```
git add build_scripts/build.sh Makefile scripts/smoke_rootfs.sh .github/workflows/build.yml
git commit -m "P2: build wrapper + smoke + CI for the full-stack variant"
```

---

## Task 10: zram compressed swap (P1–P3, stock kernel)

**Files:** Create `br-external/package/reforge-zram/{Config.in,reforge-zram.mk}` (ships the prebuilt modules + helper + setup into the rootfs); `br-external/board/reforge/rootfs-overlay/etc/init.d/S35zram`; reference artifacts in `modules/zram-bsp/dist/`.

**Already proven** (see `modules/zram-bsp/` + `docs/research/2026-05-31-memory-and-testing.md` §4): loadable `zram.ko`+`zsmalloc.ko` built from the **Allwinner T113 vendor BSP** source (`iLotusK9/linux_kernel_aw_t113@5.4.61`) load on the stock 5.4.61 kernel and give **~4× zstd** compressed swap. Because P1–P3 ride the stock kernel, ReForge ships these as prebuilt modules now (P4's own kernel builds zram in — `CONFIG_ZRAM`/`ZSMALLOC` — and drops this package). This mirrors the forge-x contribution (`maci0/ff5m` branch `add-zram-swap`).

- [ ] **Step 1: Vendor the artifacts.** Copy `modules/zram-bsp/dist/{zsmalloc.ko,zram.ko,swapon_prio}` into the package. **Provenance + rebuild steps are `modules/zram-bsp/README.md` + `build.sh`** (vendor BSP source — NOT upstream, which Oopses; vermagic must be exactly `5.4.61 SMP preempt mod_unload ARMv7 p2v8`). Commit the `.ko` as binary artifacts with the build doc (GPL: source + instructions referenced).

- [ ] **Step 2: Package** — `reforge-zram.mk` installs the two `.ko` + `swapon_prio` to `$(TARGET_DIR)/opt/reforge/zram/`. `Config.in` `BR2_PACKAGE_REFORGE_ZRAM`, enabled in the variant defconfig.

- [ ] **Step 3: `S35zram` init** (runs before `S60klipper`) — load modules; if `/dev/zram0` appears, configure `comp_algorithm` (from a config var, default `zstd`; `lzo-rle` is the low-CPU alt), set `disksize` (256M), `mkswap`, and `swapon_prio /dev/zram0 100` (primary). **Do NOT `swapoff -a`** (fails under memory pressure on 128MB — see the forge-x bug). Optionally add a small eMMC/UDISK swapfile as low-priority overflow without disturbing existing swaps. If the module fails to load, log + continue (no swap rather than a boot failure).

- [ ] **Step 4: Make the algorithm configurable** — read `zram_algo` from the ReForge config (default `zstd`); document `zstd` (~4× best ratio) vs `lzo-rle` (~2.7×, cheaper A7 CPU) per `docs/research/2026-05-31-memory-and-testing.md` §6.

- [ ] **Step 5: Verify** — build the variant; confirm the `.ko` + `swapon_prio` land in the rootfs and vermagic matches; assert in the smoke test that `/opt/reforge/zram/zram.ko` exists with the exact vermagic string. (Live insmod is an on-device P3 check — qemu-user can't load kernel modules.)

- [ ] **Step 6: Commit** — `git add br-external/package/reforge-zram/ br-external/board/reforge/rootfs-overlay/etc/init.d/S35zram modules/zram-bsp/dist/ ; git commit -m "P2: zram compressed swap (prebuilt modules, configurable algo) for P1-P3"`

---

## Done criteria for Plan 2

- [ ] One shared `python3` builds with numpy/cffi/pyserial/greenlet/jinja2 and imports under qemu-user.
- [ ] Klipper installed to `/opt/klipper`, chelper `.so` is ARM + NEON-built, klippy arg-parses; AD5M patches applied; klippy extensions present + compile.
- [ ] Moonraker installed on the system python3 (no venv), imports tornado+lmdb, `iproute2` real `ip` present; unused components disabled in `moonraker.conf`.
- [ ] Mainsail static bundle + nginx present.
- [ ] GuppyScreen binary built (ARM).
- [ ] Init scripts + `/etc/hosts` cloud-block present.
- [ ] zram package present: `zram.ko`+`zsmalloc.ko`+`swapon_prio` in the rootfs with exact vermagic; `S35zram` init brings up zstd compressed swap as primary (configurable algo); no `swapoff -a`.
- [ ] `make integration` PASSES (or the documented fallback level, with exactly-what-was-verified recorded).
- [ ] Full-stack smoke PASSES; Plan-1 minimal variant still PASSES; CI green; Buildroot submodule still unmodified; no large artifacts tracked.

**Next plan:** Plan 3 — P3 `.tgz` installer (stock-format package, first on-device flash, gated on the verified golden dump).
</content>
