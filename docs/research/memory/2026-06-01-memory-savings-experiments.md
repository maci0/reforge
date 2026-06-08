# Memory-savings experiments (128 MB T113)

Levers to cut RAM on the AD5M Pro (128 MB), and how each is A/B-measured in qemu.
The dominant consumer is the shared Python (klippy + moonraker); wins target its
resident set or the code-page footprint shared across all processes.

Measurement: `tests/qemu-harness/mem-probe.sh` boots the full rootfs under the virt
kernel at **`-m 128`** (real device RAM), lets Python settle, and dumps per-process
**Pss** (`/proc/<pid>/smaps_rollup`) + `/proc/meminfo` + zram stats over serial.
`sudo make qemu-mem [TWEAKS=oo,arena1] [ROOTFS_TAR=...]`.

## Already in the baseline

- zram compressed swap (zstd) on the stock kernel
- ~~`MALLOC_ARENA_MAX=2`~~ **superseded by jemalloc tuned (-6.5MB)** — see docs/optimizations.md
- nginx → busybox httpd (−~3 MB RSS)
- Moonraker components trimmed (no update_manager/spoolman/notifier/ldap)
- single shared python3 interpreter (COW page sharing); GUI idle unless SCREEN_MODE=GUPPY

## Levers under test

### Runtime (no rebuild — `TWEAKS=` in mem-probe)
| lever | mechanism | hypothesis |
|---|---|---|
| `arena1` | `MALLOC_ARENA_MAX=1` | tighter than 2; small extra RSS cut, minor malloc contention on 2 cores |
| `oo` | run klippy+moonraker as `python3 -OO` | drops docstrings + asserts from in-RAM bytecode |
| (glibc tunables) | `GLIBC_TUNABLES=glibc.malloc.trim_threshold=131072` | return freed heap to OS sooner |

### Build flags (rebuild — size-optimized variant)
| lever | option | hypothesis |
|---|---|---|
| Thumb-2 | `BR2_ARM_INSTRUCTIONS_THUMB2=y` | ~25–30 % smaller code → fewer resident code pages everywhere |
| size-opt | `BR2_OPTIMIZE_S=y` (`-Os`) | −10–15 % code |
| section GC | `-ffunction-sections -fdata-sections` (+ `--gc-sections`) | strip dead code |
| locale purge | `BR2_ENABLE_LOCALE_PURGE=y` + drop gconv/docs | smaller rootfs → less page-cache/tmpfs pressure |

### Allocator (one comparison)
- jemalloc tuned `narenas:1,dirty_decay_ms:0,background_thread:true` vs glibc+arena cap.

## A/B matrix (qemu `-m 128`, settle 25s; klippy in error/no-MCU; zram absent under virt kernel)

| build | RAM lever | MemAvailable (kB) | sum tracked Pss (kB) | notes |
|---|---|---|---|---|
| baseline | glibc, -O2, ARM, arena=2 | 46208 | 59746 | klippy 21.1M, moonraker 38.5M, **httpd 0.19M** |
| baseline | +arena1 | 46312 | 59741 | **no change** (≈noise) |
| baseline | +oo | 46064 | 59734 | **no change** (≈noise) |
| baseline | +oo,arena1 | 46120 | 59946 | **no change** (≈noise) |
| size-opt | Thumb2+-Os+purge | 46256 | **54862** | **−4.9 MB Pss (−8.2 %)**; rootfs 25.74→24.66 MB |

### Arena: glibc-default vs cap=2 (the value the cap actually provides), `-smp 2`, idle
| config | klippy Rss | moonraker Rss | Σ Pss |
|---|---|---|---|
| `MALLOC_ARENA_MAX=2` (shipped) | 23.5 MB | 41.0 MB | 57.3 MB |
| glibc default (no cap, = forge-x) | 26.2 MB | 43.7 MB | 59.7 MB |
| **win from cap** | **−2.7 MB** | **−2.7 MB** | **−2.4 MB** |

The cap is worth ~5.4 MB RSS / 2.4 MB Pss **at idle** — a floor; under load (Moonraker
threadpool active → more uncapped arenas) it grows. forge-x ships **no** cap → submitted as
`moonraker-malloc-arena` (MALLOC_ARENA_MAX=2 in its S65moonraker), mirroring the zram PR.

**Per-process baseline (Pss / Rss kB):** klippy 21093 / 26200 · moonraker 38465 / 43636 ·
busybox httpd **188 / 692**.

### Findings so far
- **Runtime levers are exhausted.** `MALLOC_ARENA_MAX=1` and `python -OO` give **no
  measurable win** over the shipped baseline (which already caps arenas at 2). Python RSS
  here is heap objects, not docstrings or arena fragmentation. Keep arena=2; **skip -OO**
  (no benefit, and it forces opt-2 `.pyc` recompiles).
- **httpd → 0.19 MB confirms the nginx removal win** (nginx would be ~2–4 MB RSS).
- **Moonraker (38.5 MB) dominates.** The remaining real lever is **code-page size**
  (Thumb-2/-Os), which shrinks the shared libc/libpython/.so pages all three processes map.
  Heap-side Moonraker savings would need a lighter rewrite (out of scope) or feature trims.
- Reproduce the size build: `lab/mem-experiment/build-size-variant.sh` → `build/output-mem`.

### Conclusions
- **Thumb-2 + -Os + locale purge is the win: −4.9 MB Pss (−8.2 %), −1.08 MB rootfs**, zero
  runtime downside. Built clean; klippy + busybox + python run Thumb-2. **Recommend folding
  into the product `reforge_defconfig`** after a guppyscreen render check under Thumb-2.
- Runtime levers (arena=1, -OO) are exhausted on top of the shipped arena=2.
- The arena cap itself is worth ~2.4 MB Pss; **forge-x lacks it → PR `moonraker-malloc-arena`**.
- Ranked remaining ideas (untested): jemalloc tuned (`narenas:1,dirty_decay_ms:0`) vs glibc;
  trimming Moonraker further; these chase the 35 MB Moonraker heap, which dominates.
- **Thumb-2 fold validated + shipped** (`reforge_defconfig`): klippy ran and **GuppyScreen
  renders to the 800×480 fb under Thumb-2** (`make qemu-render` PASS).

## VM / swap tuning (shipped: reforge `zram-setup.sh` + forge-x `init_swap.sh`)

- **`vm.swappiness=100`** (max on 5.4) — with fast zram swap, readily push cold anon pages to
  compressed swap to free RAM.
- **`vm.page-cluster=0`** — disable swap read-ahead; zram is fast random-access, so batching
  reads just wastes decompression.

## transparent_hugepage=never — VERIFIED NO-OP on this hardware

The stock 5.4.61 kernel config has **no `CONFIG_TRANSPARENT_HUGEPAGE`** (only the unrelated
`ARCH_WANT_GENERAL_HUGETLB` capability). So `/sys/kernel/mm/transparent_hugepage/` does not
exist and `=never` does nothing. THP is only a consideration in Plan 5 with our own kernel —
where we simply won't enable it.

## guppyscreen arena cap (shipped: reforge S75guppyscreen + forge-x S80guppyscreen)

GuppyScreen is multi-threaded (LVGL loop + Moonraker WebSocket client thread) → gets
`MALLOC_ARENA_MAX=2` like klippy/moonraker. Same mechanism as the measured Moonraker win
(−2.7 MB RSS), zero downside.

## Moonraker [update_manager] — tested; reforge keeps it OFF

reforge `moonraker.conf` ships `[update_manager]` disabled. Cost of enabling it (qemu
`-m 128`, idle, web + git updaters):

| | moonraker Pss | moonraker Rss |
|---|---|---|
| OFF (shipped) | 38.4 MB | 43.6 MB |
| ON | 39.0 MB | 44.2 MB |
| cost | +0.6 MB | +0.6 MB |

The +0.6 MB is a **floor**: `git` is absent from the reforge rootfs, so the `git_repo`
updater fails init early (cost understated) and `enable_auto_refresh: False` means no
periodic-refresh state held. The real reason to keep it off is **the dependency** —
update_manager needs `git` (+ deps: tens of MB of rootfs, plus git's own RSS when it runs).
Reforge flashes via a USB `.tgz`, so in-place git updates aren't needed. **Decision: stay
disabled** — the win is avoiding `git` in the image, not the 0.6 MB. (Probe tweak:
`make qemu-mem TWEAKS=updmgr`.)

## Caveats

- qemu has no MCU → klippy sits in error/retry, but Python + all modules are loaded, so
  RSS/code-size deltas are representative; absolute MemAvailable is optimistic vs a printing
  load. zram modules are built for the stock kernel; under the virt kernel they may not load,
  so swap may be absent in-probe (Pss is swap-independent; note MemAvailable accordingly).
- Thumb-2 affects **userspace only** here; the stock-kernel zram .ko keep their ARM-mode
  vermagic. Validate guppyscreen/klipper still run after the Thumb-2 rebuild (NEON chelper
  builds Thumb-2-compatible with `-mcpu=cortex-a7`).

## Update 2026-06-08

Production reverted **klippy** to glibc malloc (NO jemalloc): on real hardware jemalloc's LD_PRELOAD corrupts klippy's NEON `c_helper.so` heap (`free(): invalid size` abort). jemalloc is kept for **moonraker** (+ guppyscreen) only. The whole-stack-jemalloc conclusion in this snapshot applies to moonraker/guppyscreen, not klippy. See `etc/init.d/S60klipper` + `docs/boot.md`.
