# Live mode — run ReForge from USB (no install)

Live mode boots the **entire ReForge stack from a USB stick** without going
through the installer. On the 2026-06-02 AD5M Pro trial, pulling the stick and
rebooting returned to the previous system. Validation covers that unit and trial;
the persistent writes below still apply.

"Live" means booted from USB. The launcher does not install ReForge. It does
write: the first boot creates `/reforge` on the stock rootfs (p6), and
user-uploaded gcode lands on eMMC `/data` (p7), same as install mode. The
[Write topology](#write-topology) section lists each write.

| | Live mode | Install (`.tgz`) |
|---|---|---|
| Chroot ROOT (host-side) | `/reforge` (F2FS USB partition mounted here) | `/reforge` (rootfs bind-mounted here from `/data/.mod/.reforge`) |
| `/data` inside chroot | eMMC mmcblk0p7 (bind from host) | eMMC mmcblk0p7 (bind from host) |
| OS-level eMMC writes | launcher mountpoints on p6; optional HELIX state on p7; see [write topology](#write-topology) | overlay + LKG bookkeeping on p7 |
| User gcode persistence | eMMC `/data/` (visible to install too) | eMMC `/data/` |
| Config / Moonraker data | F2FS USB partition | eMMC `/data/.mod/.reforge/` |
| Klippy log (`/var/log → /tmp`) | tmpfs; lost on reboot | host `/tmp` bind; lost on reboot |
| Revert | pull USB + reboot | OTA rollback / recovery |
| Stock UI | does **not** run after successful stack startup; early launcher failure returns to stock | `auto_run.sh` still launches it after `S01reforge` returns (from source; no install-mode hardware trial recorded) |

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
2. **finds and mounts the F2FS rootfs** directly at `/reforge`. `F2FS_DEV` can
   override discovery; otherwise the launcher tries the configured label, a blkid
   F2FS-type search, the FAT partition's sibling, then a magic scan. See
   [`find_f2fs_dev()`](../packaging/live/flashforge_init.sh) for the exact order.
   There is no loop-mounted rootfs file.
3. sets up the chroot mounts via the shared `reforge-chroot.sh` helper — binds
   `proc`/`sys`/`dev`/`run` + a **fresh tmpfs `/tmp`** into `/reforge`, and binds the
   eMMC `/data` (mmcblk0p7) in so gcode uploads persist. See the
   [write topology](#write-topology) for launcher, service and user writes.
4. **boots the toolhead "eboard" MCU** (`chroot … /usr/bin/reforge-boot-eboard`) —
   right here, before banner/network/stack. The eboard (`/dev/ttyS1`) waits in a
   serial bootloader for an `A` (0x41) before starting its Klipper app; without this
   handshake klippy can never connect it and the toolhead stays dark. Best-effort.
   See [boot.md §8](boot.md).
5. `REFORGE_LIVE=1 chroot … /mod/start.sh`, then **blocks forever** — so stock
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

`reforge-live-<ver>.img.gz` is a compressed whole-disk image. Flash it onto a
USB stick (≥ ~600 MiB). Replace `/dev/sdX` with the disk you identified
(`lsblk` before and after inserting the stick). The write erases that entire
disk. Unmount every mounted partition on that USB disk before writing. Do not point `dd` at an internal disk.

```sh
version=$(cat packaging/VERSION)
zcat "packaging/dist/reforge-live-${version}.img.gz" | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
# Cross-platform: open the .img.gz in balenaEtcher / Rufus / GNOME Disks "Restore Disk Image"
# and select the USB disk, not a partition.
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

## Write topology

Live mode is **not** a zero-eMMC-write mode — it is "booted from USB with the
installer skipped". Known paths from the launcher and services are listed below;
this is not a whole-device write audit:

| What | Where | Storage | When |
|---|---|---|---|
| `mkdir -p /reforge` (one-time) | mountpoint inode on the stock **p6** rootfs (eMMC **p7 untouched**) | eMMC | First live boot on a fresh unit; no-op thereafter |
| F2FS mount + chroot setup | kernel mount table | RAM | Boot only |
| `klippy.log` | `/var/log/klippy.log`; Buildroot’s `/var/log` links to `/tmp` | tmpfs; lost on reboot | Runtime |
| moonraker SQLite DB + history | `/var/lib/moonraker/` inside chroot | F2FS USB | Runtime |
| `SAVE_CONFIG` (PID/shaper/mesh) | `/etc/reforge/printer.cfg` inside chroot | F2FS USB | Tuning events |
| Klippy UDS / lockfiles | `/tmp/klippy_uds` etc. | tmpfs | Runtime |
| Live-mode log | `/mnt/reforge-live.log` (FAT p1) | FAT USB | Per boot |
| Gcode uploads via Mainsail | `/data/` (factory `[virtual_sdcard] path: /data/`) | eMMC | Per upload |
| Print job state (stop/pause) | moonraker DB | F2FS USB | Per event |
| Optional HELIX cache/config/log directories | `/data/helixscreen/{cache,config,log}` | eMMC p7 | Startup when HELIX is built, selected and has a framebuffer |

The launcher creates `/reforge` on p6 and, if absent, the host `/data` mountpoint.
Chroot mountpoints are created on the USB rootfs. It does not mount over an installed
`/data/.mod/.reforge` tree. This does not guarantee p7 is unchanged: user uploads and
the optional HELIX service use the bound `/data`, and other stock processes are outside
this launcher’s write accounting. HELIX is not part of the default GuppyScreen image.

**User-action writes to eMMC: gcode uploads**, intentional. You upload via
Mainsail in live mode, pull the stick, and the gcodes are still in `/data/`.
An install on the same unit sees the same files at the same path. The launcher
has no switch for ephemeral gcodes; to keep uploads off the eMMC, point
`[virtual_sdcard] path` (set in `printer.base.cfg`) at a USB or tmpfs path
inside the chroot.

## The install-residue invariant

What live mode **does NOT** write to eMMC: any install state. No
`/data/.mod/.reforge/{mod,lkg,state,config,.installed}` install files are created by live
mode. Pull the USB stick and reboot to stock with no ReForge install state; the
empty `/reforge` mountpoint on p6 can remain. In particular,
stock's `/etc/init.d/` is unchanged, no `S01reforge` symlink, no
`/data/.mod/.reforge/mod` overlay. If you previously had an install, it is
left untouched at `/data/.mod/.reforge` — live mode mounts at `/reforge` and
no longer mounts over the install dir, so the install reappears as-is when the
USB is removed.

The qemu gate `tests/qemu-harness/live-mode-test.sh` (`make qemu-live`,
rootless) checks the eMMC stand-in via `debugfs`, but at the obsolete path
`/data/.reforge/{mod,lkg,trial,.installed}`. It does not inspect the current install
path `/data/.mod/.reforge` or its `state/` and `config/` directories, so it cannot
establish the install-residue invariant above. `make qemu-live-ota` has the same gap. CI does not run
the `qemu-*` targets (`.github/workflows/build.yml`).

## Hardware trial (2026-06-02, AD5M Pro `kunos`)

The first hardware run used `tools/release/verify-live-trial.sh` (baseline → live →
stock), before the F2FS-p2 layout. That [legacy helper](../tools/README.md) is not a
current write-audit gate; install-directory absence does not prove zero eMMC writes. ReForge booted from the USB (GuppyScreen on the
panel). The before/after comparison showed no install residue on that unit:
`/data/.mod/.reforge` ABSENT both before and after, the
user's print files intact, no `/mod` or ReForge residue, the live modules unloaded on
reboot, and the previous forge-x system came back. Pulling the stick + rebooting
returned to that system.

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
  SSH reachable.** See `packaging/live/net-up.sh`.
- **klippy "waiting to initialize" — was a CONFIG error, not a host↔MCU version wall.**
  The stall was klippy aborting config parse on FlashForge-fork sections vanilla Klipper
  lacks (`flashforge_loadcell`/`flashforge_tvoc`) + a missing `[extruder] rotation_distance`
  + a `[probe] z_offset`. After rebasing the config on the stock/ZMod form (standard
  `MAX31856`/`MAX31865` sensors), **klippy reaches `ready` and drives BOTH stock v11 MCUs**
  (`mcu` + `eboard`, real temps) — no MCU reflash / Plan 4 needed. The only version-locked
  piece was then believed to be `[adxl345]` calibration, which was left gated.
  That version explanation was corrected on 2026-06-04; see the
  [source analysis](reverse-engineering/ad5m-mcu-firmware-and-config.md) and current caveats below.

## Caveats

- The USB must stay inserted — it *is* the rootfs; running from USB is slower than eMMC.
- After successful startup, the stock UI is not launched; early launcher failure
  can return to `auto_run.sh` and the stock UI.
- `/data` inside the chroot is the **real eMMC p7** (bound in), so gcode uploads
  persist across reboots and are visible to an install on the same unit. Moonraker
  data/logs live on F2FS USB; `klippy.log` and `/tmp` are ephemeral tmpfs. See the
  [write topology](#write-topology).
- **Network works** (`net-up.sh` joins WiFi before the launcher blocks; `ensure_sshd`
  brings up SSH) — Moonraker/Mainsail/SSH are reachable. See the trial findings.
- **klippy can reach `ready` with both stock MCUs**, but the first config-CRC
  restart requires a manual relaunch: `S60klipper` has no respawn. See the
  [startup issue](BACKLOG.md#live-klippy-respawn-after-crc-mismatch-auto-restart).
- The trial's initial `query_adxl345` version explanation was corrected on
  2026-06-04. The current v0.11 host pin and enabled accelerometer configuration
  supersede the earlier disabled-calibration workaround; see
  [MCU firmware & config](reverse-engineering/ad5m-mcu-firmware-and-config.md).

## See also

- `docs/architecture.md` — the overlay-on-stock chroot model live mode mirrors
- `packaging/live/flashforge_init.sh` + `net-up.sh` — the launcher + WiFi bring-up (source of truth)
- `tests/qemu-harness/README.md` — the qemu gates
