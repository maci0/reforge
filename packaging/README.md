# ReForge Packaging

This directory contains the installer for the ReForge firmware overlay for the
FlashForge AD5M Pro (ARMv7, Allwinner T113-S3).

---

## Stock MCU compatibility

The 2026-06-02 live-mode hardware trial reached klippy `ready` with both stock MCUs and
real temperatures after a manual relaunch when the MCUs retained another
configuration’s CRC (for example after Forge-X). `S60klipper` has no respawn; see the
[open startup issue](../docs/BACKLOG.md#live-klippy-respawn-after-crc-mismatch-auto-restart).
No install-mode hardware trial is recorded. Plan 4 is not required for that MCU link. The earlier `query_adxl345`
version-mismatch explanation was corrected by source review on 2026-06-04;
see [MCU firmware & config](../docs/reverse-engineering/ad5m-mcu-firmware-and-config.md).

---

## What the `.tgz` Is

`make tgz` produces `packaging/dist/reforge-<ver>.tgz`, a **stock-format FlashForge
OTA package** — a plain tar of xz-compressed subpackages plus a `flashforge_init.sh`
script.  Once named `Adventurer5MPro-*.tgz` on the stick, the stock `auto_run.sh`
unpacks and runs it exactly like an official FlashForge update.

### Subpackage Layout

```
reforge-<ver>.tgz
├── flashforge_init.sh          ← entry point; stock updater runs this
├── software-<ver>.tar.xz       ← ReForge rootfs overlay (klipper, moonraker,
│                                   mainsail, busybox httpd, guppyscreen, boot glue)
├── library-<ver>.tar.xz        ← stub (the rootfs is self-contained)
├── control-<ver>.tar.xz        ← reserved stub (see below; not the klipper13 images)
└── md5sum.list                 ← md5 of the three .tar.xz files
```

`software-<ver>.tar.xz` carries its own inner `md5sum.list` of every file; the
installer verifies that inner list before moving the tree into place. The
`library-` and `control-` subpackages are still reserved stubs:
`packaging/build-tgz.sh` packs `control-stub/RESERVED-FOR-MCU-PLAN4` and does
not read `klipper13` output. Optional `BR2_PACKAGE_KLIPPER13` source-builds
mainboard and toolhead images into the rootfs at `/opt/klipper/firmware/`
(see `br-external/package/klipper13/README.md`); the default defconfig does not
select that package, and this `.tgz` does not flash those images.

---

## Build

```sh
make tgz
# output: packaging/dist/reforge-<ver>.tgz
```

Version is read from `packaging/VERSION`.

---

## Before You Install — Other Mods Must Be Cleanly Uninstalled

ReForge expects the device to be running **clean stock firmware**. If you have
another third-party mod installed — most commonly **forge-x**, but the same
rule applies to **Helper Script / zmod / kAIO** or anything else that drops
files into `/etc/init.d/`, `/opt/config/`, `/data/.mod/`, `/root/`, or
`/opt/klipper/klippy/extras/` — you **must** run that mod's official
uninstaller **before** installing ReForge.

Why: ReForge owns the boot chain via `/etc/init.d/S01reforge` and chroots into
`/data/.mod/.reforge/`. Another mod sitting at `/etc/init.d/S00init` (the
forge-x slot) or `/data/.mod/.forge-x/` will:

- Run *first* in `rcS` (lower S?? number wins) and bring up its own Klipper /
  Moonraker against `/data/`, racing ReForge's chroot stack for the printer
  serial port, the Moonraker HTTP port, and the GuppyScreen framebuffer.
- Leave dropbear or other long-running daemons running beside ReForge's stack,
  doubling resident-set pressure on the 128 MB box.
- Leave stock state modified (`/etc/hosts`, `/opt/klipper/klippy/extras/`, MCU
  firmware staging at `/opt/PROGRAM/`), so a `SKIP_MOD` stock boot or a later
  uninstall finds it in an inconsistent shape.

Specifically for forge-x: run **`/data/.mod/.forge-x/uninstall.sh`** (or the
equivalent path in your install), reboot to stock, confirm `firmwareExe`
starts normally and `ls /etc/init.d/` shows no `S00init` / `S55boot` /
`S60dropbear` / `S98camera` / `S98zssh` / `S99root` symlinks, then install ReForge.

A stock USB `.tgz` update does not establish a clean mod-free baseline. The
captured 5.1.4 updater replaces selected components but leaves mod paths such as
`/etc/init.d/S00init`, `/opt/config/mod` and `/data/.mod/.forge-x` intact. If the
uninstaller is unavailable, use the [recovery runbook](../tools/recovery/RUNBOOK.md)
and verify mod removal before installing; do not bypass the conflict check merely
because a stock update completed.

ReForge's installer (`packaging/flashforge_init.sh`) runs a defensive
pre-flight check and **refuses to proceed** if it detects a known competing
mod — see the `pre_install_conflict_check` function. You can override the
refusal with `REFORGE_FORCE_OVER_OTHER_MOD=1`, but that path is unsupported
and will probably brick the install.

---

## Install Flow

1. **Copy to USB.** The stock `auto_run.sh` only scans for `Adventurer5MPro-*.tgz`
   ([boot.md §4](../docs/boot.md#4-how-stock-fw-detects-a-usb-update-tgz--optauto_runsh)),
   so copy `reforge-<ver>.tgz` to a FAT USB stick under a matching name, e.g.
   `Adventurer5MPro-reforge-<ver>.tgz`. On boot `auto_run.sh` copies it to `/data/`
   and extracts it into `/data/update/`.
2. **`flashforge_init.sh`** is called by the stock `auto_run.sh` as
   `flashforge_init.sh Adventurer5MPro 0024`.  It:
   - Refuses to run over a competing mod (see above).
   - Validates machine type + PID.
   - Deletes any prior install before extracting `software-<ver>.tar.xz` to a temp
     directory on `/data` and checking its inner `md5sum.list`. Extraction or
     verification failure therefore leaves no prior install to recover.
   - Renames the verified temp directory to `/data/.mod/.reforge`.
   - Seeds the last-known-good copy (`mod` → `lkg`) used by [OTA rollback](../docs/ota.md).
   - Symlinks `/data/.mod/.reforge/.shell/reforge-boot` as `/etc/init.d/S01reforge`
     (the **boot hook**).
   - Writes the default screen mode (`SCREEN_MODE=HEADLESS`) to
     `/data/.mod/.reforge/config/screen.conf` and the `.installed` version stamp.
3. **Boot hook** (`S01reforge` / `reforge-boot`): on next boot, the stock `/etc/init.d/rcS`
   calls this script which:
   - Checks the **SKIP_MOD** guard (see Dual-Boot below).
   - Bind-mounts `/data/.mod/.reforge` at `/reforge`, then mounts `proc`, `sys`,
     `dev`, `run`, `tmp` and `/data` into it (`.shell/reforge-chroot.sh`).
   - Boots the toolhead MCU and runs the trial/LKG check.
   - Replaces itself with `chroot /reforge /mod/start.sh`, which starts the ReForge
     services in the background. When that process exits, stock `rcS` continues. See [boot.md §7](../docs/boot.md#7-installed-reforge-boot-the-chroot-service-chain).

**Stock kernel, partitions, and FlashForge binaries are never modified.**
A stock USB `.tgz` can recover an install only while boot still reaches `auto_run.sh`;
otherwise use [RUNBOOK Path B](../tools/recovery/RUNBOOK.md).

---

## Uninstall

`make tgz` also writes `packaging/dist/reforge-uninstall-<ver>.tgz`, a stock-format
package whose `flashforge_init.sh` removes the `/etc/init.d/S01reforge` symlink and
`/data/.mod/.reforge` (the empty `/reforge` mountpoint directory stays). Install it from
USB like the installer (renamed to `Adventurer5MPro-*.tgz`), or run it over SSH:

```sh
# On the printer:
mkdir -p /tmp/reforge-uninstall
tar -xf reforge-uninstall-<ver>.tgz -C /tmp/reforge-uninstall
sh /tmp/reforge-uninstall/flashforge_init.sh
```

---

## Dual-Boot (SKIP_MOD)

To boot stock firmware without uninstalling ReForge:

```sh
# On the printer — persistent skip (survives reboots until removed):
touch /data/.mod/.reforge/SKIP_MOD
rm /data/.mod/.reforge/SKIP_MOD   # to re-enable ReForge
```

`reforge-boot` also honours `/tmp/SKIP_MOD`, `/tmp/SKIP_MOD_SOFT` and
`/tmp/SKIP_MOD_HARD`, but `/tmp` is tmpfs, so those only take effect when an earlier
hook creates them in the same boot; touching one before a reboot does nothing.
`SCREEN_MODE=STOCK` in `screen.conf` is a persistent alternative.

When any SKIP_MOD marker is present, `reforge-boot` exits immediately and the stock
firmware stack continues normally.  The stock `firmwareExe` UI runs as if ReForge were
not installed.

---

## Screen Modes

Installed Mode 2a still launches the stock UI after ReForge starts, even in GUPPY
mode; it can contend for the framebuffer and MCU ports. See the
[open install-mode issue](../docs/BACKLOG.md#mode-2-install-stock-ui-still-starts-cloud-block-misses-it).

Configured in `/data/.mod/.reforge/config/screen.conf` (`SCREEN_MODE=<mode>`).

| Mode | Description | Status |
|------|-------------|--------|
| `HEADLESS` | No display daemon. Mainsail/Moonraker served over HTTP. **Default.** | Implemented |
| `GUPPY` | GuppyScreen LVGL touchscreen UI on `/dev/fb0`. | Implemented (Plan 2) |
| `HELIX` | HelixScreen lab/eval UI; no-op unless built with `BR2_PACKAGE_HELIXSCREEN=y`. | Lab |
| `STOCK` | Skip ReForge for the boot (`reforge-boot` touches `/tmp/SKIP_MOD`), so stock `firmwareExe` runs against stock Klipper. | Implemented |

Running `firmwareExe` against **ReForge's** Klipper instead is feasibility-confirmed
(below) but not implemented.

### Stock UI on ReForge's Klipper — Feasibility (lab/spike-stockui, Plan 3)

The Plan 3 spike confirmed it is feasible (**GO — Option A**):

- `firmwareExe` renders to `/dev/fb0` via Qt4 LinuxFB — **confirmed** by qemu test.
- `firmwareExe` connects to Klipper at `/tmp/uds` using **standard upstream JSON-RPC**
  — no proprietary protocol gap.
- All required Klipper objects (`objects/query` payload) are available in upstream
  Klipper.  The only work is adding `[temperature_sensor weightValue/tvocValue]` and
  `[gcode_button btn_power]` entries to `printer.cfg` — no custom modules.
- Constraint: `firmwareExe` is **soft-float ABI** and must run in the stock soft-float
  environment, not inside the ReForge hard-float chroot.

Full spike findings: `docs/research/ui-camera/2026-06-01-stock-ui-spike.md` (spike scripts live in `lab/spike-stockui/`).
`make qemu-stockui-real` shows the stock home screen rendering against real upstream
Klipper under qemu.

---

## Validation (Without Flashing)

### Loopback Test

This legacy test does not validate the current install layout; see the
[test limitation](../tests/README.md#loopback-install-test).

```sh
make validate-loopback
```

Runs `flashforge_init.sh` with `REFORGE_SKIP_ARCH_CHECK=1`, `REFORGE_DATA_ROOT`
pointing at a loopback-mounted ext4 image and `REFORGE_INITD_DIR` at a scratch
directory. Its assertions still use the old layout. It needs sudo for loop
mounts and mkfs, but no printer.

### qemu Harness

The `tests/qemu-harness/` directory contains a qemu-system-arm test harness
that boots a virt-machine kernel with the built ReForge rootfs and runs
install, boot, web-reachability, and GUI-render tests.

```sh
make qemu-kernel    # build the virt ARM kernel (heavy, one-time)
make qemu-update    # run the update-process test (sudo)
make qemu-render    # run the GuppyScreen render test (rootless)
```

These are local-only and need `make rootfs` plus `make qemu-kernel`; `qemu-update`
needs sudo. The stock-UI gates additionally need the golden dump and
`make qemu-stock-rootfs`. See the [harness guide](../tests/qemu-harness/README.md)
for each target’s inputs and LIVE versus FLOOR results.

---

## Proprietary Blob Policy

The repo must **never track** FlashForge proprietary blobs (`firmwareExe`, Qt `.so`
libraries, `/opt/PROGRAM/` contents).  The spike extracts them only to
`lab/spike-stockui/extracted/` which is gitignored.

A CI job (`no-blobs` in `.github/workflows/build.yml`) fails if any tracked file path
matches these patterns — providing an automated guard against accidental commits.

## Known follow-ups
- **`reforge-boot` mount-unwind on failure:** the boot hook runs under `set -e`; a
  failed chroot bind-mount aborts mid-sequence, leaving partial mounts until reboot
  without an unwind `trap`. The uninstaller’s mount matcher still uses
  `/data/.mod/.reforge`, so it does not reliably match today’s `/reforge/*` mounts.
  Reboot clears residual runtime mounts; do not assume uninstall proves they are gone.
- The canonical `reforge-boot` lives in the rootfs overlay
  (`br-external/board/reforge/rootfs-overlay/.shell/reforge-boot`) — it ships inside the
  rootfs; there is intentionally no copy under `packaging/`.

## Minimal stock footprint (design guarantee)
ReForge installs as an overlay whose persistent changes to the stock rootfs are the
symlink `/etc/init.d/S01reforge → /data/.mod/.reforge/.shell/reforge-boot` (written by
the installer) and the empty `/reforge` mountpoint directory (created by `reforge-boot`
on first boot). Everything else is **self-contained**:
- the entire ReForge stack lives in `/data/.mod/.reforge` (on `/data` = `mmcblk0p7`, not the stock rootfs);
- klippy/moonraker use their **own** configs (`/etc/reforge/{printer.cfg,moonraker.conf}` inside the chroot) — ReForge does **not** read or write the stock `/opt/config`;
- the cloud-block edits the **chroot's** `/etc/hosts`, never the stock one (so it does not cover a stock `firmwareExe`; see [security findings](../docs/security-findings.md));
- `reforge-boot` only sets up **transient** runtime mounts (`/reforge` plus proc/sys/dev/run/tmp/data inside it) — these modify nothing on disk and are gone on reboot; uninstall’s stale mount matcher is not a reliable cleanup gate.

So **uninstall = delete that symlink + `/data/.mod/.reforge`**, leaving only the empty
`/reforge` directory on the stock rootfs. See the validation section above for
the limits of the legacy loopback test.
