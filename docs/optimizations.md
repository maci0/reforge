# ReForge optimizations & tuning — impact summary

Every memory/size/perf lever we apply, with its **measured** impact, on the 128 MB Allwinner
T113 (dual Cortex-A7). The headroom problem is RAM: the shared Python (klippy + moonraker) is
the dominant consumer. Measurement method: `tests/qemu-harness/mem-probe.sh` at `-m 128 -smp 2`
(real device RAM + cores), per-process **Pss/Rss** from `/proc/<pid>/smaps_rollup`. Full
write-ups: [`docs/research/`](research/).

## Shipped wins

| lever | what it does | measured impact | where |
|---|---|---|---|
| **gcc 15.2 (toolchain)** | flip `BR2_GCC_VERSION_15_X=y` (up from BR 2026.02.2 LTS's default gcc 14.3); newer optimizer + tuned glibc give 25–50 % smaller shared libraries that get mmap'd into every process | **−10.16 MB Σ Pss (−17.0 %)** at `-m 128` under qemu virt, NOSWAP. Per-binary: libpython3.14.so −29.5 %, numpy `_multiarray_umath` −34.4 %, libcrypto.so.3 −27.0 %, libc.so.6 −36.8 %, libsqlite3 −48.4 %, klippy `c_helper.so` −26.6 %. rootfs.tar 157 MB → 144 MB (−8.3 %). Loop: the 2026-06-04 toolchain sweep (variant fragments in [`lab/toolchain-memory/`](../lab/toolchain-memory/)). | `reforge_defconfig` (`BR2_GCC_VERSION_15_X`) |
| **jemalloc (tuned)** | `LD_PRELOAD` jemalloc with `MALLOC_CONF=narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0` — single arena + **no thread-cache** + zero-decay (return freed pages to the OS immediately) | **−6.5 MB Σ Pss (−11.2 %)** vs glibc (the original 2026-05 measurement), plus **another −0.9 MB** from adding `tcache:false` (iter 3, 2026-06-04 — jemalloc's per-thread cache otherwise hoards memory). _Measured with jemalloc on all daemons under qemu; klippy was later reverted (see note), so the on-device win is smaller._ | `reforge_defconfig` (`BR2_PACKAGE_JEMALLOC`) + `S65moonraker`/`S75guppyscreen` (**not** klippy) |
| **Thumb-2 + -Os + locale purge** | smaller code → fewer resident code pages across every process; smaller rootfs | **−4.9 MB Σ Pss (−8.2 %)**, **−1.08 MB** rootfs | `reforge_defconfig` (`BR2_ARM_INSTRUCTIONS_THUMB2`, `BR2_OPTIMIZE_S`, `BR2_ENABLE_LOCALE_PURGE`) |
| **LTO (all packages)** | link-time cross-TU dead-code elimination + inlining → smaller `.text`/rootfs on top of -Os/Thumb-2 | _enabled; cross-package effect overlaps with LTO so the marginal `-ffunction-sections -fdata-sections` win is null (autoresearch iter 8: +75 kB, noise)_ | `reforge_defconfig` (`BR2_ENABLE_LTO`) |
| **nginx → busybox httpd** | serve the Mainsail SPA statically; browser hits Moonraker `:7125` direct (no reverse proxy) | **−~3 MB RSS** (httpd Pss 0.19 MB vs nginx ~2–4 MB); also −~0.6 MB vs forge-x's full httpd (Pss 0.7 MB) | `S70httpd`, mainsail package |
| **zram compressed swap** | zstd-compressed RAM swap on the stock kernel (loadable `.ko`) | ~**4× compression** of cold anon pages → effective RAM gain; high-prio over eMMC | `modules/zram-bsp/`, `S35zram` |
| **zram VM tuning** | the runtime sysctls for the zram-as-primary-swap profile: `vm.page-cluster=0` (zram is RAM — no swap read-ahead), `vm.swappiness=100` (prefer compressed-RAM swap over eMMC file re-reads), `vm.vfs_cache_pressure=50`, `vm.watermark_scale_factor=40` (kswapd reclaims ahead of demand), `vm.dirty_ratio=10` / `vm.dirty_background_ratio=5` | makes zram actually get used + targets the measured direct-reclaim/throttle storm; **no fixed RAM cost** | `.shell/reforge-vmtune.sh`, sourced by `S35zram` right after `swapon` |
| **single shared Python interpreter** | klippy + moonraker share one python3 → COW page sharing of code/libs | avoids a second interpreter's resident set | by design |
| **Moonraker trimmed** | `[octoprint_compat]` removed; `spoolman`/`notifier`/`ldap`/`announcements`/`job_state`/`analysis` off; `file_system_observer: none` (stock kernel has no `CONFIG_INOTIFY_USER`, so the observer would `OSError(ENOSYS)` and crash the server); `update_manager` configured with `provider: simple` + `type: web` (no `type: git_repo`) | smaller resident set; `[octoprint_compat]` removal is ~100 kB Pss (iter 4 subset). Going further — dropping `[history]` + `[update_manager]` too — measures at −1.4 MB but breaks OTA; documented in-conf as opt-in. | `moonraker.conf` |
| **no Fortran toolchain** | `BR2_TOOLCHAIN_BUILDROOT_FORTRAN` dropped: numpy uses Fortran only through LAPACK/OpenBLAS, neither enabled | −868 KB rootfs (`libgfortran.so.5`, linked by nothing); no RAM change, faster toolchain build (`125d529`) | `reforge_defconfig` |

**Note on jemalloc and klippy:** jemalloc is `LD_PRELOAD`ed for **moonraker and guppyscreen only**.
It is **deliberately NOT used for klippy** — on real hardware jemalloc's `LD_PRELOAD` corrupts
klippy's `c_helper.so` heap and klippy aborts (`free(): invalid size`) shortly after the heater
checks. The qemu probe never hit this (klippy ran in a no-MCU state), so the original −6.5 MB figure
counted klippy's jemalloc savings; on-device that portion is forfeited (klippy keeps the default
glibc allocator). `S60klipper` ships without the preload by design.

**Note on `MALLOC_ARENA_MAX=2`:** this was the prior allocator win (−2.7 MB/daemon vs glibc
default) and is still what the **forge-x PRs** ship. ReForge has now **superseded it with jemalloc**
(jemalloc ignores `MALLOC_ARENA_MAX`). [Buildroot-only Forge-X tests](research/memory/2026-10-28-forgex-buildroot-memory.md)
measured trim/jemalloc candidates across 24 boots; allocator results overlap baseline, so no
production change is adopted.

**Note on the zram VM tuning:** the six knobs above are the "no fixed RAM cost" set from the
runtime-tuning audit ([`docs/research/memory/2026-06-02-stock-kernel-runtime-tuning.md`](research/memory/2026-06-02-stock-kernel-runtime-tuning.md)).
The two knobs that **do** cost reserved RAM — `vm.min_free_kbytes` (≈+2.7 MB always-free) and
`vm.extra_free_kbytes` — are deliberately **not** shipped: they are measure-first, pending a
before/after on the reclaim *rates* across a real print. The same audit also closes out
`cpufreq` governor tuning, KSM, compaction and the CFS latency knobs as **not runtime-available**
on this BSP kernel (no driver / config), so they are not pursued **on stock** — the worthwhile
ones (compaction, CFS-debug, cpufreq, MGLRU) carry forward as Plan-5 kernel-build levers (below).
forge-x ships the same six via
`DrA1ex/ff5m#66`.

**Measured impact (qemu, `make vmtune-bench`):** A/B under an identical 150 MB random-churn
workload at `-m 128` with zram active (baseline = stock sysctls vs the tuned profile) showed the
tuned profile **eliminating direct-reclaim stalls** (`allocstall_normal 4→0`, `pgscan_direct_throttle
−10 %`) and a consistent **~1.3 % drop in swap traffic** (`pswpin`/`pswpout`/`pgmajfault`) with
~9 % less data pushed to zram. Honest caveat: `page-cluster=0` is **nearly inert in a zram-only
config** — zram is `SWP_SYNCHRONOUS_IO`, so the kernel skips swap read-ahead and `page-cluster`
has no effect on zram swap-in (the bench confirmed `pswpin` barely moved despite worst-case random
access). It still matters for the device's **eMMC overflow swapfile** (the async path), which the
qemu rig doesn't model; the bench's measurable wins are the reclaim-ahead knobs
(`watermark_scale_factor`). The values are net-positive and zero-cost regardless.

## Measured, not adopted

| lever | measured impact | blocker |
|---|---|---|
| **musl instead of glibc** (gcc -Oz) | **−2.9 MB Σ Pss (−5.2%)**, about −2.1 MB of it klippy (qemu, 2026-10-27) | Hardware validation; the stock `firmwareExe` (glibc) cannot run on a musl rootfs; klippy's share is likely musl's allocator, not separated. [Write-up](research/memory/2026-10-27-clang-oz-musl-memory.md). |
| **mainline 7.3 board kernel** (`make kernel-mainline`) | **−5.2 MB** static kernel memory: 7.41 MB vmlinux vs stock 10.59 MB + 2.02 MB `8821cu.ko` (`size` only) | Does not boot yet: no mainline board DTS, panel timings, SMP bring-up. Run-time kernel memory unmeasured. [Write-up](research/kernel/2026-10-27-mainline-board-kernel.md). |

## Plan-5 kernel-build levers (not on stock 5.4.61)

These are **not** runtime-tunable on the stock BSP kernel (the configs/drivers aren't built),
so they're out of reach for P1–P3. They become available when ReForge ships its **own** kernel
(Plan 5, mainline 6.x LTS). Listed here so the memory work carries forward. Full analysis:
[`docs/research/memory/2026-06-02-stock-kernel-runtime-tuning.md`](research/memory/2026-06-02-stock-kernel-runtime-tuning.md) §7 / §7.1.

| lever | why enable | cost / caveat |
|---|---|---|
| **`CONFIG_COMPACTION=y`** | live vmstat shows **`allocstall_movable 5236`** (movable-alloc stalls → direct reclaim) + CMA-16M contiguous pressure for display/camera; compaction migrates pages to satisfy high-order/CMA allocs instead of stalling. Unlocks `vm.compact_memory` (manual defrag), `compact_unevictable_allowed`, `extfrag_threshold`, and `compaction_proactiveness` (6.x). `CONFIG_MIGRATION=y` already set. | `kcompactd` CPU on 2 cores — keep proactiveness low (~20); reactive-only on <5.9. Reduces fragmentation, **not** idle RAM. zsmalloc's own compaction is separate. |
| **MGLRU (`lru_gen`)** | default on 6.1+; far better hot/cold detection than 5.4's 2-gen LRU — directly relevant to this swap-heavy box | none meaningful; needs the 6.x kernel |
| **`CONFIG_SCHED_DEBUG=y`** | exposes CFS latency knobs (`sched_latency_ns`, …) if klippy stepping ever needs them | debug surface; off by default |
| **real cpufreq driver / `schedutil`** | T113 BSP binds no DVFS driver → CPU at fixed clock today; mainline could add actual scaling | board-specific bring-up |
| **THP `madvise`** | debatable on 128 MB — likely leave off | fragmentation/RAM overhead on low memory |

## Ruled out — measured, not worth it (evidence saved effort)

| lever | result | why |
|---|---|---|
| `MALLOC_ARENA_MAX=1` (vs 2) | **null** (≈noise) | low arena pressure at our thread counts; already implied by jemalloc's `narenas:1` |
| `python -OO` | **− −0.27 % regression** (+160 kB Pss, +5σ above baseline, autoresearch iter 1, 2026-06-04) | Python recompiles every imported module's `.pyc` → `.opt-2.pyc` on first run, doubling the bytecode cache pressure on the page cache. The docstring-strip win is real but tiny; the recompile churn overwhelms it on a cold-cache boot. |
| jemalloc **defaults** (untuned) | **−0.8 MB** (wash) | jemalloc defaults favor throughput (page caching); the win is entirely the zero-decay tuning |
| jemalloc `background_thread:true` | **null at idle** | only helps async-purge latency under churn; costs a thread |
| jemalloc `metadata_thp:never` | **+180 kB** vs `metadata_thp:auto` (autoresearch iter 6, 2026-06-04) | small but real pessimization; the default is the right answer |
| `-ffunction-sections -fdata-sections` (per-package) | **null** (+75 kB, ~2σ, autoresearch iter 8) | overlaps almost entirely with `BR2_ENABLE_LTO=y` (LTO already does cross-TU dead-code elimination within each LTO scope); the residual cross-package gain is in the noise floor |
| **clang as system toolchain** | **−0.3 to −0.6 MB** Σ Pss (clang 23 -Oz vs gcc -Oz, 2026-10-27) | Works by overriding `TARGET_CC`/`TARGET_CXX` with `lab/toolchain-memory/clang-cc.sh` after a GCC-built toolchain. Needs six gcc compatibility fixes; two failed only at run time (missing `__aeabi_d2h`, greenlet frame pointer) and silently killed klippy. Not worth it for the gain. [Write-up](research/memory/2026-10-27-clang-oz-musl-memory.md). |
| `-Oz` + function/data sections + no unwind tables + `--gc-sections -s` (gcc) | **−0.17 to −0.31 MB** Σ Pss, rootfs −2.9 MB (2026-10-27) | Barely past the noise floor. busybox ignores the flags. Same write-up. |
| forge-x klippy `MALLOC_ARENA_MAX=2` / `=1` | **null** / **−287 kB** klippy Pss (forge-x 1.4.2-beta-4, Feather, 2026-10-27) | klippy runs 4 threads. [Write-up](research/memory/2026-10-27-forgex-klippy-malloc-arenas.md). |
| `transparent_hugepage=never` | **no-op** | stock 5.4.61 kernel has **no `CONFIG_TRANSPARENT_HUGEPAGE`** |
| `[update_manager]` git path (`type: git_repo`) | kept **off** | needs `git` (tens of MB rootfs); +0.6 MB RAM. ReForge OTA uses the patched SimpleProvider (`provider: simple`) + `type: web` for Mainsail — see [ota.md](ota.md) |

## Stacking & caveats

- The wins target **independent** memory regions: gcc 15.2 = code pages of every mmap'd .so,
  jemalloc = heap, Thumb-2/-Os = code pages of stock packages, httpd = a whole process. They
  largely **stack** — the autoresearch loop measured the cumulative impact end-to-end:

  | stage | Σ Pss (kB) | Δ vs original baseline | cumulative Δ % |
  |---|---:|---:|---:|
  | original baseline (gcc 14.3, jemalloc-tight, full moonraker.conf) | 59 587 | — | — |
  | + Phase 1 runtime tweaks (`tcache:false` + moonraker `[octoprint_compat]` drop) | 57 515 | −2 072 | −3.5 % |
  | + Phase 2 (gcc 14.3 → gcc 15.2) | 49 428 | −10 159 | −17.0 % |
  | + Phase 1 × Phase 2 stack (**PRODUCTION**) | **47 488** | **−12 099** | **−20.3 %** |

  Noise floor: σ(Σ Pss) = 33.5 kB over 3 warm reruns; 3σ signal threshold = 100 kB.
  Per-iter variant fragments: [`lab/toolchain-memory/`](../lab/toolchain-memory/).

- Measurements are **idle** (klippy in no-MCU state, Moonraker threadpool quiescent). jemalloc's
  advantage typically **grows under load** (allocation churn), so −6.5 MB is a floor.
- Numbers are from qemu at the real `-m 128`; zram `.ko` don't load under the qemu virt kernel
  (vermagic preempt mismatch), so swap is absent in-probe — Pss/Rss deltas are unaffected
  (swap-independent), but in-probe `MemAvailable` understates the on-device zram benefit.
- **vs forge-x default install (UI-less, same qemu rig):** ReForge production saves
  **−7 014 kB / −14.5 %** on the klippy+moonraker+httpd subtotal, **−9 107 kB / −18.2 %** on
  all userspace, **−11 155 kB / −22.3 %** counting forge-x's already-swapped pages. The big delta
  is klippy (−42 %) and is almost entirely toolchain (gcc 15.2 + Python 3.14 + glibc 2.42 +
  LTO vs forge-x's stock FF toolchain + Python 3.7.11). Full breakdown:
  [`docs/research/memory/2026-06-05-reforge-vs-forgex-memory.md`](research/memory/2026-06-05-reforge-vs-forgex-memory.md).

## Reproduce

- `sudo make qemu-mem [TWEAKS=...]` runs the probe; `lab/mem-experiment/build-*-variant.sh` builds
  the A/B variants (Thumb-2, jemalloc). See [`docs/research/memory/2026-06-01-memory-savings-experiments.md`](research/memory/2026-06-01-memory-savings-experiments.md)
  and [`…-jemalloc-test-plan.md`](research/memory/2026-06-01-jemalloc-test-plan.md) for the raw runs.
- The 2026-06-04 toolchain loop drove the gcc/jemalloc sweep; pass `NOSWAP=0` to the probe for
  production-realistic measurements (zram + eMMC overflow ON) or `NOSWAP=1` for clean RAM-pressure
  A/B. Variant fragments under
  [`lab/toolchain-memory/`](../lab/toolchain-memory/).
- For a forge-x comparison run: `tests/qemu-harness/mem-probe-forgex.sh <label>` (slices the
  forge-x rootfs from `tools/recovery/forge-x-*.img.gz`, patches out `ffstartup-arm`, launches
  klippy directly, snapshots like the ReForge probe). `FX_SET="display='FEATHER'
  use_swap='OFF'"` boots forge-x's own defaults; `KLIPPY_ARENA=N` sets klippy's
  `MALLOC_ARENA_MAX`.
- -Oz / clang / musl variants: `lab/toolchain-memory/build-oz.sh gcc|clang [glibc|musl]`
  ([README](../lab/toolchain-memory/README.md)).
