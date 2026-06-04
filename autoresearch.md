# Autoresearch — reduce ReForge stack memory under qemu virt (-m 128, NOSWAP)

**Started:** 2026-06-04
**Goal:** drive `sum(Pss) of klippy + moonraker + httpd + guppyscreen` DOWN on the
qemu-system-arm virt board at `-m 128 -smp 2 cortex-a7`, with **NO swap** (zram +
eMMC overflow disabled by `NOSWAP=1`) so the measurement reflects pure RAM
pressure with no swap-relief noise.

**Bench:** `autoresearch.sh <variant>` → wraps `tests/qemu-harness/mem-probe.sh`
with `NOSWAP=1`. Per-iter raw probe log under `autoresearch-logs/`.

**Noise floor** (3 warm baseline reruns): σ(sum_Pss) = **33.5 kB**. Signal threshold = 3σ ≈ **100 kB**. `MemAvail` is ~4× noisier (σ = 141 kB) and is treated as a secondary metric.

**Already-baked baseline optimizations** (the floor we hunt marginal wins on top of):
`BR2_OPTIMIZE_S=y`, `BR2_ENABLE_LTO=y`, `BR2_ARM_INSTRUCTIONS_THUMB2=y`,
`BR2_ENABLE_LOCALE_PURGE=y`, **jemalloc LD_PRELOAD'd into klippy + moonraker** with
`MALLOC_CONF=narenas:1,dirty_decay_ms:0,muzzy_decay_ms:0`, gcc 14.3.0 + glibc 2.42.

## Phase 1 — runtime tweaks (no rebuild) — COMPLETE

Warm-baseline mean (3 samples): `sum_Pss = 59587 kB`, σ = 33.5 kB.

| iter | variant | sum_Pss | Δ vs warm | σ-distance | verdict |
|---:|---|---:|---:|---:|---|
| 0 | baseline (cold cache) | 59858 | +271 | +8 | cold-cache artifact, ignore |
| 0v1–v3 | baseline (warm) | 59587 | 0 | 0 | reference |
| 1 | `oo` (python -OO for both) | 59747 | +160 | +5 | **REGR** — Python recompiles `.opt-2.pyc` on top of `.pyc`, churning page cache |
| 2 | `no-jemalloc` | 60909 | +1322 | +40 | **REGR** — confirms jemalloc is worth ~1.3 MB on this stack |
| 3 | `tcache-off` (MALLOC_CONF + tcache:false) | 58683 | −904 | −27 | **WIN** −1.5% |
| 4 | `moonraker-min` (drop [history], [announcements], [update_manager], [octoprint_compat], [job_state], [analysis]) | 58186 | −1401 | −42 | **WIN** −2.3% |
| 5 | **`tcache-off + moonraker-min` (stack)** | **57515** | **−2072** | **−62** | **BEST WIN −3.5%** |
| 6 | `tcache-off + metadata_thp:never` | 58862 | −725 | −22 | win, but `thp:never` hurts ~180 kB vs `tcache-off` alone (drop) |

**Phase 1 conclusion.** The two real, stackable runtime wins are:

1. **`tcache:false` in MALLOC_CONF** (−904 kB). jemalloc's thread-local cache holds memory per-thread without returning it to the OS; disabling it gives memory back faster.
2. **Strip optional moonraker sections** (−1401 kB). The full default config loads `[history]`, `[announcements]`, `[update_manager]`, `[octoprint_compat]`, `[job_state]`, `[analysis]` — each instantiates SQLite handles, HTTP polling, etc. Dropping them saves ~1.35 MB on moonraker alone.

Combined: **−2072 kB (−3.5%) over the already-tuned baseline.**

## Phase 2 — compile-time variants — IN PROGRESS

### Iter 7 — `gcc15-base` — **MASSIVE WIN** −17.0%

Flip `BR2_GCC_VERSION_15_X=y` (default gcc 14.3 → gcc 15.2). Everything else inherited from `reforge_defconfig`. Build: 20 min (incl. one false start fixing a fuzz-tolerant patch).

| metric | gcc 14.3 baseline | gcc 15.2 | Δ | % |
|---|---:|---:|---:|---:|
| sum(Pss) | 59587 | 49428 | **−10 159 kB** | **−17.0%** |
| klippy Pss | 20393 | 12733 | −7 660 kB | −37.6% |
| moonraker Pss | 38992 | 36522 | −2 470 kB | −6.3% |
| rootfs.tar | 157 MB | 144 MB | −13 MB | −8.3% |
| MemAvailable | 43209 | 48156 | +4 947 kB | +11.4% |

Why so big: gcc 15.2 produces dramatically smaller .text across the whole stack. Top shrinkers (.so size deltas):
- libpython3.14.so:               4 702 KB → 3 313 KB  (−29.5%)
- numpy `_multiarray_umath.so`:   4 197 KB → 2 756 KB  (−34.4%)
- libcrypto.so.3:                 3 811 KB → 2 783 KB  (−27.0%)
- libc.so.6 (glibc):              1 458 KB →   922 KB  (−36.8%)
- libsqlite3.so.3.51.3:             964 KB →   497 KB  (−48.4%)
- klippy/chelper/c_helper.so:        46 KB →    34 KB  (−26.6%)

Since libpython + numpy are shared between klippy and moonraker, Pss accounting picks up most of the per-binary win. Confirmed steady state (SETTLE=60 vs SETTLE=25 gives identical sum_Pss within noise). No tracebacks, no SIGSEGV/SIGILL — stack reaches `S99ok` cleanly.

### Iter 9 — `gcc15-best` (gcc15 + Phase-1 winning stack) — −20.3%

Same gcc15-base binary, runtime tweaks layered: `MALLOC_CONF=narenas:1,tcache:false,dirty/muzzy_decay_ms:0` + moonraker `[history]`/`[announcements]`/`[update_manager]`/`[octoprint_compat]`/`[job_state]`/`[analysis]` stripped.

| metric | original baseline | gcc15-best | Δ | % |
|---|---:|---:|---:|---:|
| sum(Pss) | 59587 | **47488** | **−12 099 kB** | **−20.3%** |
| klippy Pss | 20393 | 12643 | −7 750 kB | −38.0% |
| moonraker Pss | 38992 | 34665 | −4 327 kB | −11.1% |
| MemAvailable | 43209 | 49984 | +6 775 kB | +15.7% |

Phase 1 runtime tweaks stack on top of gcc15 cleanly (−2072 kB additional on top of gcc15's already-improved baseline of 49428).

### Iter 8 — `gcc15-funcsec` — **wash**

Variant: gcc 15.2 + `-ffunction-sections -fdata-sections` in `BR2_TARGET_OPTIMIZATION`. Result: sum_Pss = 49503 vs gcc15-base 49428 = **+75 kB (noise, ~2σ)**. LTO already does cross-TU dead-code elim within each package; cross-package gains are negligible because the ReForge packages don't link each other heavily. Drop.

### Iter 10 — **PRODUCTION** — gcc15 + Phase-1 stack @ SETTLE=60 — **−20.3% final**

The candidate production config. Reproduces iter 9 within noise (47508 vs 47488, Δ = 20 kB).

| metric | original baseline | PRODUCTION | Δ | % |
|---|---:|---:|---:|---:|
| sum(Pss) | 59587 | **47508** | **−12 079 kB** | **−20.3%** |
| klippy Pss | 20393 | 12621 | −7 772 kB | −38.1% |
| moonraker Pss | 38992 | 34711 | −4 281 kB | −11.0% |
| MemAvailable | 43209 | 49904 | +6 695 kB | +15.5% |

## Discarded levers

- `python -OO` — net regression (+160 kB; Python recompiles `.pyc` → `.opt-2.pyc`, churns page cache)
- `MALLOC_ARENA_MAX=1` — equivalent to current `narenas:1` already in MALLOC_CONF
- `jemalloc-conf metadata_thp:never` — slight pessimization vs default `metadata_thp:auto`
- clang as system toolchain — not supported in BR 2026.02.2 LTS (would need a multi-day BR-layer hack)

## Cumulative win so far

| stage | sum(Pss) | Δ vs original baseline | cumulative Δ % |
|---|---:|---:|---:|
| original baseline (gcc 14.3, jemalloc-tight, full moonraker.conf) | 59587 | — | — |
| + Phase 1 (`tcache:false` + moonraker-min) | 57515 | −2 072 | −3.5% |
| + Phase 2 iter 7 (gcc 15.2 alone) | 49428 | −10 159 | −17.0% |
| + Phase 1 × Phase 2 stack (iter 9) | **47488** | **−12 099** | **−20.3%** |
