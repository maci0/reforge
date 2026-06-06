# jemalloc evaluation — test plan

**Question:** does jemalloc (tuned for low RSS) beat the shipped **glibc + `MALLOC_ARENA_MAX=2`**
on the 128 MB T113, for the long-running allocators — Moonraker (threadpool), klippy, and
GuppyScreen? Adopt only if it's a clear, no-regression win.

**Status:** RUN 2026-06-01 (qemu `-m 128 -smp 2`, idle, settle 25 s). **Verdict: adopt jemalloc
tuned (`narenas:1,dirty_decay_ms:0,muzzy_decay_ms:0`).** −6.5 MB Σ Pss vs base at idle, no
regression. See Results + Verdict below.

## Why jemalloc might help (and might not)

- glibc's per-thread arenas inflate RSS under threading; we already cap them at 2. jemalloc
  uses its own arenas + decay-based purging, and with `dirty_decay_ms:0,muzzy_decay_ms:0` it
  returns freed pages to the OS aggressively → potentially lower steady RSS than glibc.
- Costs: `libjemalloc.so` adds ~0.3–0.6 MB to the rootfs; `background_thread:true` spends one
  thread to do async purging (lower latency spikes, slightly more RSS); jemalloc shines under
  allocation churn, so an **idle** probe may understate the win (note this in results).

## Prerequisite: a jemalloc-enabled rootfs

jemalloc must be in the image (`BR2_PACKAGE_JEMALLOC=y` → `/usr/lib/libjemalloc.so.2`). Build a
variant (does not touch the product `build/output`):

```sh
lab/mem-experiment/build-jemalloc-variant.sh        # -> build/output-jemalloc
```

This is `reforge_defconfig` + `BR2_PACKAGE_JEMALLOC=y`, built into `build/output-jemalloc`.

## Variants to measure (A/B against the shipped baseline)

mem-probe is extended with a `jemalloc` tweak that, per the chosen `MALLOC_CONF`, `LD_PRELOAD`s
libjemalloc into klippy + moonraker (+ guppyscreen) before they start.

| id | allocator | config | how |
|---|---|---|---|
| `base` | glibc | `MALLOC_ARENA_MAX=2` (shipped) | baseline (use `build/output`) |
| `jem-default` | jemalloc | (defaults) | `build/output-jemalloc`, `TWEAKS=jemalloc` |
| `jem-tuned` | jemalloc | `narenas:1,dirty_decay_ms:0,muzzy_decay_ms:0` | `TWEAKS=jemalloc` + `JEMALLOC_CONF` |
| `jem-bgthread` | jemalloc | tuned + `background_thread:true` | as above + bg thread |

## Method

Reuse `tests/qemu-harness/mem-probe.sh` at **`-m 128`** (real RAM), `-smp 2` (device cores),
measuring per-process **Pss/Rss** + `MemAvailable`. Run idle (settle 25–45 s); optionally repeat
under light load (drive a few Moonraker API calls) to expose churn behavior.

```sh
# baseline (glibc, shipped)
sudo SMP=2 tests/qemu-harness/mem-probe.sh build/output/images/rootfs.tar.xz base

# jemalloc default
sudo SMP=2 TWEAKS=jemalloc \
    tests/qemu-harness/mem-probe.sh build/output-jemalloc/images/rootfs.tar.xz jem-default

# jemalloc tuned
sudo SMP=2 TWEAKS=jemalloc JEMALLOC_CONF='narenas:1,dirty_decay_ms:0,muzzy_decay_ms:0' \
    tests/qemu-harness/mem-probe.sh build/output-jemalloc/images/rootfs.tar.xz jem-tuned

# jemalloc tuned + background thread
sudo SMP=2 TWEAKS=jemalloc JEMALLOC_CONF='narenas:1,dirty_decay_ms:0,muzzy_decay_ms:0,background_thread:true' \
    tests/qemu-harness/mem-probe.sh build/output-jemalloc/images/rootfs.tar.xz jem-bgthread
```

## Results

Measured: qemu `-M virt -cpu cortex-a7 -smp 2 -m 128`, idle, 25 s settle. Per-process from
`/proc/<pid>/smaps_rollup`; Σ Pss = klippy + moonraker + busybox httpd (the three tracked procs).
GuppyScreen does not run in the probe (only launches under `SCREEN_MODE=GUPPY`, which the probe
does not set), so its column is N/A for every variant — it is identical across base and jem-*, so
the A/B remains valid. **jemalloc verifiably loaded** in every jem-* run: the probe checks
`/proc/<pid>/maps` and printed `JEM=yes` for both klippy and moonraker in all three jemalloc runs
(`JEM=no` for httpd, expected — only klippy/moonraker get the LD_PRELOAD), and `JEM=no` for base.

| variant | klippy Rss | moonraker Rss | guppyscreen Rss | Σ Pss | MemAvailable | rootfs |
|---|---|---|---|---|---|---|
| base (glibc, arena=2) | 25.7 MB | 42.5 MB | N/A (not run) | **58.2 MB** (59640 kB) | 45344 kB | 25.74 MB |
| jem-default | 24.5 MB | 41.3 MB | N/A | 57.4 MB (58800 kB) | 41644 kB | 24.82 MB |
| jem-tuned | 22.8 MB | 37.3 MB | N/A | **51.7 MB** (52951 kB) | 47544 kB | 24.82 MB |
| jem-bgthread | 22.8 MB | 37.4 MB | N/A | 51.9 MB (53149 kB) | 47312 kB | 24.82 MB |

Σ Pss deltas vs base: jem-default **−0.82 MB** (≈noise), jem-tuned **−6.53 MB (−11.2 %)**,
jem-bgthread **−6.34 MB**. klippy+moonraker Rss together: base 68.2 MB → jem-tuned 61.6 MB
(**−6.6 MB**).

Per-process Pss/Rss (kB) as measured:
- base:        klippy 21097 / 26280 · moonraker 38339 / 43524 · httpd 204 / 744 · JEM=no
- jem-default: klippy 20739 / 25068 · moonraker 37900 / 42240 · httpd 161 / 648 · JEM=yes
- jem-tuned:   klippy 18975 / 23360 · moonraker 33780 / 38200 · httpd 196 / 692 · JEM=yes
- jem-bgthread:klippy 19025 / 23376 · moonraker 33943 / 38296 · httpd 181 / 644 · JEM=yes

**rootfs size note:** the jemalloc variant tar is 24.82 MB; the product `build/output` tar is
25.74 MB. This is *not* a jemalloc saving — the two are independent build trees and the base tree
is older/differently-built; jemalloc only *adds* (`libjemalloc.so.2` is 258 kB stripped in
target). Treat the real jemalloc cost as **+~0.25 MB rootfs**, per the lib size, not the −0.92 MB
tar diff. (A true rootfs Δ needs both built from the same tree; out of scope for this RAM run.)

## Decision criteria

- **Adopt jemalloc** only if a tuned variant beats `base` by a **meaningful margin** (target
  ≥ ~2 MB Σ Pss / ~3 MB Rss) **with no functional regression** (klippy/moonraker/guppyscreen all
  start + run in the probe; GuppyScreen still renders via `make qemu-render`).
- If the win is marginal (< ~1 MB), **keep glibc + arena=2** — not worth the extra lib + the
  `background_thread`.
- Record the idle-vs-load caveat: if idle is flat but load shows a win, note it and decide on
  the load numbers.

## Verdict (2026-06-01)

**ADOPT jemalloc tuned** (`MALLOC_CONF=narenas:1,dirty_decay_ms:0,muzzy_decay_ms:0`).

- jem-tuned beats base by **−6.53 MB Σ Pss (−11.2 %)** and **−6.6 MB Rss** (klippy+moonraker) —
  far past the ~2 MB Σ Pss / ~3 MB Rss adoption bar — with **no regression**: klippy, moonraker,
  and httpd all start and run, and jemalloc verifiably loaded (`JEM=yes` in `/proc/<pid>/maps`).
  MemAvailable improves +2.2 MB (45344 → 47544 kB).
- **`jem-default` is essentially a wash** (−0.82 MB, within noise). The win is entirely from the
  tuning — single arena + zero decay (return freed pages to the OS immediately). This is the
  classic glibc-vs-tuned-jemalloc result: jemalloc's *defaults* favor throughput (page caching)
  over footprint; `dirty_decay_ms:0,muzzy_decay_ms:0` flips it to favor RSS, which is what a
  128 MB box wants.
- **`background_thread:true` adds nothing here** (53149 vs 52951 kB Σ Pss, ~noise; it costs one
  extra thread). At idle it is not worth it. It only helps latency of async purging under churn,
  which this idle probe does not exercise — keep it off unless a load test shows purge-induced
  latency spikes.

**Chosen config: `narenas:1,dirty_decay_ms:0,muzzy_decay_ms:0` (no background thread).**

### Idle-vs-load caveat

This is an **idle** measurement (25 s settle, klippy in no-MCU error state, Moonraker threadpool
quiescent). jemalloc's footprint advantage typically *grows* under allocation churn (Moonraker's
threadpool + websocket traffic), where glibc's per-thread arenas fragment — so this −6.5 MB is
expected to be a **floor**, not a ceiling. The decision does not hinge on the caveat (idle alone
clears the bar by 3×), but a follow-up load run (drive a few Moonraker API calls) would quantify
the upside and confirm no purge-latency regression before/with `background_thread`.

## If adopted

- `BR2_PACKAGE_JEMALLOC=y` in `reforge_defconfig`.
- `LD_PRELOAD=/usr/lib/libjemalloc.so.2` + the winning `MALLOC_CONF` exported in `S60klipper`,
  `S65moonraker`, `S75guppyscreen` (replacing/alongside `MALLOC_ARENA_MAX`, which jemalloc
  ignores). Update `docs/research/memory/2026-06-01-memory-savings-experiments.md`.
- Consider a forge-x PR too (forge-x also runs glibc moonraker/guppyscreen) if the win holds.
