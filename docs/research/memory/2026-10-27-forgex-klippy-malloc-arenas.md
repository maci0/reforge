# forge-x 1.4.2-beta-4: capping klippy's glibc malloc arenas

**Date:** 2026-10-27
**Status:** snapshot, qemu `-M virt` only; nothing proposed upstream.
**TL;DR:** `MALLOC_ARENA_MAX=2` for klippy (what forge-x already sets for Moonraker and
GuppyScreen) saves nothing measurable; `=1` saves 287 kB (−1.3%) of klippy Pss. klippy runs four
threads, so glibc never creates many arenas.

## Why

On ReForge, musl cut klippy by about 2.1 MB
([clang-oz-musl memory](2026-10-27-clang-oz-musl-memory.md)). forge-x cannot move klippy off the
stock glibc 2.25 / Python 3.7.11 (it runs on the stock rootfs), but it could cap glibc's
arenas for klippy as it does for Moonraker (`.root/S65moonraker:42`) and GuppyScreen
(`.root/S80guppyscreen:16`).

## Method

`tests/qemu-harness/mem-probe-forgex.sh` on the local forge-x image fixture, whose
`/opt/config/mod` tree is byte-identical to tag `1.4.2-beta-4` (diffed against `git archive`;
only an extra `.git`). Run with forge-x defaults for the screen and swap off:

```sh
FX_SET="display='FEATHER' use_swap='OFF'" [KLIPPY_ARENA=N] \
    tests/qemu-harness/mem-probe-forgex.sh <label>
```

In Feather mode forge-x's `boot.sh` starts klippy (`zstart_klipper.sh` → `/opt/klipper/start.sh`)
with the Feather plugins loaded and `typer` rendering. `KLIPPY_ARENA` adds `export
MALLOC_ARENA_MAX=N` to `/opt/klipper/start.sh`; the snapshot printed klippy's `MALLOC_*`
environment in every run, so each setting is confirmed to have applied. Three runs per setting,
interleaved, `-m 128 -smp 2`.

## Results

| klippy setting | klippy Pss kB (mean ± sd) | Δ |
|---|---|---|
| unset (beta-4 as shipped) | 22,816 ± 62 | — |
| `MALLOC_ARENA_MAX=2` | 22,777 ± 105 | −39 (noise) |
| `MALLOC_ARENA_MAX=1` | 22,529 ± 67 | −287 (−1.3%) |

klippy had 4 threads (`/proc/<pid>/task`). Moonraker (31.4 to 35.3 MB) and `typer` (4.8 to
5.0 MB) are unchanged by the klippy setting; Moonraker's spread is run-to-run.

## Not checked

- Whether one arena slows klippy's MCU communication under print load (thread contention on the
  allocator lock).
- Real hardware.
