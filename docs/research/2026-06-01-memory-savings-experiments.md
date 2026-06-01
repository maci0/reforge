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
- `MALLOC_ARENA_MAX=2` for both klippy + moonraker (caps glibc per-thread arenas)
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

## Caveats

- qemu has no MCU → klippy sits in error/retry, but Python + all modules are loaded, so
  RSS/code-size deltas are representative; absolute MemAvailable is optimistic vs a printing
  load. zram modules are built for the stock kernel; under the virt kernel they may not load,
  so swap may be absent in-probe (Pss is swap-independent; note MemAvailable accordingly).
- Thumb-2 affects **userspace only** here; the stock-kernel zram .ko keep their ARM-mode
  vermagic. Validate guppyscreen/klipper still run after the Thumb-2 rebuild (NEON chelper
  builds Thumb-2-compatible with `-mcpu=cortex-a7`).
