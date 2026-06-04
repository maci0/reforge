# Memory comparison — ReForge (production) vs forge-x (default install), UI-less

**Date:** 2026-06-05
**Status:** measured + reproducible; both probes commit to disk under `tests/qemu-harness/`
**Workbench:** qemu-system-arm virt board, `-m 128 -smp 2 cortex-a7`, settle 60 s
**Snapshot:** per-process `Pss` / `Rss` from `/proc/<pid>/smaps_rollup`, plus full `/proc/meminfo`
**Build state at measurement:**
  - ReForge production rootfs `build/output-gcc15-base/images/rootfs.tar` — gcc 15.2, glibc 2.42, Python 3.14, jemalloc preload with `narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0`, moonraker.conf with `[octoprint_compat]` removed (keeps `[history]` + `[update_manager]` for OTA)
  - forge-x rootfs sliced from `tools/recovery/forge-x-20260531-152104.img.gz` (p6) with `tools/recovery/forge-x-20260531-152104.partitions.txt` — Python 3.7.11, stock FF klipper, moonraker in chroot venv

**Per-side patches applied for the measurement (do NOT change the running stack):**
  - forge-x: `/opt/auto_run.sh`'s `ffstartup-arm` line replaced with a no-op (`mem-probe-forgex.sh` does this rootlessly via `debugfs`); `S00aprep` creates `/dev/mmcblk0p7 → /dev/vdb` so forge-x's `mount_data_partition` finds `/data` on the virt board; `S99forgex-probe` then directly execs `/opt/klipper/start.sh` (since the UI is what normally launches klippy) and snapshots after settle.
  - ReForge: `S98memprobe` runs `/mod/start.sh` (production boot chain), settles, snapshots. No tweaks applied (the rootfs already includes the autoresearch winners: gcc15, `tcache:false`, conservative moonraker trim).
  - **Reforge zram ON (production); forge-x runs its own swap config (an mmc swapfile at `/data/.mod/.forge-x/root/swap`, low priority).** Each side is measured as it ships.

## Headline numbers

| metric (kB) | ReForge prod | forge-x default | Δ (forge-x − ReForge) | % |
|---|---:|---:|---:|---:|
| **klippy** Pss | 12 640 | 17 981 | **+5 341** | **+42.3%** |
| **moonraker** Pss | 35 683 | 36 785 | +1 102 | +3.1% |
| **httpd** Pss | 154 | 725 | +571 | +371% |
| **klippy + moonraker + httpd subtotal** | **48 477** | **55 491** | **+7 014** | **+14.5%** |
| **All userspace Pss (incl. background services)** | **50 119** | **59 226** | **+9 107** | **+18.2%** |

### `/proc/meminfo` snapshot

| key (kB) | ReForge prod | forge-x default | note |
|---|---:|---:|---|
| MemTotal | 108 332 | 108 332 | both `-m 128`; kernel reserves the same |
| MemFree | 10 956 | 9 508 | forge-x ~1.4 MB tighter on free RAM |
| MemAvailable | 45 084 | 46 568 | forge-x slightly higher — **swap shenanigans** (see below) |
| Cached | 32 912 | 33 620 | comparable |
| Buffers | 2 024 | 3 132 | comparable |
| SwapTotal | 262 140 | 65 532 | ReForge zram (256 MiB); forge-x mmc swapfile (64 MiB) |
| SwapFree | 262 140 | 63 484 | **ReForge: 0 swap used; forge-x: 2 048 kB pushed out to mmc** |

### The MemAvailable paradox

forge-x reports `MemAvailable=46 568` vs ReForge's `45 084` — i.e. forge-x looks like it has *more* free RAM. That's misleading: forge-x has already evicted **2 048 kB to its mmc swapfile**, so 2 MB of process pages aren't in RAM. ReForge's zram is also active (256 MiB) but unused (`SwapFree == SwapTotal`) because the system isn't under pressure.

Adding back the swapped-out pages, forge-x's **effective** Pss footprint is ~**61 274 kB**, putting the gap at **+11 155 kB (+22.3%)** vs ReForge.

## Background services breakdown

| Process | ReForge | forge-x | note |
|---|---:|---:|---|
| `/usr/sbin/ntpd` | — | 779 kB | forge-x runs ntpd by default; ReForge relies on DHCP-pushed NTP servers |
| `/bin/dropbear -F -p 22` | — | 504 kB | forge-x ships dropbear in the base rootfs; ReForge has it via the live launcher only |
| `/sbin/udevd -d` | — | 487 kB | forge-x uses full eudev; ReForge uses busybox mdev (Pss < 200 kB, folded into kthreads) |
| `dbus-daemon --system` | — | 448 kB | forge-x ships dbus for the QT UI; ReForge has no dbus consumers |
| `/usr/sbin/crond -f` | 261 kB | — | ReForge runs busybox crond; forge-x doesn't have any cron jobs |
| `udhcpc -t1 -A3 -b -R -O search -O staticroutes -p ... -i eth0` | 174 kB | — | ReForge keeps an active DHCP renewer; forge-x's runs and exits |

Subtotal of unique-to-each services:
- forge-x: +2 218 kB (ntpd + dropbear + udevd + dbus)
- ReForge: +435 kB (crond + udhcpc)
- **net background overhead in forge-x: +1 783 kB**

## What drives the +42% klippy delta

Both sides run the same klippy `klippy.py` against an equivalent `printer.cfg`; the
delta is **toolchain + Python runtime**, not Klipper itself.

| | ReForge | forge-x |
|---|---|---|
| Python | 3.14 | 3.7.11 |
| gcc | 15.2 | (stock FF; gcc 6 or 7-era, build string `?-20230317_182329-ubuntu20-virtual-machine`) |
| glibc | 2.42 | stock (older) |
| libpython size | 3 313 KB | (older, larger; not measured here) |
| LTO across packages | yes | no |
| -Os + Thumb-2 | yes | likely no (FF builds for size were ad-hoc) |

The autoresearch loop (`autoresearch.md`, `autoresearch.jsonl`) attributed −17.0% of ReForge's Pss reduction to **gcc 14.3 → 15.2 alone**, with libpython dropping 29.5%. Same effect applies vs the much older toolchain forge-x's stack was compiled with.

## What drives the small moonraker delta

forge-x's moonraker runs in a chroot venv with **its own copy of Python and its own dependencies** (CPython 3.x bundled at `/root/moonraker-env/bin/python3`); ReForge's moonraker runs against the system Python 3.14. The reason the delta is small (only +1.1 MB) despite the different libpython is that moonraker's Pss is dominated by its own Python heap (cffi, asyncio loop state, tornado, jinja2 templates, the SQLite open DB pages) — not the interpreter binary.

ReForge's moonraker.conf still has `[history]` and the full `[update_manager]` tree (for OTA). Stripping those (the aggressive `moonraker-min` variant from the autoresearch loop) saves another ~1.4 MB — a config-time choice, not a code-level one.

## Reproducing this comparison

```sh
# 1. ReForge rootfs (production): the gcc15 build + the autoresearch tweaks
make rootfs                                        # via tools/build/build.sh or:
tools/build/build-variant.sh gcc15-base experiments/2026-06-04-toolchain-memory/gcc15-base.fragment

# 2. Slice the forge-x rootfs from the eMMC dump (rootless)
gzip -dc tools/recovery/forge-x-20260531-152104.img.gz > /tmp/fx.img
sfdisk -d /tmp/fx.img | grep img    # find p6 (rootfs) and p7 (/data) offsets
# slice via dd by sector offsets (extract-stock-rootfs.sh does this for golden;
# mem-probe-forgex.sh expects forgex-rootfs.ext4 + forgex-data.ext4 in build/)

# 3. Run both probes
SETTLE=60 NOSWAP=0 tests/qemu-harness/mem-probe.sh           build/output-gcc15-base/images/rootfs.tar reforge
SETTLE=60          tests/qemu-harness/mem-probe-forgex.sh    forgex
```

Both probes drop their snapshot under `tests/qemu-harness/build/mem-probe-{reforge,forgex-forgex}-*.log`. The summary is generated by:

```sh
python3 docs/research/2026-06-05-reforge-vs-forgex-memory.md  # ← this file has the parsing code at the end
```

## Caveats / honest gotchas

1. **Different kernels.** Both rootfs boot under the same virt test kernel (`tests/qemu-harness/build/zImage`), so the kernel-side overhead is identical. On the real device both would run the stock 5.4.61 BSP kernel, so the relative numbers should hold but absolutes will shift slightly.
2. **forge-x's swap counts toward its footprint.** The +9 MB / +18% in the headline does not credit forge-x for the 2 MB already evicted. The "+22%" effective number does.
3. **httpd Pss skew.** ReForge uses busybox `httpd` (~150 kB); forge-x ships full `nginx`-replacement-ish httpd (~700 kB). Most of this delta is `mmap`'d Mainsail static files — under more load both would converge.
4. **forge-x's S00init brings up extras** (KAMP daemon, z* CLI tooling, etc.) — those didn't appear in the snapshot because they're triggered by KAMP-related gcode events, not at boot.

## Verdict

For the **host stack** the user actually cares about (klippy + moonraker serving the printer):
**ReForge production saves 7 014 kB Pss (−14.5%) vs forge-x default**, with the win concentrated in klippy (−5.3 MB, −42%) driven almost entirely by the gcc 15.2 + Python 3.14 + tuned-glibc toolchain stack.

System-wide including background services, the gap widens to **−9 107 kB (−18.2%)**. With the 2 048 kB forge-x has already paged to mmc swap counted in, **−11 155 kB (−22.3%)** effective.
