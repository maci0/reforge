# Toolchain memory experiments

Buildroot config fragments from the 2026-06-04 compiler and memory measurements.
Each fragment is combined with the current ReForge defconfig by the variant builder:

```sh
tools/build/build-variant.sh gcc15-base lab/toolchain-memory/gcc15-base.fragment
tools/build/build-variant.sh gcc15-funcsec lab/toolchain-memory/gcc15-funcsec.fragment
```

Build output and logs go under `build/`. Generated variant defconfigs under
`br-external/configs/` are ignored by Git.

Results and measurement conditions are recorded in
[optimizations.md](../../docs/optimizations.md) and the
[memory comparison](../../docs/research/memory/2026-06-05-reforge-vs-forgex-memory.md).

## -Oz, clang and musl (2026-10-27)

```sh
tools/build/build-variant.sh gcc15-base lab/toolchain-memory/gcc15-base.fragment
lab/toolchain-memory/build-oz.sh gcc           # build/output-gcc-oz
lab/toolchain-memory/build-oz.sh clang         # build/output-clang-oz
lab/toolchain-memory/build-oz.sh clang musl    # build/output-clang-oz-musl
lab/toolchain-memory/build-oz.sh gcc musl      # build/output-gcc-oz-musl
NOSWAP=1 tests/qemu-harness/mem-probe.sh build/output-<variant>/images/rootfs.tar.xz
```

`build-oz.sh` builds the toolchain with reforge_defconfig flags, then every other package with
the -Oz set (`oz.fragment` plus a `TARGET_OPTIMIZATION` override) and, for clang, `clang-cc.sh`
as `TARGET_CC`/`TARGET_CXX` (host clang + lld against the Buildroot sysroot; it carries the gcc
compatibility fixes and links `aeabi-d2h.c`). `musl.fragment` switches the toolchain libc.
Checks: `compiler-audit.sh <log>` (per-package compiler and `-O` level), `object-audit.sh
<output dir>` (compiler per object), `undefined-audit.sh <target dir>` (unresolved dynamic
symbols). Results: [clang-oz-musl memory](../../docs/research/memory/2026-10-27-clang-oz-musl-memory.md).
