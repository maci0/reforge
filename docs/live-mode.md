# Live mode — run ReForge from USB, zero eMMC writes

Live mode boots the **entire ReForge stack from a USB stick** without installing
anything. The eMMC is **never** written — pull the stick, reboot, and the printer
is back to pristine stock. It's how you trial ReForge on real AD5M / AD5M Pro
hardware with **no brick risk**.

| | Live mode | Install (`.tgz`) |
|---|---|---|
| Where it runs | USB stick (loop-mounted image) | eMMC (`/data/.reforge`) |
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

1. **insmods three kernel modules** shipped next to it on the stick — the stock
   5.4.61 kernel has **none** of them (verified on hardware): `loop.ko` (to
   loop-mount an image file), `crc32_generic.ko` (the `crc32` algo F2FS checks at
   mount — the kernel only has `crc32c`), and `f2fs.ko`. Each insmod is a no-op if
   the symbol is already present.
2. **loop-mounts `reforge-live.f2fs`** (the ReForge rootfs as an F2FS image — FAT
   can't host a Linux rootfs's symlinks/perms) as the chroot root.
3. binds `proc`/`sys`/`dev`/`run` + a **tmpfs `/data`** into the chroot — the
   install path binds the eMMC `/data` (mmcblk0p7); live mode uses tmpfs so **no
   eMMC partition is touched**.
4. `REFORGE_LIVE=1 chroot … /mod/start.sh`, then **blocks forever** — so stock
   never reaches `umount /mnt` and never launches its own UI. ReForge owns the box.

`REFORGE_LIVE=1` tells the boot/LKG scripts to skip the persistent trial/LKG
bookkeeping (that's for installs; live mode reboots clean by removing the USB).

## The three modules

Built by `modules/f2fs-bsp/build.sh` against the Tina BSP — exact vermagic
`5.4.61 SMP preempt mod_unload ARMv7 p2v8`, `depends=` empty (standalone), same
recipe as `modules/zram-bsp`. Committed prebuilt under `modules/f2fs-bsp/dist/`.

The `loop.ko` build also patches `loop.c` with
`MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver)` — it
calls `vfs_getattr`, which this Android-GKI kernel exports into that namespace; the
BSP source omits the import because loop was never built as a module here.

**Verified end-to-end on real hardware:** all three load and an F2FS image
loop-mounts read-write.

## Build & use

```sh
make rootfs                       # the ReForge image (build/output/images/rootfs.tar)
make live-usb                     # -> packaging/dist/reforge-live-<ver>.tar.gz
# extract onto the root of any FAT32 USB stick (no dd, no dedicated stick):
tar xzf packaging/dist/reforge-live-<ver>.tar.gz -C /path/to/usb/
```

Then: insert the stick, power on the printer — ReForge boots from USB. To return to
stock, **pull the stick and reboot**. The build is fully rootless (`mkfs.f2fs` +
`sload.f2fs` bake the F2FS image, `tar`+`gzip` pack it); extracting onto a FAT32 stick
needs no `dd` and no dedicated stick — the stock `auto_run` picks up `flashforge_init.sh`
off any FAT USB.

USB layout (FAT32):

```
/flashforge_init.sh    the live launcher
/net-up.sh             best-effort WiFi bring-up (sourced by the launcher)
/loop.ko               loop block driver
/crc32_generic.ko      the 'crc32' algo F2FS needs at mount
/f2fs.ko               F2FS filesystem
/reforge-live.f2fs     the ReForge rootfs (loop-mounted chroot root)
```

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
  SSH reachable.** See `docs/2026-06-02-ad5m-mcu-firmware-and-config.md` and
  `docs/specs/2026-06-02-live-mode-wifi.md`.
- **klippy "waiting to initialize" — was a CONFIG error, not a host↔MCU version wall.**
  The stall was klippy aborting config parse on FlashForge-fork sections vanilla Klipper
  lacks (`flashforge_loadcell`/`flashforge_tvoc`) + a missing `[extruder] rotation_distance`
  + a `[probe] z_offset`. After rebasing the config on the stock/ZMod form (standard
  `MAX31856`/`MAX31865` sensors), **klippy reaches `ready` and drives BOTH stock v11 MCUs**
  (`mcu` + `eboard`, real temps) — no MCU reflash / Plan 4 needed. The only version-locked
  piece is `[adxl345]` input-shaper *calibration* (`query_adxl345` format changed v11→v13),
  left gated. Full analysis: `docs/2026-06-02-ad5m-mcu-firmware-and-config.md`.

## Caveats

- The USB must stay inserted — it *is* the rootfs; running from USB is slower than eMMC.
- The stock UI (`firmwareExe`) does not run — live mode runs ReForge's GuppyScreen /
  headless. That's the point.
- `/data` is tmpfs (ephemeral). Persistent live state across reboots is a future
  option (a writable dir on the FAT stick).
- **Network works** (`net-up.sh` joins WiFi before the launcher blocks; `ensure_sshd`
  brings up SSH) — Moonraker/Mainsail/SSH are reachable. See the trial findings.
- **klippy reaches `ready` and drives the stock v11 MCUs** with the rebased config; only
  adxl345/input-shaper *calibration* is version-locked (gated). No MCU reflash needed to run.

## See also

- `docs/specs/2026-06-02-reforge-live-mode.md` — the design spec (archival snapshot)
- `docs/architecture.md` — the overlay-on-stock chroot model live mode mirrors
- `tests/qemu-harness/README.md` — the qemu gates
