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
| **nginx → busybox httpd** | serve the Mainsail SPA statically; browser hits Moonraker `:7125` direct (no reverse proxy) | **−~3 MB RSS** (httpd Pss 0.19 MB vs nginx ~2–4 MB) | `S70httpd`, mainsail package |
| **zram compressed swap** | zstd-compressed RAM swap on the stock kernel (loadable `.ko`) | ~**4× compression** of cold anon pages → effective RAM gain; high-prio over eMMC | `modules/zram-bsp/`, `S35zram` |
| **zram VM tuning** | `vm.swappiness=100` (push cold pages to fast zram) + `vm.page-cluster=0` (no swap read-ahead) | makes zram actually get used; less eMMC swap thrash | `modules/zram-bsp/zram-setup.sh` |
| **single shared Python interpreter** | klippy + moonraker share one python3 → COW page sharing of code/libs | avoids a second interpreter's resident set | by design |
| **Moonraker trimmed** | `update_manager`/`spoolman`/`notifier`/`ldap` off | smaller resident set; **avoids the `git` dependency** (tens of MB rootfs) | `moonraker.conf` |

**Note on `MALLOC_ARENA_MAX=2`:** this was the prior allocator win (−2.7 MB/daemon vs glibc
default) and is still what the **forge-x PRs** ship. ReForge has now **superseded it with jemalloc**
(jemalloc ignores `MALLOC_ARENA_MAX`). A forge-x jemalloc change is under evaluation.

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
