# Stock kernel runtime tuning audit — AD5M Pro (T113-S3, Linux 5.4.61)

Date: 2026-06-02. Live unit `root@192.168.0.158` (hostname `kunos`), forge-x install,
captured idle-with-light-load (load avg ~0.9, up 1d17h). All probes were **read-only**;
nothing on the device was changed. Goal: find **runtime-tunable** knobs (sysctl / sysfs /
module-param / block-queue) that save memory, improve performance, or improve scheduling
on this 128 MB box, and classify each by how it can be applied.

Hardware/kernel context: dual Cortex-A7 @ fixed clock (no DVFS bound — see §4),
`MemTotal 110 MB` (128 MB SoC − 16 MB CMA − DSP/reserve), `5.4.61 SMP PREEMPT`.
The unit is **already running zram (zstd, 256 MB)** as primary swap above a 64 MB eMMC
swapfile — the forge-x loadable-module setup from the memory investigation. So this audit
treats zram-as-present as the baseline and tunes around it.

**Headline:** the box is under genuine, sustained memory pressure (one OOM-kill in the
current uptime, ~6.3k direct-reclaim allocstalls, ~5.2k direct-reclaim throttle events,
79k major faults, 110k pages swapped out). The single highest-value safe runtime change is
**`vm.page-cluster = 0`** (zram wants no swap-readahead). After that, a small **swappiness**
bump and a modest **min_free_kbytes / watermark_scale_factor** raise to make reclaim kick in
a touch earlier and reduce the direct-reclaim/throttle storm. Most classic "low-RAM" knobs
(THP, KSM, compaction, CFS latency tuning, cpufreq governor) **do not exist at runtime on
this kernel** and are documented below as not-applicable so nobody wastes time on them.

---

## Summary table (bucket a = runtime-settable now)

| Knob | Bucket | Current | Suggested | Effect / rationale |
|---|---|---|---|---|
| `vm.page-cluster` | **a** | `3` | **`0`** | Swap readahead = 2^3 = 8 pages per fault. zram is RAM — readahead just decompresses pages you won't use, wasting CPU + polluting RAM. `0` (1 page) is the standard zram setting. Highest-value safe change. |
| `vm.swappiness` | **a** | `60` | **`100`** | With zstd zram (~3.7× effective), anon pages are cheap to reclaim and the alternative is evicting file/code pages that cause major faults from eMMC. Push the kernel to prefer compressed-RAM swap over dropping clean file pages. |
| `vm.vfs_cache_pressure` | **a** | `100` | **`50`** | Slightly favour keeping dentry/inode cache (cheap, in-RAM) over reclaiming it; reduces repeated metadata re-reads from eMMC. Modest. |
| `vm.min_free_kbytes` | **a** | `1313` | **`4096`** | Current reserve is tiny (~1.3 MB) → kswapd has almost no headroom, so reclaim happens as *direct* reclaim in allocating tasks (klippy/moonraker stall). A bigger floor lets kswapd reclaim ahead of demand. Costs ~2.7 MB of "always free" RAM — measure the trade. |
| `vm.watermark_scale_factor` | **a** | `10` | **`40`–`60`** | Widens the gap between min/low/high watermarks so kswapd starts earlier and runs longer per pass. Directly targets the observed direct-reclaim throttle (`pgscan_direct_throttle 5197`). Cheap; no fixed RAM cost. |
| `vm.dirty_ratio` | **a** | `20` | **`10`** | 20% of 110 MB = ~22 MB of dirty pages can accumulate before forced writeback — large for this box and mostly destined for slow eMMC. Lower cap smooths writeback and frees pages sooner. |
| `vm.dirty_background_ratio` | **a** | `10` | **`5`** | Start background writeback earlier (~5.5 MB) so dirty pages drain steadily instead of in bursts that compete with a print. |
| `vm.dirty_expire_centisecs` | **a** | `3000` | (leave `3000`, or `1500`) | 30 s is fine for a printer; lowering to 15 s only if write bursts are observed. Optional. |
| `vm.extra_free_kbytes` | **a** | `0` | optional `2048` | Adds to the kswapd-wake target without raising the hard reserve (unlike min_free_kbytes). 5.4 still has this knob. Alternative/complement to watermark_scale_factor. |
| zram `comp_algorithm` | **b** (module/setup) | `zstd` | keep `zstd` | Already optimal for 128 MB per the measured ratios (zstd 3.7–4.2× vs lzo-rle 2.74×). `lzo-rle` is the escape hatch if zstd CPU ever contends with klippy mid-print. Set at zram bring-up, not via sysctl. |
| zram `max_comp_streams` | **b** (setup) | `2` | keep `2` | Already = nproc. Correct. |
| zram `disksize` | **b** (setup) | 256 MB | keep / review | 256 MB on 110 MB RAM is aggressive but intentional (compressed). Fine; revisit only if zram `mem_used` approaches a `mem_limit` (none set). |
| block `mmcblk0` scheduler | **a** | `[mq-deadline]` | keep `mq-deadline` | Correct for flash + low core count. `kyber`/`none` give no benefit here. No change. |
| `vm.overcommit_memory` | **a** | `0` (heuristic) | keep `0` | `Committed_AS` already 2.5 GB ≫ RAM (lots of lazily-committed VM); strict overcommit (`2`) would break the Python daemons. Leave heuristic. |
| cpufreq governor | n/a | **no driver bound** | — | `CONFIG_CPU_FREQ=y` but no `cpufreq` sysfs dir exists → no DVFS on this BSP. Governor choice is **inapplicable at runtime**. §4. |
| THP `enabled` | n/a | absent | — | No `transparent_hugepage` node; not in config. Nothing to set. §4. |
| KSM | n/a | absent | — | `CONFIG_KSM` not set; no `/sys/kernel/mm/ksm`. Not runtime-available. §4. |
| `vm.compact_*` | n/a | absent | — | `CONFIG_COMPACTION` not set → no compaction sysctls. zram/zsmalloc run without it. §4. |
| CFS `sched_latency_ns` etc. | **c** | absent | — | `CONFIG_SCHED_DEBUG` not set → CFS tuning knobs not exposed. Only RT-throttle knobs exist. §3/§4. |

---

## 1. Memory pressure: what the live stats actually say

From `/proc/meminfo` and `/proc/vmstat` (full dumps in the appendix):

- `MemTotal 110404 kB`, `MemFree 26064 kB`, `MemAvailable 45008 kB`.
- Swap: zram0 256 MB (16.7 MB used) **priority 100** + eMMC swapfile 64 MB (20.1 MB used)
  priority −2. So ~37 MB is currently swapped; zram took the hot half, the older 20 MB sits
  on flash from before zram was added.
- zram `mm_stat`: `orig 16.86 MB`, `compr 4.50 MB`, `mem_used 5.11 MB` →
  **~3.74× effective** on live pages (consistent with the 4.0× measured earlier; ratio drops
  a little as a wider mix of pages lands in zram). Good.
- Pressure indicators (cumulative over 1d17h uptime):
  - `oom_kill 1` — at least one process was OOM-killed.
  - `allocstall_normal 1078` + `allocstall_movable 5236` = **6314 direct-reclaim stalls**
    (allocations that had to reclaim synchronously — i.e. a task blocked).
  - `pgscan_direct_throttle 5197` — direct reclaim was throttled 5k times (classic sign the
    watermarks/min_free are too tight, so reclaim is always behind).
  - `pgmajfault 79240`, `pswpin 62055`, `pswpout 110146` — heavy paging traffic.
  - `pgsteal_kswapd 749656` vs `pgsteal_direct 300233` — ~29% of reclaim is *direct*
    (should be near-zero on a healthy system; kswapd should do almost all of it).

The direct-reclaim share + throttle count is the actionable signal: **the kernel isn't
reclaiming early enough**, so allocating tasks (klippy, moonraker) stall doing reclaim
themselves. That's what the watermark / min_free / extra_free suggestions target. The
page-cluster + swappiness changes reduce wasted work and bias reclaim toward cheap
compressed-RAM swap instead of expensive eMMC file re-reads.

Honesty note: these are **cumulative counters since boot**, not a rate. They prove pressure
*has occurred*, not that it's continuous. The right validation is a before/after on the
*rates* (`allocstall`, `pgscan_direct_throttle`, `pgmajfault` deltas over a fixed window)
across a real print — see §6.

---

## 2. The runtime knobs (bucket a) — detail

### 2.1 `vm.page-cluster` 3 → 0  (the one clear win)
Path: `/proc/sys/vm/page-cluster`. Current `3`. Swap readahead reads `2^page-cluster`
contiguous pages on every swap-in fault. For a rotating disk that amortises seeks; **for
zram there are no seeks** — every "read" is a synchronous zstd decompress. With
page-cluster=3 each fault decompresses **8 pages** when usually only 1 is needed, burning
A7 CPU and re-populating RAM with cold pages. `0` = read exactly the faulting page. This is
the textbook zram setting (upstream `Documentation/admin-guide/blockdev/zram.rst` and the
zram-generator defaults both use 0). Pure win here; no downside on a swap device with zero
seek cost.

### 2.2 `vm.swappiness` 60 → 100
Path: `/proc/sys/vm/swappiness`. With compressed-RAM swap, swapping an anon page costs a
zstd compress (cheap, stays in RAM) whereas dropping a file/code page costs a future major
fault from **eMMC** (slow, wears flash). At swappiness 60 the kernel still evicts a lot of
file cache; raising toward 100 biases it to compress anon pages into zram instead. This is
the standard recommendation when zram is the swap. Watch CPU: if zstd compress time starts
showing up against klippy during a print, back off to ~80 or switch zram to `lzo-rle`.

### 2.3 `vm.vfs_cache_pressure` 100 → 50
Path: `/proc/sys/vm/vfs_cache_pressure`. Lower = retain dentry/inode caches longer. On a
box that re-reads many small files (Python imports, gcode, config) keeping metadata cached
avoids eMMC round-trips. Modest, low-risk. Don't go below ~50 on 128 MB (the slab caches
themselves cost RAM — `SUnreclaim 13.6 MB` already).

### 2.4 `vm.min_free_kbytes` 1313 → ~4096
Path: `/proc/sys/vm/min_free_kbytes`. Current `1313` (~1.3 MB) is the kernel's auto value
for this RAM size and is *very* tight — zoneinfo shows `min 328 / low 410 / high 492` pages
(1.3/1.6/2.0 MB). With that little slack, the `low` watermark is hit constantly and
allocations fall into direct reclaim before kswapd can get ahead. Raising to ~4 MB gives
kswapd real headroom. **Cost:** that RAM is held permanently free, so on a 110 MB box ~2.7 MB
is a real opportunity cost — this is the one suggestion that *trades* RAM for latency, so
**measure** (§6) before committing. `watermark_scale_factor` (below) gets much of the same
benefit *without* the fixed RAM cost and is the safer first move.

### 2.5 `vm.watermark_scale_factor` 10 → 40–60
Path: `/proc/sys/vm/watermark_scale_factor`. Units = 1/10000 of RAM; controls the
min→low→high spread, i.e. how early kswapd wakes and how far it reclaims before sleeping.
At `10` the spread is ~82 pages (from zoneinfo: low−min = 410−328 = 82 pages ≈ 0.3 MB) — kswapd
wakes barely above the floor and stops almost immediately, so it can't stay ahead of bursty
demand → direct reclaim. `40`–`60` widens that band ~4–6×, letting kswapd batch-reclaim and
keeping allocators out of synchronous reclaim. No fixed RAM cost (it changes *when* reclaim
runs, not how much is reserved). This is the cleanest lever against the observed
`pgscan_direct_throttle`. Prefer this over min_free_kbytes as the first change.

### 2.6 Dirty ratios: `dirty_ratio` 20→10, `dirty_background_ratio` 10→5
Paths under `/proc/sys/vm/`. 20% dirty of 110 MB ≈ 22 MB can buffer before a hard,
everything-blocks writeback — and most of it targets slow eMMC. Halving both caps means
writeback starts sooner and in smaller chunks, so dirty pages become reclaimable faster and
a big flush never collides with a print's I/O. `dirty_expire_centisecs 3000` (30 s) is fine;
optionally 1500 if write bursts show up. Current `Dirty: 12 kB` at idle, so this only matters
under write load (gcode upload, log writes).

### 2.7 `vm.extra_free_kbytes` 0 → ~2048 (optional)
Path: `/proc/sys/vm/extra_free_kbytes` (present on 5.4; removed in later kernels). Adds to
kswapd's wake target *without* raising the hard `min` reserve — so it nudges reclaim earlier
like watermark_scale_factor but is additive and easy to reason about. Use as a complement if
watermark_scale_factor alone doesn't cut the direct-reclaim rate. Don't stack all three to
extremes or you'll just hold RAM idle.

### 2.8 Things that are already correct (leave alone)
- **Block scheduler** `mmcblk0 = mq-deadline` — right for eMMC + 2 cores. `rotational 0`,
  `add_random 0` already set sensibly by the MMC driver. zram scheduler `none` — correct
  (stacked block dev, no reordering wanted).
- **overcommit_memory 0** — must stay heuristic; `Committed_AS 2.5 GB` shows the Python
  daemons lazily commit far more than RAM. Strict mode (`2`) would break allocation.
- **max_map_count 65530**, **mmap_min_addr 4096**, **pid_max 32768**, **threads-max 1429** —
  all default/fine for the workload. No change.
- **net core rmem/wmem 192 KB**, tcp_rmem/wmem default — fine for LAN moonraker/dropbear;
  not a memory or perf concern at this scale. No change.

---

## 3. Scheduling

The workload is "mostly idle + bursts" (klippy real-time-ish stepping during prints, web/UI
otherwise). Relevant facts:

- **No CFS tuning knobs**: `CONFIG_SCHED_DEBUG` is **not set**, so
  `sched_latency_ns`, `sched_min_granularity_ns`, `sched_wakeup_granularity_ns`,
  `sched_migration_cost_ns` are **absent** from `/proc/sys/kernel/`. Only
  `sched_child_runs_first`, `sched_rr_timeslice_ms`, `sched_rt_period_us`,
  `sched_rt_runtime_us` exist. So CFS latency tuning is **not a runtime option** on this
  kernel (it would be bucket c — needs `CONFIG_SCHED_DEBUG=y` in the Plan-5 mainline build).
- **RT throttling**: `sched_rt_runtime_us 950000` / `sched_rt_period_us 1000000` = RT tasks
  capped at 95% — the safe default. Klipper's MCU comms run in userspace (not RT threads on
  this stock setup), so this isn't currently a limiter. Leave default; changing RT throttle
  on a 2-core box risks starving kworkers/kswapd, which would be *worse* under memory
  pressure. No change.
- **PREEMPT** is already configured (`SMP PREEMPT` in uname) — good for latency. Nothing to
  toggle at runtime.
- `kernel.timer_migration 1`, `randomize_va_space 2` — defaults, fine.

Net: there is **no useful runtime scheduling knob** on the stock kernel. The scheduling wins
(CFS latency, possibly `PREEMPT_RT` or threaded-IRQ tuning) are Plan-5 kernel-build items,
not sysctl changes. Documented here so the question is closed.

---

## 4. Not-applicable on this kernel (so nobody re-investigates)

Confirmed absent from the **live** `/proc/config.gz` and/or sysfs:

| Feature | Status | Evidence |
|---|---|---|
| **cpufreq governor** | No DVFS bound | `CONFIG_CPU_FREQ=y` and default gov = `performance`, but **no `/sys/devices/system/cpu/cpu*/cpufreq` directory** and no `cpuidle` dir → the T113 BSP registers no cpufreq driver. CPU runs at a fixed clock. ondemand/schedutil/performance choice is **moot at runtime**. (A real DVFS driver is a Plan-5 mainline item.) |
| **THP** | Not present | No `/sys/kernel/mm/transparent_hugepage`. (Also generally undesirable on 128 MB.) |
| **KSM** | Off, not built | `CONFIG_KSM` not set; no `/sys/kernel/mm/ksm`. (Marginal here anyway — Python pages already COW-shared.) |
| **Compaction** | Off, not built | `CONFIG_COMPACTION` not set → no `vm.compact_*`, no `compaction_proactiveness` (the latter is a 5.9+ knob regardless; we're on 5.4). zsmalloc/zram thus run without compaction support — a fragmentation consideration, not a runtime knob. |
| **MGLRU / `lru_gen`** | Not present | 6.1+ feature; this is 5.4. Cold-page detection is the old 2-gen LRU. (Plan-5 win.) |
| `compaction_proactiveness`, `watermark_boost_factor` semantics | n/a / present-but-default | `watermark_boost_factor 5000` exists (5.4 has it) but only matters with fragmentation/compaction, which is off — leave default. |

---

## 5. zram / module-param (bucket b) — controlled by ReForge's module loading

These aren't sysctls; they're set when `zram.ko` is loaded / zram0 is configured. ReForge
already owns this path (the `zram-setup.sh` / loadable-module work). Current state is good:

- `comp_algorithm = zstd` (options: `lzo lzo-rle [zstd]`). **Keep zstd** — measured 3.7–4.2×
  vs lzo-rle 2.74×; on 128 MB the extra ratio outweighs A7 CPU since swap is intermittent.
  `lzo-rle` is the documented escape hatch if zstd compress time ever contends with klippy
  during a print. (No `lz4` — `CONFIG_CRYPTO_LZ4` not set.)
- `max_comp_streams = 2` = nproc. Correct (parallel compress across both cores).
- `disksize = 256 MB`, no `mem_limit` set. Fine; if you ever want a hard cap on how much RAM
  zram's compressed store may consume, `mem_limit` is the knob (sysfs, set at setup). Not
  needed now.
- Priority: zram0 `100` > eMMC swapfile `−2`. Correct — fills zram first, only overflows to
  flash. Consider whether the eMMC swapfile is even wanted long-term (it adds flash wear for
  the cold tail); that's a policy choice, not a tuning knob.

The zram device exposes `idle` and `writeback` nodes but **no `backing_dev`** is configured
and there's no second-tier writeback target wired — leave as-is.

---

## 6. What to actually do — and what to wire into ReForge

### Worth a ReForge boot hook (an `S`-script that applies safe sysctls at boot)
A tiny init script (e.g. `/etc/init.d/S__sysctl-tune` or appended to the existing zram-setup,
since the zram-relevant ones belong with it) applying the **no-fixed-cost, clearly-safe** set:

```
vm.page-cluster = 0          # zram: no swap readahead   (highest value)
vm.swappiness = 100          # prefer compressed-RAM swap over eMMC file eviction
vm.vfs_cache_pressure = 50   # keep cheap in-RAM metadata cache
vm.watermark_scale_factor = 40   # kswapd wakes earlier → fewer direct-reclaim stalls
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
```

These are reversible, cost no reserved RAM, and `page-cluster`+`swappiness` in particular
*pair with* the zram setup — so the cleanest home is **inside the existing zram bring-up
script**, right after `swapon`, so swap-tuning and swap-setup live together. The dirty/cache
knobs can ride along or sit in a generic sysctl drop-in.

### Apply only after measuring (don't bake in blind)
- `vm.min_free_kbytes 4096` and `vm.extra_free_kbytes 2048` — these **trade ~2.7 MB / ~2 MB of
  RAM** for reclaim latency. On a box this tight, that trade must be justified by data. Run a
  before/after over a real print: sample `grep -E "allocstall|pgscan_direct_throttle|pgmajfault" /proc/vmstat`
  and `free` at start and end, compute deltas. If `watermark_scale_factor` alone already
  drops the direct-reclaim rate to near-zero, **skip** min_free/extra_free entirely and keep
  the RAM.

### Validation method (the honest part)
Every claim above about reducing stalls is a **hypothesis from cumulative counters**, not a
measured before/after. Before declaring any win:
1. Snapshot `/proc/vmstat` (allocstall_*, pgscan_direct_throttle, pgmajfault, pswpin/out),
   `free`, zram `mm_stat`.
2. Run a representative print (or a synthetic memory-pressure burst).
3. Re-snapshot; compare **deltas/rates**, not totals.
4. Confirm zstd CPU isn't stealing from klippy (watch klippy timing/`load average` during the
   print) — if it is, drop swappiness to ~80 or zram to `lzo-rle`.

Single highest-confidence change regardless of measurement: **`vm.page-cluster = 0`** — it
only removes wasted decompression work and has no downside on a seekless swap device.

---

## 7. Plan-5 (mainline kernel) carry-forward (bucket c, informational)

Knobs/features that are **not runtime-available on 5.4** but should be enabled/considered in
the ReForge mainline-LTS (6.x) kernel build:

- `CONFIG_SCHED_DEBUG=y` → exposes CFS latency/granularity sysctls (if we ever want them).
- **MGLRU** (`lru_gen`) — default on 6.1+; far better cold/hot detection than 5.4's 2-gen LRU,
  directly relevant to this swap-heavy workload.
- A real **cpufreq driver** for the T113 (or `schedutil`) — gives actual DVFS, currently absent.
- `CONFIG_COMPACTION=y` — lets zsmalloc/zram reclaim fragmented memory; also enables
  `compaction_proactiveness` (5.9+) as a runtime knob. **Detailed in §7.1.**
- THP `madvise` mode — debatable on low RAM; probably leave off.

These are tracked elsewhere in the Plan-5 kernel notes; listed here only to close the loop on
"is this knob a sysctl or a rebuild?" for each item.

### 7.1 Memory compaction (`CONFIG_COMPACTION`) — possible tuning (Plan-5 kernel)

**Status today: compiled out.** `# CONFIG_COMPACTION is not set` in every sun8iw20p1/T113
kernel defconfig (`arch/arm/configs/sun8iw20p1smp*_defconfig`) and confirmed on the live unit
— `/proc/sys/vm/compact_memory`, `compact_unevictable_allowed`, `extfrag_threshold` are all
absent and `/proc/vmstat` has **no `compact_*` counters**. So there is nothing to tune at
runtime on P1–P3; this is purely a **ReForge-kernel build decision** for Plan 5. `CONFIG_MIGRATION=y`
is already set (it's the prerequisite), so enabling compaction is a small, clean addition.

**What compaction does, and why it could help *this* box.** Compaction migrates movable pages
together to free up physically-contiguous (high-order) blocks, instead of failing or
direct-reclaiming when a >order-0 allocation can't be satisfied in a fragmented zone. On a
128 MB SoC the contiguous-allocation pressure is real:

- **`allocstall_movable 5236`** in the live vmstat (vs `allocstall_normal 1078`) — the *movable*
  allocation class is the dominant stall source, and movable allocations are precisely what
  compaction services. Without compaction those stalls fall straight into direct reclaim
  (which the §2 watermark knobs only partially relieve). This is the single strongest argument
  for enabling it.
- **CMA = 16 MB** carved for display/camera + DMA-contiguous needs. CMA migration *uses the
  compaction machinery*; with `CONFIG_COMPACTION` off the kernel has fewer tools to vacate a
  CMA region when the framebuffer/camera needs a large contiguous buffer, so a fragmented box
  can fail a CMA grab even when `CmaFree` looks ample (the appendix already shows odd
  `CmaFree > CmaTotal` accounting). Compaction makes CMA reclaim more reliable.
- zram's `zsmalloc` has its **own** internal compaction (`mm_stat: pages_compacted 1963`) — that
  is *separate* from kernel `CONFIG_COMPACTION` and already runs. So enabling kernel compaction
  helps the page-allocator / CMA side, **not** the zram store (don't double-count the benefit).

**Runtime knobs it unlocks (once built):**

| sysctl | default | meaning |
|---|---|---|
| `vm.compact_memory` | write-only | write `1` → one synchronous full-system compaction pass. A cheap **manual defrag**; good to fire once before an operation that needs contiguous memory (e.g. starting the camera/UI, or post-print). |
| `vm.compact_unevictable_allowed` | `1` | allow compaction to migrate unevictable (e.g. mlock'd) pages. Leave `1` for best defrag on a tight box; `0` only if a latency-sensitive mlock'd region must never be migrated. |
| `vm.extfrag_threshold` | `500` | fragmentation index (0–1000) above which the allocator prefers **compaction over reclaim** for a high-order request. Lower → compact more eagerly. Leave default unless high-order failures persist. |
| `vm.compaction_proactiveness` | n/a on 5.4 | **5.9+ only.** Background proactive compaction (0–100). If Plan-5 lands a 6.x LTS, set this **low (~20)** so kcompactd trickle-defrags without stealing A7 cycles from klippy. On 5.4 compaction is reactive-only (on allocation failure or manual `compact_memory`). |

**Costs / caveats.**
- A `kcompactd0` kernel thread + CPU for page migration — non-trivial on 2 cores; keep
  proactiveness low (or rely on reactive + manual triggers on 5.4) so it never competes with a
  print's real-time stepping.
- Tiny code-size add; negligible idle RAM.
- Compaction reduces *fragmentation*, not total RAM use — it won't lower idle Pss. Its win is
  fewer high-order/CMA allocation failures and fewer `allocstall_movable` direct-reclaim stalls.

**Recommendation.** Enable `CONFIG_COMPACTION=y` in the Plan-5 mainline kernel (cheap, and the
`allocstall_movable` + CMA evidence justifies it). On a 6.x build also expose
`compaction_proactiveness` and set it modestly (~20). **Validate** before claiming a win: snapshot
`allocstall_movable`, `pgscan_direct_throttle`, and any high-order/CMA allocation-failure counters
(`/proc/vmstat compact_fail`, `compact_stall`) before/after over a real print + a camera start,
and confirm kcompactd CPU doesn't show up against klippy timing. A one-shot
`echo 1 > /proc/sys/vm/compact_memory` before a CMA-heavy operation is the safest first use.

---

## 8. Applicability to stock forge-x

Everything in this audit was captured **on a forge-x install** (`DrA1ex/ff5m`) — the live
unit `kunos` runs stock forge-x, not ReForge. forge-x is a stock-overlay mod for the same
AD5M/Pro: identical T113-S3 SoC, identical stock Linux 5.4.61 kernel, identical ~128 MB RAM.
A sysctl is a property of the running kernel, so **every runtime knob below applies to
forge-x exactly as it applies here** — same paths, same defaults, same effect. There is no
kernel difference to account for.

The one thing that *does* differ is starting state: forge-x already ships its own zram swap
via **PR #66** ("Add ZRAM compressed swap option", `maci0:add-zram-swap`), and that PR's
`activate_zram_swap()` in `.shell/boot/init_swap.sh` already sets some of these sysctls right
after `swapon`. So for forge-x the question per knob is not "does it apply" (it does) but
"does forge-x already set it." Derived from the **actual PR #66 diff**:

### Already set by forge-x PR #66 (no action needed)
Both are written immediately after the zram `swapon`, exactly where this report recommends:

| Knob | Value in PR #66 | Matches report? |
|---|---|---|
| `vm.swappiness` | `100` | yes — identical |
| `vm.page-cluster` | `0` | yes — identical |

These are the two highest-value zram knobs and PR #66 already nails both, with the same
reasoning (page-cluster=0 to kill swap readahead, swappiness=100 to prefer compressed-RAM
swap over eMMC file eviction).

### Applies to forge-x but was MISSING from PR #66 (the no-fixed-cost remainder)
These apply identically on forge-x but PR #66 did not set them. They are the rest of the
"no-fixed-cost, clearly-safe" set from §6 — they change reclaim/writeback *timing* only and
reserve no RAM, so they belong in the same place as the two above:

| Knob | Suggested | Why it applies to forge-x too |
|---|---|---|
| `vm.vfs_cache_pressure` | `50` | Same eMMC + small-file workload; keep in-RAM metadata cache. |
| `vm.watermark_scale_factor` | `40` | Same tight auto watermarks → same direct-reclaim throttling; widen the band so kswapd stays ahead. |
| `vm.dirty_ratio` | `10` | Same 110 MB / slow-eMMC writeback target; cap dirty pages low. |
| `vm.dirty_background_ratio` | `5` | Start background writeback early so flushes don't collide with a print. |

(These have since been added to PR #66's `activate_zram_swap()`, right after the existing
`swappiness`/`page-cluster` lines, so forge-x and ReForge converge on the same boot-time set.)

### Measure-first (docs only on forge-x too — RAM trade)
`vm.min_free_kbytes` (→ ~4096) and `vm.extra_free_kbytes` (→ ~2048) trade ~2.7 MB / ~2 MB of
permanently-reserved RAM for reclaim latency. The trade is **identical** on forge-x (same RAM,
same auto-computed `min_free_kbytes 1313`), so the same advice holds: don't bake in blind,
measure a before/after over a real print, and skip them entirely if `watermark_scale_factor`
already drops the direct-reclaim rate. PR #66 correctly does **not** set these.

### Not-applicable — equally N/A on forge-x
Because forge-x runs the byte-identical stock kernel, the knobs ruled out in §4 are absent on
forge-x for the same reasons — there is nothing for forge-x to set either:

- **cpufreq governor** — no DVFS driver binds on the T113 BSP; no `cpufreq` sysfs dir.
- **THP / KSM / compaction / MGLRU** — not built into the stock 5.4.61 kernel (`CONFIG_*`
  not set); no sysfs/sysctl nodes exist.
- **CFS latency knobs** (`sched_latency_ns` etc.) — `CONFIG_SCHED_DEBUG` not set, so the
  knobs are not exposed.

These are kernel-build items (Plan-5 / mainline-LTS) regardless of which mod is installed.

### zram module params (bucket b)
forge-x's PR #66 sets `comp_algorithm` (user-selectable `zstd`/`lzo-rle`/`lzo`, default
`zstd`) and `disksize` (256 MB) at zram bring-up — the same values §5 recommends. These are
setup-time params, not sysctls; forge-x already owns them. No change.

---

## Appendix — raw captures (read-only, 2026-06-02, live unit)

### A. uname / cmdline / cpu
```
Linux kunos 5.4.61 #52 SMP PREEMPT Wed Aug 23 15:33:33 CST 2023 armv7l GNU/Linux
nproc = 2   (cpu online 0-1)
ARMv7 rev 5 (v7l), Features: half thumb fastmult vfp edsp neon vfpv3 tls vfpv4 idiva idivt vfpd32 lpae, BogoMIPS 48.00
cmdline: earlycon=uart8250,mmio32,0x05000000 clk_ignore_unused initcall_debug=0 console=ttyS3,115200 loglevel=4
  root=/dev/mmcblk0p6 init=/init partitions=... cma=16M ... androidboot.hardware=sun8iw20p1 ... disp_reserve=1536000,0x448ee000 androidboot.dramsize=128
loadavg: 0.94 0.65 0.43   (up 1 day, 17:37)
```

### B. free / meminfo (selected)
```
             total       used       free     shared    buffers     cached
Mem:        110404      84280      26124         48       5904      16712
-/+ buffers/cache:      61664      48740
Swap:       327672      36892     290780

MemTotal 110404 kB  MemFree 26064  MemAvailable 45008  Buffers 5904  Cached 16712  SwapCached 3792
Active 31436  Inactive 16500  Active(anon) 10724  Inactive(anon) 14660  Active(file) 20712  Inactive(file) 1840
AnonPages 23816  Mapped 14480  Shmem 48  Slab 13624  SReclaimable 0  SUnreclaim 13624  KernelStack 3296  PageTables 1876
SwapTotal 327672  SwapFree 290780  CommitLimit 382872  Committed_AS 2567324
CmaTotal 16384  CmaFree 19332   (CmaFree > CmaTotal: free counts spill; CMA mostly unused at idle)
```

### C. /proc/swaps
```
Filename                                  Type        Size    Used    Priority
/data/.mod/.forge-x/root/swap             file        65532   20148   -2
/dev/zram0                                partition   262140  16744   100
```

### D. /proc/modules
```
zram      24576    1 -                Live 0xbf1f9000
zsmalloc  24576    1 zram,            Live 0xbf1ee000
8821cu  2019328    0 -                Live 0xbf000000 (C)
```

### E. /proc/sys/vm/* (current)
```
admin_reserve_kbytes        3271        dirty_background_ratio    10
dirty_expire_centisecs      3000        dirty_ratio               20
dirty_writeback_centisecs   500         dirtytime_expire_seconds  43200
extra_free_kbytes           0           laptop_mode               0
lowmem_reserve_ratio        32 0        max_map_count             65530
min_free_kbytes             1313        mmap_min_addr             4096
mmap_rnd_bits               8           overcommit_kbytes         0
overcommit_memory           0           overcommit_ratio          50
page-cluster                3           panic_on_oom              0
percpu_pagelist_fraction    0           stat_interval             1
swappiness                  60          user_reserve_kbytes       3271
vfs_cache_pressure          100         watermark_boost_factor    5000
watermark_scale_factor      10          oom_kill_allocating_task  0
admin/user_reserve_kbytes   3271        block_dump                0
```

### F. /proc/sys/kernel/* (selected)
```
sched_child_runs_first 0   sched_rr_timeslice_ms 100
sched_rt_period_us 1000000 sched_rt_runtime_us 950000
panic 0  panic_on_oops 0  threads-max 1429  pid_max 32768
timer_migration 1  randomize_va_space 2
(absent: sched_latency_ns, sched_min_granularity_ns, sched_wakeup_granularity_ns,
 sched_migration_cost_ns, sched_autogroup_enabled  — CONFIG_SCHED_DEBUG not set)
```

### G. /proc/vmstat (pressure-relevant)
```
nr_free_pages 6379
workingset_refault 781752  workingset_activate 134429  workingset_restore 106751
pgpgin 6152771  pgpgout 7463974  pswpin 62055  pswpout 110146
allocstall_normal 1078  allocstall_movable 5236
pgscan_kswapd 6030920  pgscan_direct 2060166  pgscan_direct_throttle 5197
pgsteal_kswapd 749656  pgsteal_direct 300233
pgmajfault 79240  oom_kill 1
```

### H. zram0 state
```
disksize 268435456 (256 MB)   comp_algorithm: lzo lzo-rle [zstd]   max_comp_streams 2   mem_limit (unset)
mm_stat: orig_data_size 16863232  compr_data_size 4504830  mem_used_total 5107712  mem_limit 0
         mem_used_max 11485184  same_pages 390  pages_compacted 1963  huge_pages 21
   → effective ratio ≈ orig/mem_used = 16.86/5.11 ≈ 3.30×  (orig/compr = 3.74×)
io_stat: failed_reads 0  failed_writes 0  invalid_io 0  notify_free 50229
queue/scheduler: none   queue/rotational 0
/sys/module/zram/parameters/ : (empty — no insmod-time params on this module build)
```

### I. block / mmcblk0
```
queue/scheduler: [mq-deadline] kyber none
queue/read_ahead_kb 128   queue/nr_requests 128   queue/rotational 0   queue/add_random 0   queue/iostats 1
```

### J. cpufreq / cpuidle / THP / KSM / compaction — ABSENT
```
/sys/devices/system/cpu/cpu0/cpufreq      -> No such file or directory   (no DVFS driver bound)
/sys/devices/system/cpu/cpu0/cpuidle/     -> No such file or directory
/sys/kernel/mm/transparent_hugepage/      -> No such file or directory   (THP not built)
/sys/kernel/mm/ksm/                       -> No such file or directory   (CONFIG_KSM not set)
/proc/sys/vm/compact*                     -> none                        (CONFIG_COMPACTION not set)
```

### K. config.gz greps (live /proc/config.gz)
```
# CONFIG_COMPACTION is not set
# CONFIG_KSM is not set
# CONFIG_ZSMALLOC is not set            (zsmalloc is the loadable forge-x module, not built-in)
# CONFIG_CRYPTO_LZ4 is not set          (no lz4 zram option)
CONFIG_CRYPTO_ZSTD=y                     (zstd available — what zram uses)
# CONFIG_SCHED_DEBUG is not set          (no CFS sysctls)
CONFIG_CPU_FREQ=y / DEFAULT_GOV_PERFORMANCE=y  (config says yes, but no driver binds at runtime)
CONFIG_MIGRATION=y
```

### L. net core/tcp buffers
```
net.core.rmem_default 196608  net.core.wmem_default 196608  net.core.rmem_max 196608  net.core.wmem_max 196608
net.ipv4.tcp_rmem 4096 131072 847296   net.ipv4.tcp_wmem 4096 16384 847296
```
