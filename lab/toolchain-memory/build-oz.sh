#!/usr/bin/env bash
# Two-phase variant build: toolchain with reforge_defconfig flags, then every
# other package with oz.fragment applied, compiled by gcc or clang.
#
# Usage: lab/toolchain-memory/build-oz.sh gcc|clang [glibc|musl]
# Output: build/output-<cc>-oz[-musl]/images/rootfs.tar.xz, log alongside as .log
set -euo pipefail
source "$(cd "$(dirname "$0")" && until [ -e pins.lock ]; do cd ..; done; pwd)/tools/build/env.sh"

cc=${1:?usage: build-oz.sh gcc|clang [glibc|musl]}
libc=${2:-glibc}
lab=$REFORGE_ROOT/lab/toolchain-memory
case "$libc" in
    glibc) out=$REFORGE_ROOT/build/output-$cc-oz; triple=arm-buildroot-linux-gnueabihf ;;
    musl) out=$REFORGE_ROOT/build/output-$cc-oz-musl; triple=arm-buildroot-linux-musleabihf ;;
    *) echo "unknown libc: $libc" >&2; exit 1 ;;
esac
log=$out.log
br() { make -C "$BUILDROOT_GIT" BR2_EXTERNAL="$BR2_EXTERNAL_DIR" O="$out" "$@"; }
# Replaces Buildroot's -Os in TARGET_CFLAGS (see oz.fragment for why not
# BR2_TARGET_OPTIMIZATION).
oz_cflags="-Oz -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables"

case "$cc" in
    gcc) cc_args=() ;;
    clang)
        export REFORGE_BR_HOST=$out/host REFORGE_BR_TRIPLE=$triple
        # Under host/bin: the CMake toolchain file stores compilers relative to host/.
        bin=$out/host/bin
        cc_args=(TARGET_CC="$bin/clang-cc" TARGET_CXX="$bin/clang-c++"
                 TARGET_AR=llvm-ar TARGET_NM=llvm-nm TARGET_RANLIB=llvm-ranlib) ;;
    *) echo "unknown compiler: $cc" >&2; exit 1 ;;
esac

{
    echo "[build-oz] $cc $libc start $(date -Is)"
    br reforge_defconfig
    if [ "$libc" = musl ]; then
        cat "$lab/musl.fragment" >> "$out/.config"
        br olddefconfig
    fi
    grep -E '^BR2_TOOLCHAIN_BUILDROOT_(GLIBC|MUSL)=' "$out/.config"
    br $MULTICORE toolchain
    cat "$lab/oz.fragment" >> "$out/.config"
    br olddefconfig
    grep -E '^BR2_TARGET_LDFLAGS=' "$out/.config"
    if [ "$cc" = clang ]; then
        mkdir -p "$bin"
        ln -sf "$lab/clang-cc.sh" "$bin/clang-cc"
        ln -sf "$lab/clang-cc.sh" "$bin/clang-c++"
        rm -f "$out/host/lib/libreforge-aeabi.a"
        "$bin/clang-cc" -Oz -c "$lab/aeabi-d2h.c" -o "$out/build/aeabi-d2h.o"
        llvm-ar rcs "$out/host/lib/libreforge-aeabi.a" "$out/build/aeabi-d2h.o"
        "$bin/clang-cc" -Oz "$lab/aeabi-d2h-test.c" -o "$out/build/aeabi-d2h-test"
        qemu-arm -L "$out/host/$triple/sysroot" "$out/build/aeabi-d2h-test"
    fi
    # Regenerate the CMake toolchain file (written by the toolchain package from
    # TARGET_CC and TARGET_CFLAGS) so CMake packages get the same compiler and flags.
    br toolchain-reinstall TARGET_OPTIMIZATION="$oz_cflags" "${cc_args[@]}"
    br $MULTICORE TARGET_OPTIMIZATION="$oz_cflags" "${cc_args[@]}"
    echo "[build-oz] $cc $libc finished $(date -Is)"
} 2>&1 | tee "$log"
