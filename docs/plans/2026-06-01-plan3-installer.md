# ReForge Plan 3 — Installer + qemu Harness + Stock-UI Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the flashable `reforge-<ver>.tgz` userland installer and validate it **without flashing the printer** — via a qemu-system-arm harness whose `/dev/fb0` matches the real panel — plus a stock-UI feasibility spike.

**Architecture:** A packaging unit assembles a stock-format `.tgz` (overlay-on-stock, `flashforge_init.sh`-compatible) from the Plan-2 `output-guppy` rootfs. A validation unit proves the install logic on a loopback `/data` and inside qemu (a test-only virt kernel built from the Tina vendor source, the stock rootfs extracted from the golden eMMC dump, a pinned 800×480×32 framebuffer). A spike unit extracts + analyzes the stock `firmwareExe` and (if the qemu fb works) runs it live against ReForge's upstream klippy, producing a go/no-go report. Nothing touches the device; no proprietary blobs are committed.

**Tech Stack:** bash, tar/xz, GNU make, Buildroot (in-repo submodule), the Tina vendor kernel source (`modules/zram-bsp/tina-bsp-kernel`), qemu-system-arm (`-M virt`, virtio-blk/gpu/input), qemu-arm-static, ext4 loopback, the golden eMMC dump.

**Spec:** `docs/2026-06-01-plan3-installer-design.md`. Read it. Path bases (spec §8): the golden dump, the Tina kernel source, and `output-guppy/` are **in-repo** under `reforge/`; `../fw-analysis/` and `../forge-x/` are **external sibling dirs** (use `../` or absolute paths). The proprietary `firmwareExe` lives only in `../fw-analysis/` and must NEVER be copied into the repo.

**Scope boundary:** Plan 3 = userland installer + validation + spike. NO device flash. The `control-` (MCU) subpackage is an **empty stub** (Plan 4 fills it) — a flashed ReForge boots + is web-reachable but won't drive the printer until Plan 4. No motion/print simulation.

---

## File Structure

| Path | Responsibility |
|---|---|
| `packaging/build-tgz.sh` | Assemble `reforge-<ver>.tgz` from `output-guppy` + the installer + subpackages |
| `packaging/flashforge_init.sh` | The installer run by the stock USB updater: overlay-install to `/data/.reforge` + boot hook |
| `packaging/reforge-boot` | Boot hook (mount over `/data`, chroot, start ReForge init); installed by the installer |
| `packaging/uninstall/flashforge_init.sh` | Uninstall package installer (remove `/data/.reforge` + hook) |
| `packaging/VERSION` | ReForge version string |
| `validation/loopback-install-test.sh` | Run installer against an ext4 loopback `/data` → assert overlay + hook |
| `validation/qemu-harness/build-test-kernel.sh` | Build the virt test kernel (Tina source → virt; generic fallback) |
| `validation/qemu-harness/extract-stock-rootfs.sh` | Extract `mmcblk0p6` from the golden dump → bootable ext4 |
| `validation/qemu-harness/run-qemu.sh` | Boot a rootfs under the test kernel with the pinned 800×480×32 fb + virtio |
| `validation/qemu-harness/update-process-test.sh` | Minimum-bar: install ReForge via installer → boot ReForge under the test kernel |
| `validation/qemu-harness/reforge-render-test.sh` | Boot ReForge in qemu → GuppyScreen renders to fb0 → screenshot |
| `spike-stockui/extract.sh` | Pull `firmwareExe` + Qt deps from `../fw-analysis` stock images (gitignored) |
| `spike-stockui/analyze.sh` | `ldd`/`strings`/RE → klippy socket, gcode/objects, FF modules |
| `spike-stockui/REPORT.md` | Works/breaks vs upstream klippy → go/no-go |
| `.gitignore` | MODIFY: block `spike-stockui/extracted/`, `validation/qemu-harness/*.img`, `*.ext4`, any firmwareExe/Qt blobs |
| `.github/workflows/build.yml` | MODIFY: add a "no proprietary blobs tracked" CI check |
| `Makefile` | MODIFY: add `tgz`, `validate-loopback`, `qemu-kernel`, `qemu-update`, `qemu-render`, `spike` targets |

---

## Task 1: Packaging — build the `.tgz`

**Files:** Create `packaging/build-tgz.sh`, `packaging/VERSION`, `packaging/flashforge_init.sh` (stub for now), `packaging/control-stub/README`; Modify `Makefile`, `.gitignore`.

- [ ] **Step 1: Version + gitignore.** `echo "0.3.0-dev" > packaging/VERSION`. Add to `.gitignore`: `packaging/dist/`, `*.img`, `*.ext4`, `spike-stockui/extracted/`.

- [ ] **Step 2: Write `build-tgz.sh`.** It must produce `packaging/dist/reforge-<ver>.tgz`, a **plain tar** (stock format) containing:
  - `software-<ver>.tar.xz` — `xz`-compressed tar of the `output-guppy/images/rootfs.tar` contents (the ReForge rootfs tree) + an inner `md5sum.list`.
  - `library-<ver>.tar.xz` — runtime libs not in the rootfs; for P3 this can be an (almost) empty stub with a README "reserved" (the full-stack rootfs already self-contains its libs). Document it.
  - `control-<ver>.tar.xz` — **empty stub** (a tar with a `RESERVED-FOR-MCU-PLAN4` marker file).
  - `flashforge_init.sh` — the installer (Task 2; for Step here, copy the current stub).
  - `md5sum.list` — md5 of each subpackage (the stock installer style).
  Use `VER=$(cat packaging/VERSION)`. Build artifacts go in `packaging/dist/` (gitignored).

- [ ] **Step 3: Stub installer + control stub.** `packaging/flashforge_init.sh` = a stub that `echo "reforge installer placeholder"; exit 0` (real logic in Task 2). `packaging/control-stub/RESERVED-FOR-MCU-PLAN4` = a marker file.

- [ ] **Step 4: Makefile target.** Add `tgz: ; packaging/build-tgz.sh`. Run `make tgz` (requires `output-guppy/images/rootfs.tar` — build it first with `make guppy` if absent; the script should error clearly if missing).

- [ ] **Step 5: Verify the `.tgz` structure**
```
make guppy >/dev/null 2>&1 || true   # ensure rootfs exists
make tgz
VER=$(cat packaging/VERSION)
tar tf packaging/dist/reforge-$VER.tgz        # lists software/library/control subpkgs + flashforge_init.sh + md5sum.list
mkdir -p /tmp/tgz && tar -C /tmp/tgz -xf packaging/dist/reforge-$VER.tgz
ls /tmp/tgz/flashforge_init.sh /tmp/tgz/software-$VER.tar.xz /tmp/tgz/control-$VER.tar.xz /tmp/tgz/md5sum.list
# software subpkg actually contains the ReForge rootfs:
tar tf /tmp/tgz/software-$VER.tar.xz | grep -E 'opt/klipper/klippy/klippy.py|opt/moonraker|var/www/mainsail' | head
# md5sum.list matches:
cd /tmp/tgz && md5sum -c md5sum.list
```
Expected: all subpackages + installer + md5sum present; software subpkg contains klippy/moonraker/mainsail; `md5sum -c` passes.

- [ ] **Step 6: Commit**
```
git add packaging/ Makefile .gitignore
git commit -m "P3: packaging — build stock-format reforge-<ver>.tgz from output-guppy"
```

---

## Task 2: The installer (`flashforge_init.sh`) + boot hook

**Files:** Rewrite `packaging/flashforge_init.sh`; Create `packaging/reforge-boot`, `packaging/uninstall/flashforge_init.sh`.

**Reference:** `../fw-analysis/x-5.1.4/flashforge_init.sh` (stock install flow — the `update_*` functions + arch/PID checks). `../forge-x/.shell/` (how forge-x hooks the stock boot + chroots + screen modes + SKIP_MOD dual-boot). Read both; ReForge mirrors the forge-x overlay pattern.

- [ ] **Step 1: Write `flashforge_init.sh`** (run by the stock USB updater, host-side). It must:
  1. arch check (`uname -m` == `armv7l`) + machine/PID check (`Adventurer5MPro`/`Adventurer5M`, PID 0023/0024) — exit 1 on mismatch (model on the stock script's checks).
  2. extract `software-<ver>.tar.xz` into **`/data/.reforge`** (the overlay root). NEVER write to `/opt`, the stock rootfs, kernel, or partitions.
  3. install the boot hook: place `reforge-boot` where the stock boot sequence will run it (model on how forge-x injects its init — e.g. via the stock `/opt/config` startup or an init.d hook). Persist a default screen mode = `HEADLESS`.
  4. write a `/data/.reforge/.installed` marker + version.
  5. print clear progress + a final "ReForge installed; reboot" message.
  Keep it POSIX `sh` (busybox), `sh -n` clean.

- [ ] **Step 2: Write `reforge-boot`** — on boot: if a `SKIP_MOD` marker (USB file or setting) is present → exit (dual-boot to stock); else mount over `/data`, `chroot /data/.reforge`, exec the ReForge init chain (the Plan-2 `/etc/init.d/rcS`-equivalent → S00cloudblock…S35zram…S60klipper…). Model the chroot + SKIP_MOD logic on forge-x's `S00init`/`S99root`.

- [ ] **Step 3: Write the uninstall installer** `packaging/uninstall/flashforge_init.sh` — removes `/data/.reforge` + the boot hook, restoring pure stock. Build a `reforge-uninstall-<ver>.tgz` in `build-tgz.sh` (extend it).

- [ ] **Step 4: Syntax + static checks**
```
sh -n packaging/flashforge_init.sh && echo "installer syntax OK"
sh -n packaging/reforge-boot && echo "boot hook syntax OK"
sh -n packaging/uninstall/flashforge_init.sh && echo "uninstall syntax OK"
grep -nE '/opt|mmcblk|/dev/mmc' packaging/flashforge_init.sh   # must NOT write to stock rootfs/partitions
```
Expected: all `sh -n` clean; no writes to `/opt`/partitions in the installer (read-only refs OK, but assert no destructive ops).

- [ ] **Step 5: Rebuild the `.tgz` with the real installer + verify it's included**
```
make tgz
VER=$(cat packaging/VERSION); rm -rf /tmp/tgz && mkdir /tmp/tgz && tar -C /tmp/tgz -xf packaging/dist/reforge-$VER.tgz
sh -n /tmp/tgz/flashforge_init.sh && echo "packaged installer syntax OK"
```

- [ ] **Step 6: Commit**
```
git add packaging/
git commit -m "P3: installer flashforge_init.sh (overlay+chroot) + boot hook + uninstall"
```

---

## Task 3: Loopback install validation (no device, no qemu)

**Files:** Create `validation/loopback-install-test.sh`; Modify `Makefile`.

This proves the install logic on a fake `/data` using an ext4 loopback image + chroot, independent of qemu. The **minimum** install proof.

- [ ] **Step 1: Write `loopback-install-test.sh`** that:
  1. creates a 2 GB ext4 loopback image, mounts it at a temp `$DATA` (the fake `/data`).
  2. runs the installer's extract/install steps against `$DATA` (you may need to parameterize `flashforge_init.sh` with a `DATA_ROOT` env override for testability, OR run the relevant install function with `/data`→`$DATA` redirected). Keep the installer's real logic; just point `/data` at the loopback.
  3. asserts: `$DATA/.reforge/opt/klipper/klippy/klippy.py` exists, `$DATA/.reforge/usr/bin/python3` exists, the boot hook is installed, the `.installed` marker + version present, default screen mode = HEADLESS.
  4. asserts the installer did NOT touch anything outside `$DATA` (run under a temp HOME; check no writes to `/opt`).
  5. `trap` cleanup (umount, losetup -d, rm). Prints `PASS: loopback install verified` or a specific FAIL.

- [ ] **Step 2: Run it before the installer is wired correctly to confirm it can FAIL** (e.g. against an empty `.tgz`) — expect FAIL + exit 1.

- [ ] **Step 3: Run it for real**
Run: `make validate-loopback` (add target `validate-loopback: ; sudo validation/loopback-install-test.sh` — note: loopback mount needs root; document the `sudo`).
Expected: `PASS: loopback install verified`.

- [ ] **Step 4: Commit**
```
git add validation/loopback-install-test.sh Makefile
git commit -m "P3: loopback install validation (ext4 /data, no device)"
```

---

## Task 4: qemu test kernel (virt, 800×480×32 fb)

**Files:** Create `validation/qemu-harness/build-test-kernel.sh`, `validation/qemu-harness/configs/`; Modify `Makefile`.

**This is the highest-risk task (spec §7 risk 1).** Build a test-only kernel that boots under `qemu-system-arm -M virt` with virtio + a framebuffer pinned to the printer panel.

- [ ] **Step 1: Attempt the Tina-vendor path.** Configure `modules/zram-bsp/tina-bsp-kernel` (the in-repo vendor source) for `qemu virt`: enable `ARCH_MULTI_V7` + `ARCH_VIRT` + `VIRTIO_{BLK,NET,GPU,INPUT,MMIO,PCI}` + `DRM_VIRTIO_GPU` + `DRM_SIMPLEDRM`/`FB_SIMPLE` + `FB`/`FRAMEBUFFER_CONSOLE` + ext4 + `DEVTMPFS`. Build a `zImage` + the `virt` DTB (qemu can generate the DT, or use `-machine virt,dumpdtb`). Build into `validation/qemu-harness/build/`.

- [ ] **Step 2: If the vendor kernel won't configure/boot for virt, FALL BACK** to a generic Buildroot armv7 virt kernel: add a tiny `BR2_EXTERNAL` defconfig `reforge_qemuvirt_defconfig` (or use Buildroot's `qemu_arm_vexpress`/virt sample) that builds a mainline armv7 kernel with the same virtio + fb options. Document which path you used + why. Either kernel is TEST-ONLY (never shipped).

- [ ] **Step 3: Pin the framebuffer to 800×480×32.** Configure the fb mode so `/dev/fb0` comes up as **800×480 visible, 32 bpp (xRGB8888), virtual 800×960**. Either: a fixed `simple-framebuffer` DT node (800×480, `format = "a8r8g8b8"`), or kernel cmdline `video=800x480-32` (+ later set `virtual_y=960` via `fbset`). Bake the cmdline into `run-qemu.sh` (Task: next).

- [ ] **Step 4: Boot smoke — kernel reaches userspace under qemu**
Build a trivial initramfs (busybox `init` that prints fb0 geometry) OR use the Plan-1 minimal `output/images/rootfs.tar.xz` as a virtio-blk root. Then:
```
make qemu-kernel       # builds the test kernel
# boot test (run-qemu.sh from Task 5, or inline):
qemu-system-arm -M virt -cpu cortex-a7 -m 256 -nographic \
  -kernel validation/qemu-harness/build/zImage \
  -append "console=ttyAMA0 video=800x480-32 ..." \
  -device virtio-gpu-pci ... 2>&1 | tee /tmp/qboot.log
grep -iE 'fb0|800x480|Linux version|Freeing init' /tmp/qboot.log | head
```
Expected: kernel boots to userspace under qemu virt; `/dev/fb0` reports 800×480. (If using the fallback kernel, same expectation.) Capture the boot log.

- [ ] **Step 5: Commit**
```
git add validation/qemu-harness/build-test-kernel.sh validation/qemu-harness/configs/ Makefile
git commit -m "P3: qemu virt test kernel (Tina source or generic fallback) + 800x480x32 fb"
```

---

## Task 5: Extract stock rootfs + qemu run wrapper

**Files:** Create `validation/qemu-harness/extract-stock-rootfs.sh`, `validation/qemu-harness/run-qemu.sh`; Modify `Makefile`, `.gitignore`.

- [ ] **Step 1: `extract-stock-rootfs.sh`** — from the golden dump (`recovery/golden-kunos-*.img.gz`), extract partition `mmcblk0p6` (the stock rootfs) into a standalone ext4 image `validation/qemu-harness/build/stock-rootfs.ext4` (gitignored). Use the partition offsets from `recovery/partitions-*.txt` (or `losetup -P` / `kpartx` on the decompressed image). Verify it mounts + contains the stock `/opt/PROGRAM` (where firmwareExe lives).

- [ ] **Step 2: `run-qemu.sh`** — parameterized wrapper: `run-qemu.sh <root.ext4> [extra-args]`. Boots the test kernel with: virtio-blk root = the given ext4, `-m 256`, the `video=800x480-32` cmdline, virtio-gpu + virtio-input, a virtio "USB" drive arg for the `.tgz`, `-nographic` console + optional VNC for the fb. Robust timeouts + a way to capture the fb (qemu `-display` / screenshot via the QEMU monitor `screendump`).

- [ ] **Step 3: Verify the stock rootfs extracts + the wrapper boots SOMETHING**
```
make qemu-stock-rootfs    # runs extract-stock-rootfs.sh
sudo mount -o loop,ro validation/qemu-harness/build/stock-rootfs.ext4 /mnt && ls /mnt/opt/PROGRAM 2>/dev/null; sudo umount /mnt
# boot the minimal Plan-1 rootfs via the wrapper (sanity that run-qemu works):
# (convert output/images/rootfs.tar.xz to ext4 or use as initramfs)
validation/qemu-harness/run-qemu.sh <a-known-good-rootfs> 2>&1 | grep -iE 'fb0|login|init' | head
```
Expected: stock rootfs extracts + contains `/opt/PROGRAM`; `run-qemu.sh` boots a rootfs to userspace.

- [ ] **Step 4: Commit**
```
git add validation/qemu-harness/extract-stock-rootfs.sh validation/qemu-harness/run-qemu.sh Makefile .gitignore
git commit -m "P3: extract stock rootfs from golden dump + qemu run wrapper"
```

---

## Task 6: qemu update-process test (minimum bar)

**Files:** Create `validation/qemu-harness/update-process-test.sh`; Modify `Makefile`.

Spec §4c minimum bar: install ReForge via the installer's filesystem ops, then boot ReForge under the test kernel.

- [ ] **Step 1: Write `update-process-test.sh`** that:
  1. takes the stock rootfs ext4 (or a minimal harness rootfs) + the `reforge-<ver>.tgz`.
  2. runs the installer (`flashforge_init.sh`) so ReForge lands in the rootfs's `/data/.reforge` (chroot or loopback-mount the ext4 and run the installer against it — reuse Task 3's mechanism).
  3. boots the **ReForge** rootfs (the `/data/.reforge` tree, or convert it to an ext4) under the test kernel via `run-qemu.sh`.
  4. asserts ReForge comes up: the boot hook chroots, the init chain runs, and (from inside qemu, over a virtio-net port forward or the console) Moonraker answers `:7125/server/info` OR the console shows the ReForge services started. Reuse the Plan-2 integration assertions where possible.
  5. Prints `PASS: update process (install → ReForge boots in qemu)` or a specific FAIL. Document if only the console-level (not live-API) assertion was reached.

- [ ] **Step 2: Run it**
Run: `make qemu-update`
Expected: PASS (minimum bar). If the live Moonraker-in-qemu check is too heavy, the accepted floor is "ReForge init chain runs + services start" from the console — record which level was achieved (mirror Plan-2's FULL_API/floor honesty).

- [ ] **Step 3: Commit**
```
git add validation/qemu-harness/update-process-test.sh Makefile
git commit -m "P3: qemu update-process test (install -> ReForge boots, minimum bar)"
```

---

## Task 7: ReForge render test (GuppyScreen on the pinned fb)

**Files:** Create `validation/qemu-harness/reforge-render-test.sh`; Modify `Makefile`.

- [ ] **Step 1: Write `reforge-render-test.sh`** — boot the ReForge rootfs in qemu with screen mode = `GUPPY` + the 800×480×32 fb + virtio-input; let GuppyScreen start; capture the framebuffer (QEMU monitor `screendump` → PPM, or read `/dev/fb0`). Assert: GuppyScreen process runs, the fb is non-blank (some pixels written) at 800×480. Save the screenshot to `validation/qemu-harness/build/guppy-screenshot.ppm` (gitignored). Klippy will be "waiting for MCU" (no MCU) — GuppyScreen should still render its UI/connection screen.

- [ ] **Step 2: Run it**
Run: `make qemu-render`
Expected: GuppyScreen renders to the 800×480 fb (non-blank screenshot). If GuppyScreen needs klippy/moonraker connectivity to draw anything, document the partial result (it may show a "connecting" screen — that still proves render).

- [ ] **Step 3: Commit**
```
git add validation/qemu-harness/reforge-render-test.sh Makefile
git commit -m "P3: ReForge GuppyScreen render test in qemu (800x480 fb)"
```

---

## Task 8: Stock-UI spike (extract + analyze + live test → REPORT)

**Files:** Create `spike-stockui/extract.sh`, `spike-stockui/analyze.sh`, `spike-stockui/REPORT.md`; Modify `Makefile`, `.gitignore`.

**Legal (spec §5):** firmwareExe is proprietary. Extract to a **gitignored** dir; commit ONLY the REPORT + scripts. Never commit firmwareExe/Qt blobs.

- [ ] **Step 1: `extract.sh`** — from `../fw-analysis/*/software-*.tar.xz` (+ `library-*.tar.xz`), extract `firmwareExe` + its Qt-embedded libs into `spike-stockui/extracted/` (gitignored). Confirm the dir is gitignored.

- [ ] **Step 2: `analyze.sh`** — on the extracted firmwareExe: `file`, `ldd`-equivalent (`readelf -d` / list NEEDED libs), `strings | grep` for the klippy socket path + `objects/query`/`gcode/script` API strings + FF object names (`flashforge_loadcell`, `tvocValue`, etc.). Output a structured summary (which Qt libs, which klippy API, which FF objects). Write findings into REPORT.md.

- [ ] **Step 3: Live test (if the qemu fb works — Task 4/7 succeeded).** In the qemu stock env (stock rootfs + the pinned fb), run firmwareExe against ReForge's **upstream** klippy (start ReForge's klippy with the AD5M printer.cfg; point firmwareExe at its socket). Observe: renders? connects? temps/move/status? what errors (missing FF objects)? Screenshot. If firmwareExe won't run under qemu (Qt/EGLFS issues), record that + fall back to the static analysis (Step 2) + a deferred on-device test note.

- [ ] **Step 4: Write `REPORT.md`** — a works/breaks matrix (render / connect / temps / jog / home / print-start / FF-calibration) + the root causes (FF custom klippy modules absent in upstream) + a **go/no-go recommendation**: implement STOCK mode as-is (basic) / port `flashforge_loadcell`+`flashforge_tvoc` for parity / drop it. Cite the evidence (static + live).

- [ ] **Step 5: Verify no proprietary blobs are tracked**
```
git status --porcelain spike-stockui/   # extracted/ must NOT appear
git ls-files spike-stockui/ | grep -iE 'firmwareExe|\.so$|extracted' && echo "FAIL: blob tracked" || echo "OK: no blobs tracked"
```

- [ ] **Step 6: Commit (report + scripts only)**
```
git add spike-stockui/extract.sh spike-stockui/analyze.sh spike-stockui/REPORT.md Makefile .gitignore
git commit -m "P3: stock-UI spike — firmwareExe vs upstream klippy report (no blobs)"
```

---

## Task 9: CI no-blob guard + docs/caveats

**Files:** Modify `.github/workflows/build.yml`, `docs/2026-06-01-plan3-installer-design.md` (status), add `packaging/README.md`.

- [ ] **Step 1: CI no-proprietary-blob check** — add a job/step that fails if any tracked file looks like a FlashForge/Qt blob (`git ls-files | grep -iE 'firmwareExe|libQt.*\.so|/extracted/'` → fail) and that the `.tgz` build + loopback-install test run (the qemu jobs may be too heavy for CI — gate them behind a manual/scheduled trigger like the Plan-1 repro job, or skip in CI and document).

- [ ] **Step 2: `packaging/README.md`** — document: how to `make tgz`, the subpackage layout, the **MCU caveat** (ReForge boots + web-reachable but won't print without Plan 4), the install/uninstall/dual-boot flow, and that the real device flash is deferred until the eMMC-reader restore is rehearsed.

- [ ] **Step 3: Validate YAML + commit**
```
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml')); print('yaml ok')"
git add .github/workflows/build.yml packaging/README.md docs/2026-06-01-plan3-installer-design.md
git commit -m "P3: CI no-blob guard + packaging docs/caveats"
```

---

## Done criteria for Plan 3

- [ ] `make tgz` produces `reforge-<ver>.tgz` (stock format; software contains the ReForge rootfs; md5sum checks).
- [ ] `make validate-loopback` PASSES (install lands in `/data/.reforge`, hook installed, nothing outside `/data` touched).
- [ ] qemu test kernel boots under `-M virt` with `/dev/fb0` = 800×480×32 (vendor path or documented generic fallback).
- [ ] `make qemu-update` PASSES at the minimum bar (install → ReForge boots in qemu); level achieved recorded.
- [ ] `make qemu-render` shows GuppyScreen rendering to the 800×480 fb (screenshot).
- [ ] Stock-UI spike `REPORT.md` delivered with a go/no-go decision (static + live evidence).
- [ ] **No device flashed**; **no proprietary blobs tracked** (CI-guarded); Buildroot submodule unmodified.
- [ ] Docs state the MCU caveat + the deferred-flash gate.

**Next plan:** Plan 4 — P3.5 MCU firmware (build matching upstream Klipper MCU fw for mainboard+eboard, the flasher, v11 fallback) — the piece that makes a flashed ReForge actually drive the printer.
</content>
