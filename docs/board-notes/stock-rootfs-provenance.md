# Stock rootfs provenance — what's Tina SDK vs what FlashForge added

What's in the stock AD5M / AD5M Pro rootfs (`mmcblk0p6`, ~1.3 GB ext4), broken
down by who put it there. The "Tina SDK" column is the
[Allwinner Tina SDK](https://github.com/Allwinner-Homlet/T113-Linux-Auto-v1.1)
base \u2014 a Buildroot-derived Linux distribution Allwinner brands as
"Allwinner KunoOS Platform" (see `/etc/issue`). The "FlashForge added"
column is everything FF layered on top to build a printer firmware.

This is mostly a reference for Mode 3 (full-replacement) work: when we build
our own rootfs we want to know what's strictly required by the board, what
we can drop entirely, and what FF added that we'd be replacing anyway.

**Source of truth:** `tools/recovery/forge-x-20260531-152104.img.gz` (p6 slice)
inspected via `debugfs`. The forge-x install touches only `/etc/init.d/S??`
symlinks and `/data/.mod/.forge-x/`; nothing under `/opt`, `/bin`, `/usr`,
`/lib`, `/sbin`, `/var`, `/system`, `/Settings`, or `/data/` itself was
changed by forge-x, so this slice is functionally identical to pristine
stock for the "what's in /" analysis.

## Smoking guns that this is a stock Tina/Buildroot rootfs

| Signal | What it tells us |
|---|---|
| `/THIS_IS_NOT_YOUR_ROOT_FILESYSTEM` (1 336 bytes) | Buildroot's own warning file from the **`target/`** intermediate directory \u2014 included as a literal text file by FF when they `cp -a`'d the tree. The warning text explicitly says "do not use this directory as your rootfs", which is amusing because they did. |
| `/init \u2192 /bin/busybox` symlink, `/linuxrc \u2192 /bin/busybox` | Classic BusyBox-init setup. Buildroot default. |
| `/etc/issue`: `Welcome to Allwinner KunoOS Platform` | Allwinner's distro brand for Tina-based Linux builds. |
| `/etc/inittab` Buildroot header (`Copyright (C) 2001 Erik Andersen`) | Vanilla Buildroot inittab template. |
| `/system/`, `/Settings/`, `/data/` mountpoints at top level | Allwinner BSP supports both Android and Linux from the same source tree \u2014 these are Android-style mount slots Tina ships even on the Linux variant. Vestigial. |
| `/lib/modules/5.4.61/` (only `8821cu.ko` inside) | A monolithic kernel build with one out-of-tree module (Realtek WiFi from `drivers/staging/`). Pure Tina kernel build. |
| `/usr/bin` has 600+ entries including PostgreSQL, can-utils, BlueZ, GStreamer, csslint, alsamixer | Tina's "BR2_PACKAGE_ALL=y" default \u2014 they ship everything Buildroot can build, then customers strip. FF didn't strip. |

## Top-level layout

| Path | Origin | Notes |
|---|---|---|
| `/bin/` | **Tina** | busybox + symlinks |
| `/sbin/` | **Tina** | busybox + symlinks |
| `/usr/bin/`, `/usr/sbin/`, `/usr/lib/`, `/usr/share/` | **Tina** | Mostly Buildroot package output; lots of unused tools |
| `/lib/`, `/lib32/` | **Tina** | base libs; `/lib32 \u2192 lib` symlink |
| `/lib/modules/5.4.61/` | **Tina** (kernel module) | only `8821cu.ko` (Realtek WiFi). Compiled from Tina's `drivers/staging/rtl8821cu/` during the BSP kernel build. |
| `/etc/` | **mostly Tina**, a few FF additions (`/etc/wpa_supplicant.conf`, `/etc/wifi/`, `/etc/MAC`) | See "**`/etc` breakdown**" below |
| `/dev/`, `/proc/`, `/sys/`, `/run/`, `/tmp/`, `/var/` | **Tina** | standard runtime mountpoints |
| `/media/`, `/mnt/`, `/root/` | **Tina** | empty mountpoints; `/mnt` is where `auto_run.sh` mounts USB sticks |
| `/init` (symlink \u2192 `/bin/busybox`), `/linuxrc` (same) | **Tina** | BusyBox PID 1 |
| `/system/`, `/Settings/`, `/data/` (mountpoints) | **Tina/Allwinner** | Android-flavoured mountpoints; `/data` is where mmcblk0p7 mounts |
| `/THIS_IS_NOT_YOUR_ROOT_FILESYSTEM` | **Tina/Buildroot artifact** | (shipped accidentally; literal warning file from BR's target/ stage) |
| **`/opt/`** | **FlashForge** (uid=501, gid=20 \u2014 FF dev account that built the image) | The entire FF product lives here; see "**`/opt` breakdown**" below |

## `/etc` breakdown

| Path | Origin |
|---|---|
| `/etc/issue`, `/etc/os-release`, `/etc/hostname`, `/etc/passwd`, `/etc/group`, `/etc/shadow`, `/etc/profile`, `/etc/protocols`, `/etc/services` | **Tina** (Buildroot defaults; hostname is `kunos`) |
| `/etc/inittab` | **Tina** |
| `/etc/init.d/rcS`, `/etc/init.d/rcK` | **Tina** \u2014 BUT FF appended customisations to the tail of `rcS`: `tinymix` audio routing, libcrypto/libssl 1.0.0 \u2192 1.1 symlinks, and the final `/opt/auto_run.sh &`. (Forge-x adds `S55boot S60dropbear S98camera S98zssh S99root` symlinks in `/etc/init.d/`; ReForge would add `S01reforge`.) |
| `/etc/init.d/S01syslogd S02klogd S10udev S20urandom S30dbus S40network S50postgresql S50telnet S80dnsmasq` | **Tina** (Buildroot defaults for each package) |
| `/etc/init.d/S00init` | **Tina** (empty stock placeholder; forge-x replaces this with a symlink to claim S?? slot zero) |
| `/etc/adb_conf.sh` | **Tina/Allwinner** \u2014 Android Debug Bridge daemon launcher (Tina supports adb-over-usb even on Linux builds) |
| `/etc/preinit` (absent on stock) | **Tina** \u2014 the slot is wired into inittab (`::sysinit:/etc/preinit`) but the file is not shipped. Designed as an Allwinner-specific early-boot hook \u2014 see [`boot.md`](../boot.md) \u00a72 row #6 |
| `/etc/wpa_supplicant.conf`, `/etc/wifi/` | **FlashForge** (WiFi creds + Realtek/Allwinner wlan-connect.sh wrapper) |
| `/etc/MAC` | **FlashForge** \u2014 a per-unit MAC address used by `rcS:2` to set `ifconfig eth0 hw ether` |
| `/etc/udev/rules.d/`, `/etc/network/`, `/etc/dbus-1/`, `/etc/dnsmasq.conf` | **Tina** |
| `/etc/fw_env.config` | **Tina/Allwinner** \u2014 `fw_setenv`/`fw_printenv` config for U-Boot env access from userspace |
| `/etc/qtenv.sh` | **FlashForge/Allwinner** \u2014 QT environment setup (referenced commented-out in rcS: `#. /etc/qtenv.sh && Launcher &`) |

## `/opt` breakdown \u2014 everything FlashForge

`/opt` is `0700` and owned by uid 501 / gid 20 (the FF developer account that
built the image \u2014 visible in the ext4 inode metadata). Every entry below is
FF-added; the **Tina SDK ships `/opt` empty**.

### Printer host stack (Klipper)

| Path | Size | What |
|---|---:|---|
| `/opt/klipper/` | ~50 MB | Klipper host (v0.11 baseline; see `docs/research/2026-06-04-klipper-v0.11-fork-deltas.md`) and `start.sh` (sets `LD_LIBRARY_PATH=/opt/openssl-1.0.2d/lib:/opt/libffi-3.4.4/lib`, `PATH=$PATH:/opt/Python-3.7.11/bin`, then `python3.7 /opt/klipper/klippy/klippy.py /opt/config/printer.cfg`) |
| `/opt/config/` | a few KB | `printer.cfg`, `printer.base.cfg` \u2014 the canonical factory config the live unit runs. Same files we extracted to `reference/ad5m-factory-config/`. |
| `/opt/Python-3.7.11/` | ~25 MB | Python 3.7.11 interpreter + stdlib (FF built; not Tina's) |
| `/opt/openssl-1.0.2d/`, `/opt/libffi-3.4.4/` | a few MB each | Python's OpenSSL and libffi (FF built; ancient versions) |

### Stock UI (QT firmwareExe)

| Path | Size | What |
|---|---:|---|
| `/opt/PROGRAM/` | ~100 MB | The stock UI binaries: `ffstartup-arm` + `firmwareExe` (the QT touchscreen UI launched by `auto_run.sh`'s last line), plus `control/<version>/run.sh` + MCU firmware images (`Mainboard-20230831.bin`, `Eboard-20231012.hex`) used by the MCU-update path |
| `/opt/qt-4.8.6/` | ~50 MB | QT 4.8 runtime libs used by firmwareExe |
| `/opt/tslib-1.12/` | a few MB | Touchscreen library for QT |

### Camera + video

| Path | Size | What |
|---|---:|---|
| `/opt/mjpg-streamer/` | a few MB | MJPEG over HTTP for the print camera (forge-x replaces with its own; ReForge can replace with v4l2 + nginx-equivalent) |
| `/opt/ffmpeg-4.0.2/` | ~30 MB | FFmpeg (probably for camera transcode) |
| `/opt/x264/`, `/opt/mencoder` (20 MB binary), `/opt/AD4/` | varies | Video encoding bits used by the camera path |

### Cloud / OTA / auth

| Path | Size | What |
|---|---:|---|
| `/opt/cloud/` | varies | NetEase / FF cloud SDK (the "shenzhenbest" cloud connection; this is the bit ReForge explicitly does NOT ship per the spec) |
| `/opt/cacert.pem` | 218 KB | CA bundle for the cloud TLS connection |
| `/opt/key.pub`, `/opt/key.priv`, `/opt/private.pem` | <2 KB | Per-unit cloud auth keypair |
| `/opt/ntpclient` | 18 KB | NTP client (used for the cloud connection to need accurate time) |

### Vestigial / debug

| Path | What |
|---|---|
| `/opt/screwflag` | Empty zero-byte file. Possibly an internal QC flag for "screws torqued at factory". |
| `/opt/nim/` | Unclear; possibly Nim-language tooling FF dev included for debugging? Likely unused at runtime. |
| `/opt/manualEnv.sh` | A 936-byte env-var setup script. Looks like a dev convenience. |
| `/opt/boot.img` | 3 MB copy of the boot partition's image. Commented-out line in `auto_run.sh` reads `#cat /opt/boot.img > /dev/fb0` \u2014 was probably used as a splash screen during dev. |
| `/opt/pycmd.py` | 644 bytes. Referenced by `start.sh` only in a commented-out line. Dev leftover. |
| `/opt/logFiles/` | empty dir; intended as a log destination, but actual klippy logs go to `/data/logFiles/` |
| `/opt/home/`, `/opt/usr/`, `/opt/bin/`, `/opt/lib/`, `/opt/etc/`, `/opt/share/`, `/opt/var/`, `/opt/root/`, `/opt/tmp/`, `/opt/sbin/`, `/opt/libexec/` (all dated 2024-01) | These are `0755 uid=501 gid=20` empty-ish dirs that look like a **secondary rootfs scaffold** \u2014 possibly an unfinished attempt at containerised app deployment, or a place holders for OTA-deployed sub-trees. Their dates (Jan 2024) are AFTER the rest of /opt (Jan 1970 epoch), suggesting they were added later. None are actively used by the current boot. |

## `auto_run.sh` \u2014 the FF customisation that ties everything together

`/opt/auto_run.sh` is the **single biggest FF customisation**, even though it's
a 79-line shell script. It:

1. Mounts `/data` (mmcblk0p7).
2. Loads the WiFi module.
3. Scans `/dev/sda*` for an update tarball (`Adventurer5MPro-*.tgz`) or a bare
   `flashforge_init.sh` \u2014 the dual-entry-point USB update mechanism.
4. Runs the MCU firmware update flow if `/opt/PROGRAM/control/<latest>/Update`
   exists.
5. Launches the stock UI (`ffstartup-arm`).

It is hooked into the boot chain as the **last line of `/etc/init.d/rcS`**
(backgrounded). See [`boot.md`](../boot.md) \u00a74 for the full timeline.

The Tina SDK does **not** ship this script \u2014 a clean Tina rootfs's `rcS` ends
after the `S??` loop + Allwinner audio/adb setup. FF added the
`/opt/auto_run.sh &` line + the supporting `/opt/PROGRAM/`, `/opt/klipper/`,
`/opt/config/`, etc.

## Implications for Mode 3 (full-replacement rootfs)

When ReForge builds its own rootfs (per [`deployment-modes.md`](../deployment-modes.md)
Mode 3), we can drop everything in the "FlashForge added" column except the
parts we replace with our own equivalents. Concretely:

| FF artifact | ReForge equivalent | Mode 3 action |
|---|---|---|
| `/opt/klipper/` v0.11 | `/opt/klipper/` v0.11.0 + our 6 patches (built from upstream) | Replace |
| `/opt/Python-3.7.11/`, `/opt/openssl-1.0.2d/`, `/opt/libffi-3.4.4/` | system `/usr/bin/python3.14` + system `/usr/lib/libssl*` + system `/usr/lib/libffi*` (all Buildroot-built) | Replace (smaller, newer) |
| `/opt/PROGRAM/` (firmwareExe) | GuppyScreen + Mainsail | **Drop firmwareExe entirely**; keep `/opt/PROGRAM/control/<ver>/` for MCU firmware update path |
| `/opt/qt-4.8.6/`, `/opt/tslib-1.12/` | LVGL (GuppyScreen) | Drop |
| `/opt/mjpg-streamer/`, `/opt/ffmpeg-4.0.2/`, `/opt/x264/`, `/opt/mencoder`, `/opt/AD4/` | mjpg-streamer or ustreamer (Buildroot package) | Replace with smaller equivalent |
| `/opt/cloud/`, `/opt/cacert.pem`, `/opt/key.*`, `/opt/private.pem`, `/opt/ntpclient` | **none** (no cloud connection in ReForge) | **Drop \u2014 firm spec requirement** |
| `/opt/auto_run.sh` | ReForge init chain | Replace (but **preserve the USB-`.tgz` recovery hook** so users can flash a stock `Adventurer5MPro-*.tgz` to get back to factory) |
| `/opt/screwflag`, `/opt/boot.img`, `/opt/nim/`, `/opt/manualEnv.sh`, `/opt/pycmd.py` | n/a | Drop (dev leftovers, none used) |
| Tina debugging fluff in `/usr/bin/` (postgresql, bluetooth, GStreamer, can-utils, csslint, etc.) | none | Drop via `reforge_t113_defconfig` package selection |
| `/system/`, `/Settings/` mountpoints | n/a (we're not dual-targeting Android) | Drop |
| `/THIS_IS_NOT_YOUR_ROOT_FILESYSTEM` | n/a | Don't ship it. |

The **Tina-side** entries we KEEP for the Mode 3 base:
- BusyBox `/bin`, `/sbin`, the standard `/etc/init.d/S??*` skeleton (minus
  the ones we don't need: postgresql, dnsmasq, telnet)
- `/lib/modules/<ver>/8821cu.ko` (the WiFi driver, but rebuilt against
  our mainline kernel)
- `/etc/wpa_supplicant.conf`, `/etc/wifi/` (handled via our `net-up.sh`
  flow already)
- `/etc/MAC` (per-unit MAC) and `rcS`'s `ifconfig eth0 hw ether $MAC` line
- `/etc/fw_env.config` for U-Boot env access

The **stock-recovery-`.tgz` hook** \u2014 the USB scan loop + the
`/data/update/flashforge_init.sh` path from `auto_run.sh` \u2014 we keep in our
own init script. This is the user's emergency "flash stock to recover" path,
per the [Mode 3 definition](../deployment-modes.md#mode-3--full-replacement-own-kernel--rootfs):
"the factory USB recovery hook is preserved".

## See also

- [`board-notes/partition-map.md`](partition-map.md) \u2014 where in the eMMC each
  of these trees lives
- [`board-notes/README.md`](README.md) \u2014 hardware inventory + kernel cmdline
- [`board-notes/stock-kernel-config-5.4.61.txt.gz`](stock-kernel-config-5.4.61.txt.gz)
  \u2014 the kernel `.config` (Tina-side)
- [`reverse-engineering/stock-kernel-modules-packaging.md`](../reverse-engineering/stock-kernel-modules-packaging.md)
  \u2014 deep dive on the kernel module layout
- [`research/2026-06-04-klipper-v0.11-fork-deltas.md`](../research/2026-06-04-klipper-v0.11-fork-deltas.md)
  \u2014 what FF did to upstream Klipper in their fork
- [`boot.md`](../boot.md) \u00a74 \u2014 the auto_run.sh timeline
- [`deployment-modes.md`](../deployment-modes.md) \u2014 Mode 3 plan that this provenance
  doc informs
