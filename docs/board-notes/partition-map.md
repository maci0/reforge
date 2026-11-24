# eMMC partition map — FlashForge AD5M / AD5M Pro

Canonical layout of the device's onboard eMMC (`/dev/mmcblk0`), with GPT
offsets, sizes, filesystem types, mountpoints, and brick-safety tier.

**Source of truth:** GPT extracted from `tools/recovery/golden.img.gz` (the
unit-`kunos` clean stock dump; sha256 in `tools/recovery/golden.img.gz.sha256`,
size in `tools/recovery/golden.size`).
Verified against `tools/recovery/forge-x-20260531-152104.partitions.txt`
(raw `/proc/partitions` on the same unit while running forge-x).

**Boot-path correction (2026-10-25):** the partition geometry and p4 Android
image below remain captured evidence. The validated redundant environments
select `boot_uImage`, loading `uImage` and `sunxi.dtb` from FAT p1, not p4.
See the [boot reference](../boot.md#1-the-boot-chain-verified),
[rebuild evidence](stock-bringup-rebuild.md#reference-identity-and-configured-boot-path)
and [artifact hashes](stock-boot-artifacts.json). Earlier interpretations of
p4 as the active kernel source are superseded.

## Disk geometry

- **Device:** Allwinner T113-S3 onboard eMMC
- **Reported size:** 7 634 944 KiB = **7 456 MiB ≈ 7.28 GiB** (8 GB nominal)
- **Sector size:** 512 B (LBA)
- **Partition table:** GPT (the cmdline carries `gpt=1`; sfdisk reports a
  protective MBR + GPT). The cmdline also passes Android-style
  `partitions=NAME@mmcblkPART:NAME@mmcblkPART:…` so the names below match what
  init / `auto_run.sh` / forge-x scripts use to refer to each slot.

## The seven partitions

| # | Cmdline name | Start (LBA) | Size (LBA) | Start (MiB) | Size (MiB) | FS | Mount | Contents | Brick tier |
|---|---|---:|---:|---:|---:|---|---|---|---|
| **p1** | `boot-resource` | 73 728 | 68 876 | 36.0 | 33.6 | vfat | `/mnt/UDISK/p1` (read-only by U-Boot) | U-Boot resources, active `uImage` and `sunxi.dtb`, vendor splash images, MCU firmware staging, RTOS resource bundle | ⚠ **BOOT-CRITICAL** — corruption of the selected kernel/DTB can prevent userspace startup and USB recovery |
| **p2** | `env` | 142 604 | 2 048 | 69.6 | 1.0 | U-Boot env | n/a (raw block) | U-Boot environment (primary copy). `fw_setenv` writes here. | ⛔ **HARD-BRICK TIER** — invalid environments can prevent U-Boot from selecting a working boot path; **no FEL on this unit (USB0 pads internal, no UART) → eMMC-reader-only recovery** (RUNBOOK Path B). |
| **p3** | `env-redund` | 144 652 | 2 048 | 70.6 | 1.0 | U-Boot env (redundant) | n/a (raw block) | U-Boot environment, redundant copy | ⛔ **HARD-BRICK TIER** — same protection boundary as p2; redundancy may tolerate one invalid copy, but fallback is not a substitute for a rehearsed recovery path |
| **p4** | `boot` | 146 700 | 70 400 | 71.6 | 34.4 | Android boot.img | n/a (not selected by the validated boot environment) | Captured Android kernel/DTB/initramfs image (`mkbootimg`); its presence does not establish the active boot path. | ⚠ **MEDIUM** — a bad boot image can stop startup if selected by the environment; do not assume a USB `.tgz` restores p4. The [captured stock kernel updater](fw-upgrade-mechanisms.md#path-5-in-detail--kernel--library-update) writes p1 instead; without working userspace, use Path B. |
| **p5** | `dsp0` | 217 100 | 2 048 | 106.0 | 1.0 | raw (HiFi4 binary) | n/a (loaded by U-Boot) | HiFi4 DSP firmware. The T113-S3 has an audio DSP core; this is its boot image. | ⚠ **MEDIUM** — corruption blocks the DSP but not the AP; AP-only boot still works (DSP would be silent). |
| **p6** | `rootfs` | 219 148 | 2 621 440 | 107.0 | 1 280.0 | ext4 | `/` | The stock Buildroot rootfs. Contains `/opt/klipper`, `/opt/PROGRAM` (firmwareExe + MCU updater), `/etc/init.d/`, the QT UI assets, etc. ReForge live mode creates `/reforge` here; the installer adds `/etc/init.d/S01reforge`. The installed chroot is on p7. | ⚠ **CONDITIONAL** — file-level changes are revertible only while SSH or the stock updater remains reachable. Breaking init or recovery files can require Path B. |
| **p7** | `UDISK` | 2 840 588 | 12 429 267 | 1 387.0 | 6 069.0 | ext4 | `/data` | User data partition. **All user gcodes, klippy logs, moonraker SQLite DB**, forge-x's `/data/.mod/.forge-x/` chroot, ReForge install's `/data/.mod/.reforge/`, the eMMC swapfile (if any), `wpa_supplicant.conf` for WiFi creds. | ✅ **SAFE TIER** — file-level changes avoid the boot chain, but deletion or corruption can still lose user data |

## Allocated space and unused tail

- All seven partitions span **LBA 73 728 → 15 269 854** (inclusive), approximately 36.0 MiB → 7 456.0 MiB.
- The first **36 MiB** (LBA 0 → 73 727) is unallocated reserved space holding
  `boot0` (Allwinner BROM-loaded SPL), the GPT, and pad. The mainboard ROM
  loads `boot0` from a fixed offset here.
- `p7` ends at LBA 15 269 854. The disk has 15 269 888 sectors; its final
  33 sectors hold the backup GPT, leaving **no unused tail** for partition growth.

## The brick-safety boundary, restated

| Revertible while SSH or the stock updater remains reachable | Recovery = eMMC-reader-only on this unit |
|---|---|
| **p6 rootfs** (file edits, overlays, mods) | **p2/p3 U-Boot env** (and anything earlier) |
| **p7 /data** (user data, configs, swap) | **active kernel/DTB on p1**, or another selected boot image, *if* userspace becomes unreachable (no SSH, no FEL) |
| | **p6 critical-path files**: broken `/init`, `/etc/inittab`, `rcS` or a hanging `/etc/preinit` can prevent userspace recovery |

**This unit has neither FEL (USB0 pads are internal, no external connector
soldered) nor a UART console (no 3.3 V adapter wired).** So the *only*
recovery path that doesn't require opening the case and pulling the eMMC
into a reader is RUNBOOK Path A: drop a stock-format `.tgz` on a USB stick,
and stock's `auto_run.sh` (rcS:50) reflashes whatever the tarball says to
reflash. That path **requires userspace to still be reaching rcS**, which
means the configured p1 kernel/DTB path must still reach a working init.

So in practice the *real* brick line is:
- **Safe:** anything that keeps stock `auto_run.sh` running and SSH reachable
- **Hard-brick:** anything that prevents stock from reaching `auto_run.sh`,
  because then Path A is gone and Path B (eMMC reader) is the only option.

## ReForge's footprint (where we live)

ReForge in **live mode** skips installation, but creates `/reforge` on p6
and binds eMMC `/data` into the chroot so uploaded gcode persists on p7.
See the [write topology](../live-mode.md#write-topology).

ReForge in **install mode** (`.tgz` over USB, per Plan 3) writes overlays
under `/data/.mod/.reforge/` on **p7** and adds the boot-hook symlink on p6; first boot also creates
the empty `/reforge` mountpoint there.
The installer leaves the bootloader, environment, kernel and DSP partitions in
place. The tree below includes files from the rootfs, installer and OTA:

```
/data/.mod/.reforge/
├── .shell/                 active boot hook and chroot helpers
├── config/screen.conf      created by the installer
├── mod/                    service scripts, runtime config and modules
├── lkg/                    last-known-good copy of mod/
├── opt/                    Klipper, Moonraker and GuppyScreen
├── state/trial.count       boot trial counter
└── var/www/mainsail/       Mainsail web assets
```

The installer uses `/etc/init.d/S01reforge`, pointing to its own boot hook;
forge-x uses the separate S00 slot. See [boot.md](../boot.md) and
[`packaging/flashforge_init.sh`](../../packaging/flashforge_init.sh).

The rootfs ships the initial `lkg/` copy. The installer creates it if absent.
At the end of the installed init loop, `S99ok` calls the helper that refreshes
the copy and resets the counter. See [OTA rollback](../ota.md#safety--boot-trial--last-known-good-lkg).

## Capturing / verifying the layout yourself

From a running device over SSH:

```sh
# Block-level summary (no content; the cmdline label is in /proc/cmdline)
cat /proc/partitions
cat /proc/cmdline

# Full GPT including UUIDs (needs sfdisk on device, or do it on the host)
sfdisk -d /dev/mmcblk0
```

From a captured dump (host-side, rootless):

```sh
gzip -dc tools/recovery/golden.img.gz | dd bs=1M count=2 of=/tmp/golden-head.img
sfdisk -d /tmp/golden-head.img   # GPT lives in the first ~2 MB
```

(The 2 MB head is enough for the GPT header and partition entry array; the
table on this device fits in the first ~50 KB after the protective MBR.)

## See also

- [`docs/boot.md`](../boot.md) — boot chain, intervention points, brick-safety
  recipes
- [`tools/recovery/RUNBOOK.md`](../../tools/recovery/RUNBOOK.md) — Path A
  (USB stock `.tgz`) and Path B (eMMC reader) procedures
- [`docs/board-notes/README.md`](README.md) — kernel cmdline (where the
  `partitions=…@…` line was captured from) and other board reference data
- [`docs/board-notes/device-overview.md`](device-overview.md) — hardware
  inventory (SoC, DRAM, peripherals)
- [`tools/recovery/forge-x-20260531-152104.partitions.txt`](../../tools/recovery/forge-x-20260531-152104.partitions.txt)
  — raw `/proc/partitions` from a running forge-x install on the same unit
- `tools/recovery/golden.img.gz` — local eMMC image used to check these numbers.
  See the [recovery source notes](../../tools/recovery/recovery-sources.md).
