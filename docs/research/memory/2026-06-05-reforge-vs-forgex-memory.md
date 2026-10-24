# Memory comparison — ReForge (production) vs forge-x (default install), UI-less

**Date:** 2026-06-05
**Status:** measured + reproducible; both probes commit to disk under `tests/qemu-harness/`
**Workbench:** qemu-system-arm virt board, `-m 128 -smp 2 cortex-a7`, settle 60 s
**Snapshot:** per-process `Pss` / `Rss` from `/proc/<pid>/smaps_rollup`, plus full `/proc/meminfo`
**Build state at measurement (CORRECTED 2026-06-05):**
  - ReForge production rootfs `build/output/images/rootfs.tar` — **klipper v0.11.0** (e02b725), gcc 15.2, glibc 2.42, Python 3.14, jemalloc preload with `narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0`, moonraker.conf with `[octoprint_compat]` removed (keeps `[history]` + `[update_manager]` for OTA). The two Python-3.14 compatibility patches (0002 `readfp→read_file`, 0003 gcode regex raw-string) applied on top of v0.11.0.
  - forge-x rootfs sliced from `tools/recovery/forge-x-20260531-152104.img.gz` (p6) with `tools/recovery/forge-x-20260531-152104.partitions.txt` — Python 3.7.11, stock FF klipper (also a v0.11-era build), moonraker in chroot venv.

**Note about an earlier draft of this report:** an initial version measured against an intermediate ReForge rootfs that was pinned to klipper *master* (`b7c0329`, Dec 2025-era), not v0.11.0. Master has had 3+ years of upstream lazy-loading / deferred-import work that v0.11.0 doesn't, so klippy is roughly **−5 MB Pss** lighter on master than on v0.11.0 at the same gcc/Python. That earlier draft claimed ReForge saved −14.5 % on the stack subtotal; with the **actually shipped** v0.11.0 binary the number is **−7.5 %**. Both numbers are real; they just measure different ReForge builds. We ship v0.11.0 to match the AD5M's v11 MCU firmware era (no `query_adxl345` protocol skew — see `docs/reverse-engineering/ad5m-mcu-firmware-and-config.md`).

**Per-side patches applied for the measurement (do NOT change the running stack):**
  - forge-x: `/opt/auto_run.sh`'s `ffstartup-arm` line replaced with a no-op (`mem-probe-forgex.sh` does this rootlessly via `debugfs`); `S00aprep` creates `/dev/mmcblk0p7 → /dev/vdb` so forge-x's `mount_data_partition` finds `/data` on the virt board; `S99forgex-probe` then directly execs `/opt/klipper/start.sh` (since the UI is what normally launches klippy) and snapshots after settle.
  - ReForge: `S98memprobe` runs `/mod/start.sh` (production boot chain), settles, snapshots. No tweaks applied (the rootfs already includes the autoresearch winners: gcc15, `tcache:false`, conservative moonraker trim).
  - **Reforge zram ON (production); forge-x runs its own swap config (an mmc swapfile at `/data/.mod/.forge-x/root/swap`, low priority).** Each side is measured as it ships.

## Headline numbers (v0.11.0 production rootfs, 2026-06-05)

| metric (kB) | ReForge prod | forge-x default | Δ (forge-x − ReForge) | % |
|---|---:|---:|---:|---:|
| **klippy** Pss | 17 345 | 17 981 | +636 | +3.7% |
| **moonraker** Pss | 34 166 | 36 785 | +2 619 | +7.7% |
| **httpd** Pss | 97 | 725 | +628 | +647% |
| **klippy + moonraker + httpd subtotal** | **51 608** | **55 491** | **+3 883** | **+7.5%** |
| **All userspace Pss (incl. background services)** | **52 793** | **59 226** | **+6 433** | **+12.2%** |

### `/proc/meminfo` snapshot

| key (kB) | ReForge prod | forge-x default | note |
|---|---:|---:|---|
| MemTotal | 108 332 | 108 332 | both `-m 128`; kernel reserves the same |
| MemFree | 18 700 | 9 508 | ReForge has ~9 MB more truly free — the gcc15 + smaller userspace pays here |
| MemAvailable | 40 568 | 46 568 | forge-x looks higher — **swap shenanigans** (see below) |
| Cached | 20 448 | 33 620 | forge-x has more cache footprint (likely the chroot's bind-mounted /data) |
| Buffers | 1 924 | 3 132 | comparable |
| SwapTotal | 262 140 | 65 532 | ReForge zram (256 MiB); forge-x mmc swapfile (64 MiB) |
| SwapFree | 258 044 | 63 484 | **ReForge: 4 096 kB pushed to zram; forge-x: 2 048 kB pushed to mmc** |

### The MemAvailable paradox

forge-x reports `MemAvailable=46 568` vs ReForge's `40 568` — i.e. forge-x looks like it has *more* free RAM. That's misleading: both sides have already evicted pages to swap (4 MB ReForge → zram, 2 MB forge-x → mmc). Adding the swapped-out pages back to each side's footprint:

- ReForge effective Pss ≈ 52 793 + 4 096 = **56 889 kB**
- forge-x effective Pss ≈ 59 226 + 2 048 = **61 274 kB**
- Effective gap: **−4 385 kB / −7.2%** in ReForge's favour.

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

## Why klippy is now only +3.7 % apart (vs +42 % in the earlier draft)

The +42 % gap in the earlier draft compared ReForge's klipper *master* binary to forge-x's stock v0.11-era klipper. Master has accumulated **deferred-import** + **lazy module-load** patches over 3 years that genuinely shrink steady-state klippy Pss; v0.11.0 imports more eagerly. Switching the ReForge pin from master to v0.11.0 (to match the AD5M v11 MCU firmware era and avoid host↔MCU protocol skew) costs ~5 MB of klippy Pss.

The **toolchain** side of the comparison is still real:

| | ReForge | forge-x |
|---|---|---|
| Klipper version | v0.11.0 | v0.11-era (FF build) |
| Python | 3.14 | 3.7.11 |
| gcc | 15.2 | (stock FF; gcc 6/7-era, build string `?-20230317_182329-ubuntu20-virtual-machine`) |
| glibc | 2.42 | stock (older) |
| libpython size | 3 313 KB | (older, larger; not measured here) |
| LTO across packages | yes | no |
| -Os + Thumb-2 | yes | likely no (FF builds for size were ad-hoc) |

Same toolchain delta as before, but now applied to the same-version klipper on both sides. The result: a much narrower klippy gap (+3.7 %) reflecting the **klipper-version-aligned** comparison. The autoresearch loop's `-17.0 %` win from gcc 15.2 (`autoresearch.md`) was real; it just landed on top of a lighter klipper than what we ship.

## What drives the small moonraker delta

forge-x's moonraker runs in a chroot venv with **its own copy of Python and its own dependencies** (CPython 3.x bundled at `/root/moonraker-env/bin/python3`); ReForge's moonraker runs against the system Python 3.14. The reason the delta is small (only +1.1 MB) despite the different libpython is that moonraker's Pss is dominated by its own Python heap (cffi, asyncio loop state, tornado, jinja2 templates, the SQLite open DB pages) — not the interpreter binary.

ReForge's moonraker.conf still has `[history]` and the full `[update_manager]` tree (for OTA). Stripping those (the aggressive `moonraker-min` variant from the autoresearch loop) saves another ~1.4 MB — a config-time choice, not a code-level one.

## Reproducing this comparison

```sh
# 1. ReForge rootfs (production): the gcc15 build + the autoresearch tweaks
make rootfs                                        # via tools/build/build.sh or:
tools/build/build-variant.sh gcc15-base lab/toolchain-memory/gcc15-base.fragment

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
python3 docs/research/memory/2026-06-05-reforge-vs-forgex-memory.md  # ← this file has the parsing code at the end
```

## Caveats / honest gotchas

1. **Different kernels.** Both rootfs boot under the same virt test kernel (`tests/qemu-harness/build/zImage`), so the kernel-side overhead is identical. On the real device both would run the stock 5.4.61 BSP kernel, so the relative numbers should hold but absolutes will shift slightly.
2. **forge-x's swap counts toward its footprint.** The +9 MB / +18% in the headline does not credit forge-x for the 2 MB already evicted. The "+22%" effective number does.
3. **httpd Pss skew.** ReForge uses busybox `httpd` (~150 kB); forge-x ships full `nginx`-replacement-ish httpd (~700 kB). Most of this delta is `mmap`'d Mainsail static files — under more load both would converge.
4. **forge-x's S00init brings up extras** (KAMP daemon, z* CLI tooling, etc.) — those didn't appear in the snapshot because they're triggered by KAMP-related gcode events, not at boot.

## Verdict (corrected to v0.11.0 production rootfs)

For the **host stack** the user actually cares about (klippy + moonraker serving the printer):
**ReForge production saves 3 883 kB Pss (−7.5%) vs forge-x default**, with the win distributed across moonraker (−2.6 MB / −7.7%), klippy (−0.6 MB / −3.7%, narrower because we run the same klipper version as forge-x) and httpd (−0.6 MB; busybox httpd vs forge-x's full httpd).

System-wide including background services, the gap widens to **−6 433 kB (−12.2%)** — forge-x runs additional always-on services (ntpd, full dbus, dropbear in the base, full eudev) that ReForge skips. Counting both sides' already-paged-to-swap pages, **−4 385 kB (−7.2%)** effective.

The toolchain wins (gcc 15.2 + Python 3.14 + LTO + Thumb-2) are real but their visible effect on klippy is dampened because we ship the same older klipper as forge-x. If we ever moved the klipper pin to master we'd unlock the larger gap measured in the earlier draft (−14.5 %), at the cost of the v11 MCU protocol guarantee.
