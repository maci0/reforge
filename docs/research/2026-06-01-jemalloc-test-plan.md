# jemalloc evaluation — test plan

**Question:** does jemalloc (tuned for low RSS) beat the shipped **glibc + `MALLOC_ARENA_MAX=2`**
on the 128 MB T113, for the long-running allocators — Moonraker (threadpool), klippy, and
GuppyScreen? Adopt only if it's a clear, no-regression win.

**Status:** not yet run. This plan is executable once the prerequisite build exists.

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

## Results (fill in)

| variant | klippy Rss | moonraker Rss | guppyscreen Rss | Σ Pss | MemAvailable | rootfs Δ |
|---|---|---|---|---|---|---|
| base (glibc, arena=2) | | | | | | — |
| jem-default | | | | | | |
| jem-tuned | | | | | | |
| jem-bgthread | | | | | | |

## Decision criteria

- **Adopt jemalloc** only if a tuned variant beats `base` by a **meaningful margin** (target
  ≥ ~2 MB Σ Pss / ~3 MB Rss) **with no functional regression** (klippy/moonraker/guppyscreen all
  start + run in the probe; GuppyScreen still renders via `make qemu-render`).
- If the win is marginal (< ~1 MB), **keep glibc + arena=2** — not worth the extra lib + the
  `background_thread`.
- Record the idle-vs-load caveat: if idle is flat but load shows a win, note it and decide on
  the load numbers.

## If adopted

- `BR2_PACKAGE_JEMALLOC=y` in `reforge_defconfig`.
- `LD_PRELOAD=/usr/lib/libjemalloc.so.2` + the winning `MALLOC_CONF` exported in `S60klipper`,
  `S65moonraker`, `S75guppyscreen` (replacing/alongside `MALLOC_ARENA_MAX`, which jemalloc
  ignores). Update `docs/research/2026-06-01-memory-savings-experiments.md`.
- Consider a forge-x PR too (forge-x also runs glibc moonraker/guppyscreen) if the win holds.
