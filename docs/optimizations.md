# ReForge optimizations & tuning — impact summary

Every memory/size/perf lever we apply, with its **measured** impact, on the 128 MB Allwinner
T113 (dual Cortex-A7). The headroom problem is RAM: the shared Python (klippy + moonraker) is
the dominant consumer. Measurement method: `tests/qemu-harness/mem-probe.sh` at `-m 128 -smp 2`
(real device RAM + cores), per-process **Pss/Rss** from `/proc/<pid>/smaps_rollup`. Full
write-ups: [`docs/research/`](research/).

## Shipped wins

| lever | what it does | measured impact | where |
|---|---|---|---|
| **jemalloc (tuned)** | `LD_PRELOAD` jemalloc with `MALLOC_CONF=narenas:1,dirty_decay_ms:0,muzzy_decay_ms:0` — single arena + zero-decay (return freed pages to the OS immediately) | **−6.5 MB Σ Pss (−11.2 %)**; klippy Rss 26.3→23.4, moonraker 43.5→38.2; MemAvail +2.2 MB | `reforge_defconfig` (`BR2_PACKAGE_JEMALLOC`) + `S60klipper`/`S65moonraker`/`S75guppyscreen` |
| **Thumb-2 + -Os + locale purge** | smaller code → fewer resident code pages across every process; smaller rootfs | **−4.9 MB Σ Pss (−8.2 %)**, **−1.08 MB** rootfs | `reforge_defconfig` (`BR2_ARM_INSTRUCTIONS_THUMB2`, `BR2_OPTIMIZE_S`, `BR2_ENABLE_LOCALE_PURGE`) |
| **LTO (all packages)** | link-time cross-TU dead-code elimination + inlining → smaller `.text`/rootfs on top of -Os/Thumb-2 | _not yet measured — just enabled; expected small (the `.so` are COW-shared, so the win is mostly code pages/rootfs)_ | `reforge_defconfig` (`BR2_ENABLE_LTO`) |
| **nginx → busybox httpd** | serve the Mainsail SPA statically; browser hits Moonraker `:7125` direct (no reverse proxy) | **−~3 MB RSS** (httpd Pss 0.19 MB vs nginx ~2–4 MB) | `S70httpd`, mainsail package |
| **zram compressed swap** | zstd-compressed RAM swap on the stock kernel (loadable `.ko`) | ~**4× compression** of cold anon pages → effective RAM gain; high-prio over eMMC | `modules/zram-bsp/`, `S35zram` |
| **zram VM tuning** | the runtime sysctls for the zram-as-primary-swap profile: `vm.page-cluster=0` (zram is RAM — no swap read-ahead), `vm.swappiness=100` (prefer compressed-RAM swap over eMMC file re-reads), `vm.vfs_cache_pressure=50`, `vm.watermark_scale_factor=40` (kswapd reclaims ahead of demand), `vm.dirty_ratio=10` / `vm.dirty_background_ratio=5` | makes zram actually get used + targets the measured direct-reclaim/throttle storm; **no fixed RAM cost** | `.shell/reforge-vmtune.sh`, sourced by `S35zram` right after `swapon` |
| **single shared Python interpreter** | klippy + moonraker share one python3 → COW page sharing of code/libs | avoids a second interpreter's resident set | by design |
| **Moonraker trimmed** | `update_manager`/`spoolman`/`notifier`/`ldap` off | smaller resident set; **avoids the `git` dependency** (tens of MB rootfs) | `moonraker.conf` |

**Note on `MALLOC_ARENA_MAX=2`:** this was the prior allocator win (−2.7 MB/daemon vs glibc
default) and is still what the **forge-x PRs** ship. ReForge has now **superseded it with jemalloc**
(jemalloc ignores `MALLOC_ARENA_MAX`). A forge-x jemalloc change is under evaluation.

**Note on the zram VM tuning:** the six knobs above are the "no fixed RAM cost" set from the
runtime-tuning audit ([`docs/research/2026-06-02-stock-kernel-runtime-tuning.md`](research/2026-06-02-stock-kernel-runtime-tuning.md)).
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

## Plan-5 kernel-build levers (not on stock 5.4.61)

These are **not** runtime-tunable on the stock BSP kernel (the configs/drivers aren't built),
so they're out of reach for P1–P3. They become available when ReForge ships its **own** kernel
(Plan 5, mainline 6.x LTS). Listed here so the memory work carries forward. Full analysis:
[`docs/research/2026-06-02-stock-kernel-runtime-tuning.md`](research/2026-06-02-stock-kernel-runtime-tuning.md) §7 / §7.1.

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
| `MALLOC_ARENA_MAX=1` (vs 2) | **null** (≈noise) | low arena pressure at our thread counts |
| `python -OO` | **null** | docstrings/asserts are a tiny fraction of the heap |
| jemalloc **defaults** (untuned) | **−0.8 MB** (wash) | jemalloc defaults favor throughput (page caching); the win is entirely the zero-decay tuning |
| jemalloc `background_thread:true` | **null at idle** | only helps async-purge latency under churn; costs a thread |
| `transparent_hugepage=never` | **no-op** | stock 5.4.61 kernel has **no `CONFIG_TRANSPARENT_HUGEPAGE`** |
| `[update_manager]` for OTA | kept **off** | needs `git` (tens of MB rootfs); +0.6 MB RAM. ReForge OTA uses zip/web instead |

## Stacking & caveats

- The wins target **independent** memory: jemalloc = heap, Thumb-2/-Os = code pages, httpd = a
  whole process. They largely **stack** — combined, the shipped stack is roughly **−14 MB** vs the
  original glibc/-O2/nginx baseline (each delta measured against its own baseline; not a single
  end-to-end run).
- Measurements are **idle** (klippy in no-MCU state, Moonraker threadpool quiescent). jemalloc's
  advantage typically **grows under load** (allocation churn), so −6.5 MB is a floor.
- Numbers are from qemu at the real `-m 128`; zram `.ko` don't load under the qemu virt kernel
  (vermagic preempt mismatch), so swap is absent in-probe — Pss/Rss deltas are unaffected
  (swap-independent), but in-probe `MemAvailable` understates the on-device zram benefit.

## Reproduce

`sudo make qemu-mem [TWEAKS=...]` runs the probe; `lab/mem-experiment/build-*-variant.sh` builds
the A/B variants (Thumb-2, jemalloc). See [`docs/research/2026-06-01-memory-savings-experiments.md`](research/2026-06-01-memory-savings-experiments.md)
and [`…-jemalloc-test-plan.md`](research/2026-06-01-jemalloc-test-plan.md) for the raw runs.
