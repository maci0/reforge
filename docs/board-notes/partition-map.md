# eMMC partition map — FlashForge AD5M / AD5M Pro

Canonical layout of the device's onboard eMMC (`/dev/mmcblk0`), with GPT
offsets, sizes, filesystem types, mountpoints, and brick-safety tier.

**Source of truth:** GPT extracted from `tools/recovery/golden.img.gz` (the
unit-`kunos` clean stock dump, sha256 in `tools/recovery/golden.size`).
Verified against `tools/recovery/forge-x-20260531-152104.partitions.txt`
(raw `/proc/partitions` on the same unit while running forge-x).

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
| **p1** | `boot-resource` | 73 728 | 68 876 | 36.0 | 33.6 | vfat | `/mnt/UDISK/p1` (read-only by U-Boot) | U-Boot resource: vendor splash images, MCU firmware staging, RTOS resource bundle | ⚠ **MEDIUM** — written only by `boot.img`'s init at update time |
| **p2** | `env` | 142 604 | 2 048 | 69.6 | 1.0 | U-Boot env | n/a (raw block) | U-Boot environment (primary copy). `fw_setenv` writes here. | ⛔ **HARD-BRICK TIER** — corrupting this stops U-Boot in `boot0` before any userspace; **no FEL on this unit (USB0 pads internal, no UART) → eMMC-reader-only recovery** (RUNBOOK Path B). |
| **p3** | `env-redund` | 144 652 | 2 048 | 70.6 | 1.0 | U-Boot env (redundant) | n/a (raw block) | U-Boot environment, redundant copy | ⛔ **HARD-BRICK TIER** — same as p2; both copies must be intact for U-Boot to come up cleanly |
| **p4** | `boot` | 146 700 | 70 400 | 71.6 | 34.4 | Android boot.img | n/a (loaded by U-Boot) | Kernel `Image` + DTB + initramfs in Android boot-image format (`mkbootimg`). Stock cmdline lives here too. | ⚠ **MEDIUM** — a bad `boot.img` stops the kernel; recoverable via RUNBOOK Path A (stock USB `.tgz` re-installs it) **if** userspace is reachable to run `flashforge_init.sh`. Otherwise Path B. |
| **p5** | `dsp0` | 217 100 | 2 048 | 106.0 | 1.0 | raw (HiFi4 binary) | n/a (loaded by kernel) | HiFi4 DSP firmware. The T113-S3 has an audio DSP core; this is its boot image. | ⚠ **MEDIUM** — corruption blocks the DSP but not the AP; AP-only boot still works (DSP would be silent). |
| **p6** | `rootfs` | 219 148 | 2 621 440 | 107.0 | 1 280.0 | ext4 | `/` | The stock Buildroot rootfs. Contains `/opt/klipper`, `/opt/PROGRAM` (firmwareExe + MCU updater), `/etc/init.d/`, the QT UI assets, etc. **forge-x and ReForge live mode never write here**; the ReForge **installer** writes overlays at `/data/.mod/.reforge/mod/` (see Plan 3). | ✅ **SAFE TIER (revertible)** — changes are file-level; you can SSH in and undo. Worst case, reflash a stock `.tgz` over USB (RUNBOOK Path A). |
| **p7** | `UDISK` | 2 840 588 | 12 429 267 | 1 387.0 | 6 069.0 | ext4 | `/data` | User data partition. **All user gcodes, klippy logs, moonraker SQLite DB**, forge-x's `/data/.mod/.forge-x/` chroot, ReForge install's `/data/.mod/.reforge/`, the eMMC swapfile (if any), `wpa_supplicant.conf` for WiFi creds. | ✅ **SAFE TIER** — file-level, fully under userspace control |

## Allocated space and unused tail

- All seven partitions span **LBA 73 728 → 15 269 855** = 36.0 MiB → 7 456.0 MiB.
- The first **36 MiB** (LBA 0 → 73 727) is unallocated reserved space holding
  `boot0` (Allwinner BROM-loaded SPL), the GPT, and pad. The mainboard ROM
  loads `boot0` from a fixed offset here.
- `p7` ends at the disk end (LBA 15 269 855 = 7 456 MiB), so there is **no
  unused tail** to grow into without resizing p7.

## The brick-safety boundary, restated

| Safe (revertible over SSH) | Recovery = eMMC-reader-only |
|---|---|
| **p6 rootfs** (file edits, overlays, mods) | **p2/p3 U-Boot env** (and anything earlier) |
| **p7 /data** (user data, configs, swap) | **p4 boot.img** *if* userspace is unreachable (no SSH, no FEL) |
| **p1 boot-resource** *only at update time, from the running kernel* | |

**This unit has neither FEL (USB0 pads are internal, no external connector
soldered) nor a UART console (no 3.3 V adapter wired).** So the *only*
recovery path that doesn't require opening the case and pulling the eMMC
into a reader is RUNBOOK Path A: drop a stock-format `.tgz` on a USB stick,
and stock's `auto_run.sh` (rcS:50) reflashes whatever the tarball says to
reflash. That path **requires userspace to still be reaching rcS**, which
means p4 boot.img must still boot a working kernel + init.

So in practice the *real* brick line is:
- **Safe:** anything that keeps stock `auto_run.sh` running and SSH reachable
- **Hard-brick:** anything that prevents stock from reaching `auto_run.sh`,
  because then Path A is gone and Path B (eMMC reader) is the only option.

## ReForge's footprint (where we live)

ReForge in **live mode** (USB-only) touches **nothing on the eMMC** — see
`docs/live-mode.md` for the zero-write invariant. The eMMC is untouched
through the whole live boot.

ReForge in **install mode** (`.tgz` over USB, per Plan 3) writes overlays
under `/data/.mod/.reforge/mod/` on **p7** and never touches p1–p6:

```
/data/.mod/.reforge/
├── mod/                     ReForge overlay (klippy, moonraker, mainsail, init scripts)
├── lkg/                     last-known-good copy (LKG rollback)
└── trial/                   trial-install bookkeeping
```

The installer mirrors forge-x's hooking pattern (own the `/etc/init.d/S00init`
symlink — see `docs/boot.md` §3 and `docs/specs/2026-05-31-reforge-firmware-design.md`).

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
- [`tools/recovery/golden.img.gz`](../../tools/recovery/golden.img.gz) — the
  authoritative eMMC dump these numbers come from
