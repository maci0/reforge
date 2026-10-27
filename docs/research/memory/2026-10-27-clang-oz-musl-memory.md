# Rootfs memory: gcc -Os vs gcc -Oz vs clang -Oz vs clang -Oz + musl

**Date:** 2026-10-27
**Status:** snapshot, measured under qemu `-M virt` only; nothing adopted.
**TL;DR:** `-Oz` alone saves nothing measurable (−165 kB). clang adds −0.5 MB total. Switching
glibc to musl is the only real lever: **−3.1 MB sum(Pss), −5.6%**, about 2.1 MB of it in klippy.
Getting clang to produce a working rootfs took four compatibility fixes, two of which failed only
at run time.

## Variants

All four from the same tree (Fortran already dropped, `125d529`), Buildroot 2026.08.1, gcc 15.3.0,
Thumb-2, LTO on. The -Oz variants build the toolchain first with baseline flags, then everything
else with the -Oz set (`lab/toolchain-memory/build-oz.sh`):

| variant | compiler for target packages | libc | compile / link flags |
|---|---|---|---|
| `gcc15-base` | gcc 15.3 | glibc 2.44 | `-Os` (reforge_defconfig) |
| `gcc-oz` | gcc 15.3 | glibc 2.44 | `-Oz -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables`, `-Wl,--gc-sections -Wl,-s` |
| `clang-oz` | clang 23.1.4 + lld | glibc 2.44 | same, plus `-moutline -fuse-ld=lld -Wl,--icf=all` |
| `clang-oz-musl` | clang 23.1.4 + lld | musl 1.2.6 | same as clang-oz |

GCC still builds glibc/musl, libgcc, libstdc++, the 5.4 kernel and the zram modules in every
variant. busybox ignores the -Oz flags (its binary is byte-identical in base and gcc-oz).
Verified with `lab/toolchain-memory/object-audit.sh` (compiler named in each object's
`.comment`) and `compiler-audit.sh` (per-package `-O` level from the build log).

## Results

`NOSWAP=1 tests/qemu-harness/mem-probe.sh` (`-m 128 -smp 2`, cortex-a7, 5.4 virt test kernel),
three runs per variant, interleaved, idle host. klippy, moonraker and httpd present in all 12 runs.

| variant | sum(Pss) kB (mean ± sd) | Δ vs base | klippy | moonraker | rootfs.tar |
|---|---|---|---|---|---|
| gcc15-base | 55,872 ± 119 | — | 20,793 | 34,898 | 170.1 MB |
| gcc-oz | 55,707 ± 121 | −165 (−0.3%) | 20,749 | 34,780 | 167.2 MB |
| clang-oz | 55,372 ± 69 | −500 (−0.9%) | 20,751 | 34,429 | 163.8 MB |
| **clang-oz-musl** | **52,731 ± 60** | **−3,141 (−5.6%)** | **18,644** | **33,953** | 161.7 MB |

- The lab notebook's 3σ noise floor is 100 kB (2026-06-04). gcc-oz sits just past it; clang-oz is
  a real but small win, mostly in moonraker.
- musl vs clang-oz on glibc: −2.6 MB, −2.1 MB of it in klippy. klippy uses the libc allocator
  (moonraker preloads jemalloc), so this is likely musl's malloc more than code size; not
  separated here.
- MemAvailable is bimodal in every variant (about 33.4k or 42.7k kB, independent of variant), so
  it is not used for the comparison. musl's three runs were 44.6k to 44.8k.

Static sizes (bytes):

| file | gcc15-base | gcc-oz | clang-oz | clang-oz-musl |
|---|---|---|---|---|
| libpython3.14.so.1.0 | 3,317,172 | 3,287,428 | 3,133,840 | 3,123,568 |
| libcrypto.so.3 | 2,786,668 | 2,762,092 | 2,630,556 | 2,632,108 |
| numpy `.so` total | 7,217,904 | 6,246,616 | 4,597,280 | 4,585,244 |
| libc | 937,996 | 937,996 | 937,996 | 521,808 |

## clang compatibility fixes (all in `lab/toolchain-memory/clang-cc.sh`)

1. `-ztext` (gcc driver spelling): rewritten to `-Wl,-z,text`. Broke iproute2.
2. `-r` links: `--icf=all` dropped; lld refuses the combination. Broke busybox.
3. lld ≥ 17 rejects version scripts naming undefined symbols; `-Wl,--undefined-version`. zlib's
   configure silently fell back to static-only, then python3 failed to link `-lz`.
4. `-mfp16-format=ieee` (gcc-only) dropped. numpy's meson probe failed on it and built only the
   `NEON` dispatch target; with the fix it builds `NEON NEON_FP16 NEON_VFPV4`, all the Cortex-A7
   can execute. gcc additionally builds ARMv8 `ASIMD*` targets that never run on this CPU.

Two failures showed only at run time; the boot and the probe looked healthy without klippy:

5. `__aeabi_d2h` (RTABI double→half) is called by clang but not provided by libgcc 15, so numpy
   failed to import and klippy exited. `aeabi-d2h.c` forwards to libgcc's `__gnu_d2h_ieee`;
   `aeabi-d2h-test.c` checks 10 IEEE cases under qemu-arm on every clang build.
   `undefined-audit.sh` finds no other unresolved symbol in either clang rootfs.
6. greenlet's arm32 `slp_switch()` relies on gcc's `optimize("no-omit-frame-pointer")`, which
   clang ignores; klippy's reactor segfaulted on its first greenlet switch. The wrapper adds
   `-fno-omit-frame-pointer` for greenlet sources. No other gcc `optimize` attribute or pragma in
   the clang-built packages affects correctness (python3 `ceval.c` and numpy use them for speed,
   iwd's applies only to gcc < 9).

## Not checked

- Real hardware. All numbers are qemu virt with the 5.4 test kernel.
- Performance: numpy, Klipper step compression and moonraker under clang or musl.
- Stock firmwareExe (glibc binary) cannot run on the musl rootfs.
- Whether musl's 2.1 MB klippy saving survives with jemalloc preloaded into klippy (S60klipper
  avoids jemalloc on hardware).
