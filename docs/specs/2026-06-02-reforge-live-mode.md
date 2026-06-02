# ReForge Live Mode — run from USB, zero eMMC writes

**Goal:** test ReForge on real AD5M/Pro hardware **without installing** — boot the
full stack from a USB stick, touch the eMMC **never**, so pulling the USB and
rebooting returns to pristine stock. No brick risk.

## Why it works (the stock hook)

The stock `auto_run.sh` scans a FAT USB (`/dev/sda`) on every boot and, besides
the `.tgz` install path, runs **any `flashforge_init.sh` at the USB root directly
from `/mnt`**:

```sh
if [ -f /mnt/flashforge_init.sh ]; then
    chmod a+x /mnt/flashforge_init.sh
    /mnt/flashforge_init.sh ${MACHINE} ${PID}
    if [ $? -eq 0 ]; then umount /mnt; sleep 100000; fi   # stock UI never launches
fi
```

It is run from the USB (no copy to eMMC). If our launcher **never returns**, stock
never reaches `umount /mnt` / its own UI — ReForge owns the machine, the USB stays
mounted, and nothing is written to eMMC.

## Layout (FAT USB)

```
/flashforge_init.sh      the LIVE launcher (this design)
/loop.ko                 loop block driver (to loop-mount the rootfs image)
/crc32_generic.ko        the 'crc32' crypto algo F2FS needs at mount
/f2fs.ko                 F2FS filesystem
/reforge-live.f2fs       an F2FS image = the ReForge chroot root (the reforge rootfs)
```

(FAT can't host a Linux rootfs — symlinks/perms — so the rootfs is a **filesystem
image** on the FAT stick, loop-mounted by the launcher.)

**Why F2FS + three shipped `.ko`s:** F2FS is flash-friendly, but the stock 5.4.61
kernel (probed on the device) ships **none** of what's needed: no loop driver
(`# CONFIG_BLK_DEV_LOOP is not set` → can't loop-mount any image file), no plain
`crc32` crypto (only `crc32c` → F2FS mount dies `Cannot load crc32 driver`), and no
F2FS. So `modules/f2fs-bsp/build.sh` builds all three against the Tina BSP (same recipe
as `modules/zram-bsp`, exact vermagic `5.4.61 SMP preempt mod_unload ARMv7 p2v8`,
`depends=` empty → standalone). The `loop.ko` build also patches `loop.c` to
`MODULE_IMPORT_NS(VFS_internal_…)` (it uses `vfs_getattr`, namespaced in this Android-GKI
kernel — the BSP source omits the import since loop was never a module here).

The launcher `insmod`s loop → crc32 → f2fs (each a no-op if already present), then
loop-mounts the F2FS rootfs. **Verified end-to-end on real hardware:** all three load
and an F2FS image loop-mounts read-write. Each insmod no-ops when the symbol is already
present (e.g. the qemu gate kernel), and the launcher falls back to a non-F2FS/direct
mount when modules are absent.

## The launcher

Mirrors `reforge-boot`, but rooted on the USB image with a **tmpfs `/data`**:

1. `mount -o loop /mnt/reforge-live.ext4 /tmp/.reforge-live`  (chroot root; `/tmp` is tmpfs)
2. bind `proc`/`sys`/`dev`/`run` + a fresh **tmpfs** for `/tmp` and for `/data`
   into the chroot — the on-device path binds the eMMC `/data` (mmcblk0p7); live
   mode uses tmpfs so **no eMMC partition is touched**.
3. `REFORGE_LIVE=1 SCREEN_MODE=GUPPY chroot /tmp/.reforge-live /mod/start.sh`
4. block forever (`while true; do sleep 3600; done`) so stock never proceeds.

`REFORGE_LIVE=1` tells the boot/LKG scripts to **skip the trial/LKG bookkeeping**
(it's for persistent installs; live mode reboots clean by removing the USB).

## The brick-safe invariant

**Never write the eMMC.** No partition writes, no init edits, no `/data/.reforge`
install. All runtime state (klippy logs, moonraker DB, zram) lives in the
loop-mounted USB image (persistent) or tmpfs (ephemeral). Worst case — USB yanked
mid-run — the chroot's fs vanishes but the eMMC is intact; reboot recovers.

## What it validates on hardware

Real Klipper ↔ the real eboard MCU, the real 480×800 panel, the whole stack — the
things qemu can't exercise — with zero flashing.

### Trial result (2026-06-02, AD5M Pro `kunos`)

First hardware run (via `tools/release/verify-live-trial.sh`). **Brick-safe model
confirmed:** ReForge booted live from USB (GuppyScreen on the panel); the eMMC was
untouched — `/data/.reforge` absent before AND after, print files intact, no residue,
modules unloaded on reboot, forge-x pristine afterward. Findings: (1) a `crc32`
module-skip bug (substring match of `crc32c`) blocked the F2FS mount on the first
attempt — fixed to `grep -qw`; (2) no network in live mode — the launcher blocks
`auto_run` before the stock WiFi init runs, so only the local GuppyScreen works (Moonraker/
Mainsail/SSH need a planned `wlan0`-in-launcher fix); (3) klippy stays "waiting to
initialize" — host↔MCU Klipper version mismatch (the MCUs carry forge-x's flashed
firmware; ReForge ships a different commit). Full write-up: `docs/live-mode.md`.

## Caveats

- USB must stay inserted (it *is* the rootfs); running from USB is slower than eMMC.
- The stock UI (`firmwareExe`) does not run — live mode runs ReForge's GuppyScreen
  / headless. That is the point.
- `/data` is tmpfs by default (ephemeral). Persistent live state across reboots is a
  future option (a writable dir on the FAT USB).

## qemu gate (prove zero-write before touching hardware)

`tests/qemu-harness/live-mode-test.sh` (rootless):

1. Build the stock-rootfs eMMC image + record a checksum of its bytes.
2. Build the live USB image (FAT: launcher + `reforge-live.ext4`).
3. Boot stock under qemu with the eMMC + the USB presented as `/dev/sda`
   (`usb-storage`), so the stock `auto_run` hook fires the live launcher; or, if
   the test kernel lacks USB host support, run the launcher via an injected init
   hook (same code path) with the live image on a 2nd disk.
4. **Assert:** the ReForge stack came up **and** the eMMC image is **byte-identical**
   to its pre-boot checksum.

## Build

`make live-usb` → `tools/release/build-live-usb.sh` → `packaging/dist/reforge-live-<ver>.tar.gz` (extract onto a FAT32 USB root — no dd)
(dd to a USB stick), assembled from `build/output/images/rootfs.tar` + the launcher.
