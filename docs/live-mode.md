# Live mode — run ReForge from USB, zero eMMC writes

Live mode boots the **entire ReForge stack from a USB stick** without installing
anything. The eMMC is **never** written — pull the stick, reboot, and the printer
is back to pristine stock. It's how you trial ReForge on real AD5M / AD5M Pro
hardware with **no brick risk**.

| | Live mode | Install (`.tgz`) |
|---|---|---|
| Where it runs | USB stick (real F2FS partition) | eMMC (`/data/.reforge`) |
| eMMC writes | **none** | overlay + LKG bookkeeping |
| Persistence | none (USB only; `/data` is tmpfs) | survives reboot |
| Revert | pull USB + reboot | OTA rollback / recovery |
| Stock UI | does **not** run (ReForge owns the machine) | does not run |

## How it works

The stock `auto_run.sh` scans a FAT USB on every boot and runs any
`flashforge_init.sh` it finds at the USB root — **directly from `/mnt`, off the
stick** (no copy to eMMC):

```sh
if [ -f /mnt/flashforge_init.sh ]; then
    /mnt/flashforge_init.sh ${MACHINE} ${PID}
    if [ $? -eq 0 ]; then umount /mnt; sleep 100000; fi   # stock UI never launches
fi
```

ReForge's live launcher (`packaging/live/flashforge_init.sh`) uses that hook. It:

1. **insmods two kernel modules** shipped on the FAT partition — the stock 5.4.61
   kernel has neither (verified on hardware): `crc32_generic.ko` (the `crc32` algo
   F2FS checks at mount — the kernel only has `crc32c`), and `f2fs.ko`. Each
   insmod is a no-op if the symbol is already present.
2. **finds the sibling F2FS partition** on the same USB stick (by label
   `reforge-live` via `blkid`, falling back to deriving p2 from p1's device path,
   falling back to an F2FS-magic scan of `/dev/sd?[2-4]`) and **mounts it directly
   as a real block device** as the chroot root. No loop driver, no loop file: the
   rootfs is just partition 2.
3. binds `proc`/`sys`/`dev`/`run` + a **tmpfs `/data`** into the chroot — the
   install path binds the eMMC `/data` (mmcblk0p7); live mode uses tmpfs so **no
   eMMC partition is touched**.
4. `REFORGE_LIVE=1 chroot … /mod/start.sh`, then **blocks forever** — so stock
   never reaches `umount /mnt` and never launches its own UI. ReForge owns the box.

`REFORGE_LIVE=1` tells the boot/LKG scripts to skip the persistent trial/LKG
bookkeeping (that's for installs; live mode reboots clean by removing the USB).

## The two modules

Built by `modules/f2fs-bsp/build.sh` against the Tina BSP — exact vermagic
`5.4.61 SMP preempt mod_unload ARMv7 p2v8`, `depends=` empty (standalone), same
recipe as `modules/zram-bsp`. Committed prebuilt under `modules/f2fs-bsp/dist/`.

**Verified end-to-end on real hardware:**

- *2026-06-02 (loop-on-FAT layout, three modules):* `loop.ko` + `crc32_generic.ko`
  + `f2fs.ko` all loaded clean; the loop-mounted F2FS image came up read-write.
- *2026-06-04 (2-partition layout, two modules):* `crc32_generic.ko` + `f2fs.ko`
  load clean; `loop.ko` is no longer built or shipped (its `MODULE_IMPORT_NS(VFS_internal_…)`
  patch on `loop.c` is gone with it). On `kunos` (AD5M Pro), stock auto_run picked
  up the FAT p1, the launcher's `find_f2fs_dev()` resolved `/dev/sda2`, and the
  F2FS partition mounted with `discard` enabled (the old loop-on-FAT path had to
  pass `nodiscard` to silence `loop0 I/O error, ret -5` spam). Captured evidence:
  `[reforge-live] rootfs device: /dev/sda2`, `F2FS-fs (sda2): Mounted with
  checkpoint version = 6a79795b`, no `loop` in `lsmod`, no `loop.ko` in the
  insmod log.

## Build & use

```sh
make rootfs                       # the ReForge image (build/output/images/rootfs.tar)
make live-usb                     # -> packaging/dist/reforge-live-<ver>.img.gz
```

Flash the disk image onto a USB stick (≥ ~600 MiB) and insert it:

```sh
# Linux:
zcat packaging/dist/reforge-live-<ver>.img.gz | sudo dd of=/dev/sdX bs=4M status=progress && sync
# Cross-platform: open the .img.gz in balenaEtcher / Rufus / GNOME Disks "Restore Disk Image".
```

Then: power on the printer — ReForge boots from USB. To return to stock, **pull the
stick and reboot**. The build itself is fully rootless (`sfdisk` writes the MBR to a
plain file, `mtools` (`mformat`/`mcopy`) builds the FAT partition, `mkfs.f2fs` +
`sload.f2fs` build the F2FS partition, `dd` splices them into the disk image).

USB layout (MBR, 2 partitions):

```
p1 vfat  (label REFORGE_LIV, ~64 MiB)   stock auto_run mounts this at /mnt
  /flashforge_init.sh    the live launcher (the stock auto_run hook)
  /net-up.sh             best-effort WiFi bring-up (sourced by the launcher)
  /crc32_generic.ko      the 'crc32' algo F2FS needs at mount
  /f2fs.ko               F2FS filesystem
p2 f2fs  (label reforge-live, rootfs + slack)   the ReForge rootfs (chroot root)
```

### Why two partitions instead of a loop-mounted image

The original layout was a single FAT32 partition that held a `reforge-live.f2fs`
image file the launcher loop-mounted. That worked on hardware (after the `crc32`
module-skip bug fix) but had three real costs:

1. needed `loop.ko` (with a custom `MODULE_IMPORT_NS(VFS_internal_…)` patch on
   `loop.c`, because loop was never a module in this BSP)
2. F2FS DISCARD/TRIM over a loop-on-FAT failed with `loop0 I/O error, ret -5` and
   spammed the log — the launcher had to pass `nodiscard` to silence it
3. the FAT 4 GiB file size cap held the rootfs ceiling

The 2-partition layout removes all three: the rootfs is a real F2FS block device.
Cost: the stick has to be flashed with a partitioned `.img` (`dd` or Etcher) rather
than an "extract a tarball onto an existing FAT stick" tarball.

## The brick-safe invariant

**Never write the eMMC.** No partition writes, no init edits, no `/data/.reforge`
install. Runtime state (klippy logs, moonraker DB, zram) lives in the loop-mounted
USB image (persistent) or tmpfs (ephemeral). Worst case — USB yanked mid-run — the
chroot's fs vanishes but the eMMC is intact; reboot recovers.

The qemu gate `tests/qemu-harness/live-mode-test.sh` (`make qemu-live`, rootless)
enforces it: it boots the launcher with an eMMC stand-in disk and **asserts the
eMMC bytes are identical before and after** and the stack came up. CI-gated.

## Hardware trial (2026-06-02, AD5M Pro `kunos`)

First real-hardware run, verified with `tools/release/verify-live-trial.sh`
(baseline → live → stock). **Result: the brick-safe model holds on real hardware.**
ReForge booted live from the USB (GuppyScreen on the panel), and a clean before/after
showed the eMMC was **untouched**: `/data/.reforge` ABSENT both before and after, the
user's print files intact, no `/mod` or ReForge residue, the live modules unloaded on
reboot, and forge-x came back pristine. Pulling the stick + rebooting returned to stock.

Findings from the trial — **all three since resolved** (same day):

- **`crc32` module-skip bug — fixed during the trial** (`grep -q "crc32"` matched the
  device's `crc32c` and skipped `crc32_generic.ko`, so the F2FS mount failed and the
  launcher fell through to the stock UI). Fixed to a word match (`grep -qw`); without
  it the trial wouldn't have booted. See `packaging/live/flashforge_init.sh`.
- **No network — FIXED.** Added `packaging/live/net-up.sh` (sourced by the launcher
  before it blocks): brings `wlan0` up reusing the stock driver + creds. Two real bugs
  were root-caused + fixed: the stored network had `disabled=1` (a plain
  `wpa_supplicant -c` never associates — net-up strips it into a tmpfs copy), and
  `/etc/wifi/udhcpc_wlan0` is an OpenWrt procd *service-wrapper* (not a udhcpc event
  script) that `killall`s udhcpc — net-up uses busybox's default lease script instead.
  Plus `ensure_sshd` (start dropbear if stock hasn't) and a `net_only` debug mode (wifi
  + sshd, skip the stack). **Proven on hardware: the box joined WiFi (got a DHCP lease),
  SSH reachable.** See `docs/reverse-engineering/ad5m-mcu-firmware-and-config.md`.
- **klippy "waiting to initialize" — was a CONFIG error, not a host↔MCU version wall.**
  The stall was klippy aborting config parse on FlashForge-fork sections vanilla Klipper
  lacks (`flashforge_loadcell`/`flashforge_tvoc`) + a missing `[extruder] rotation_distance`
  + a `[probe] z_offset`. After rebasing the config on the stock/ZMod form (standard
  `MAX31856`/`MAX31865` sensors), **klippy reaches `ready` and drives BOTH stock v11 MCUs**
  (`mcu` + `eboard`, real temps) — no MCU reflash / Plan 4 needed. The only version-locked
  piece is `[adxl345]` input-shaper *calibration* (`query_adxl345` format changed v11→v13),
  left gated. Full analysis: `docs/reverse-engineering/ad5m-mcu-firmware-and-config.md`.

## Caveats

- The USB must stay inserted — it *is* the rootfs; running from USB is slower than eMMC.
- The stock UI (`firmwareExe`) does not run — live mode runs ReForge's GuppyScreen /
  headless. That's the point.
- `/data` is tmpfs (ephemeral). Persistent live state across reboots is a future
  option (a writable dir on the FAT stick).
- **Network works** (`net-up.sh` joins WiFi before the launcher blocks; `ensure_sshd`
  brings up SSH) — Moonraker/Mainsail/SSH are reachable. See the trial findings.
- **klippy reaches `ready` and drives the stock v11 MCUs** with the rebased config; the
  `[adxl345]` / `[input_shaper]` sections stay enabled (matching stock 3.1.3 — see
  [`reverse-engineering/ad5m-mcu-firmware-and-config.md`](reverse-engineering/ad5m-mcu-firmware-and-config.md)).
  The only version-locked piece is the **`query_adxl345` calibration command** itself
  (`oid=%c rest_ticks=%u` on v11 vs `oid=%c clock=%u rest_ticks=%u` on v13) — a v13 host
  against a v11 MCU errors out on calibration. With ReForge's v0.11-matched host, calibration
  works against the native MCU. No MCU reflash needed to run.

## See also

- `docs/architecture.md` — the overlay-on-stock chroot model live mode mirrors
- `packaging/live/flashforge_init.sh` + `net-up.sh` — the launcher + WiFi bring-up (source of truth)
- `tests/qemu-harness/README.md` — the qemu gates
