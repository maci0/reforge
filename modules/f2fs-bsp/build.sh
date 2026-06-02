#!/bin/bash
# Build f2fs.ko (+ any needed deps) as a loadable module for the stock 5.4.61 BSP
# kernel, so ReForge LIVE mode can `insmod f2fs.ko` from the USB and mount an F2FS
# rootfs on a device whose stock kernel has no built-in F2FS (only ext4 + vfat).
#
# Same recipe as modules/zram-bsp/build.sh: the Tina sun8iw20 BSP source built
# with the EXACT stock kernel config, so vermagic matches the running kernel
# ('5.4.61 SMP preempt mod_unload ARMv7 p2v8'). Verify before shipping.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
KSRC=${KSRC:-$REPO_ROOT/vendor/kernels/tina-bsp-kernel}
CROSS=$REPO_ROOT/vendor/toolchains/gcc-9.5.0-nolibc/arm-linux-gnueabi/bin/arm-linux-gnueabi-
STOCKCFG=$HERE/../../docs/board-notes/stock-kernel-config-5.4.61.txt.gz

cd "$KSRC"
# This is an IN-TREE build; its leftovers (.config, generated headers, .o,
# .scmversion) make the shared BSP source "not clean", which breaks the qemu
# test kernel's OUT-OF-TREE build (outputmakefile Error 1). Restore the tree to
# pristine on exit so the two builds don't collide.
cleanup() { git -C "$KSRC" clean -dfxq >/dev/null 2>&1 || make -C "$KSRC" mrproper >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Empty .scmversion suppresses scripts/setlocalversion's "+" suffix (it appends
# one for an untagged/dirty git tree), so vermagic is exactly 5.4.61 — matching
# the device, not 5.4.61+ (which would fail insmod).
printf '' > .scmversion
zcat "$STOCKCFG" > .config
# F2FS as a module (+ common sub-options). crc32 is built into the stock kernel.
sed -i '/CONFIG_F2FS_FS\b/d;/CONFIG_F2FS_FS_XATTR\b/d;/CONFIG_F2FS_FS_POSIX_ACL\b/d' .config
{
  echo "CONFIG_F2FS_FS=m"
  echo "CONFIG_F2FS_FS_XATTR=y"
  echo "CONFIG_F2FS_FS_POSIX_ACL=y"
} >> .config
make ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig
make ARCH=arm CROSS_COMPILE="$CROSS" -j"$(nproc)" modules_prepare
make ARCH=arm CROSS_COMPILE="$CROSS" -j"$(nproc)" fs/f2fs/f2fs.ko

mkdir -p "$HERE/build"
cp fs/f2fs/f2fs.ko "$HERE/build/"
echo "built -> $HERE/build/f2fs.ko"
echo "vermagic: $("${CROSS}objdump" -d -j .modinfo "$HERE/build/f2fs.ko" 2>/dev/null >/dev/null; \
    strings "$HERE/build/f2fs.ko" | grep -E '^vermagic=' || echo '?')"
echo "  must equal the device's: '5.4.61 SMP preempt mod_unload ARMv7 p2v8'"
