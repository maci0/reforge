#!/bin/bash
# Build the LIVE-mode kernel modules for the stock 5.4.61 BSP kernel, so ReForge
# live mode can insmod them from the USB on a device whose stock kernel lacks
# them. The stock kernel (verified on hardware) has NO loop driver, NO plain
# 'crc32' crypto (only crc32c), and NO F2FS. Live mode needs all three:
#   loop.ko          — to loop-mount the rootfs image file off the FAT stick
#   crc32_generic.ko — registers the 'crc32' algo F2FS needs at mount time
#   f2fs.ko          — the flash-friendly rootfs filesystem
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
WANT_VM='5.4.61 SMP preempt mod_unload ARMv7 p2v8'

cd "$KSRC"
# IN-TREE build; its leftovers (.config, generated headers, .o, .scmversion) make
# the shared BSP source "not clean", which breaks the qemu test kernel's
# OUT-OF-TREE build (outputmakefile Error 1). Restore the tree to pristine on exit.
cleanup() { git -C "$KSRC" clean -dfxq >/dev/null 2>&1 || make -C "$KSRC" mrproper >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Empty .scmversion suppresses scripts/setlocalversion's "+" suffix (it appends
# one for an untagged/dirty git tree), so vermagic is exactly 5.4.61 — matching
# the device, not 5.4.61+ (which would fail insmod).
printf '' > .scmversion
zcat "$STOCKCFG" > .config
# Enable the three modules. crc32 = CRYPTO_CRC32 (the 'crc32' shash F2FS mounts
# against — the stock kernel only has crc32c); loop = BLK_DEV_LOOP.
sed -i '/CONFIG_F2FS_FS\b/d;/CONFIG_F2FS_FS_XATTR\b/d;/CONFIG_F2FS_FS_POSIX_ACL\b/d;/CONFIG_CRYPTO_CRC32\b/d;/CONFIG_BLK_DEV_LOOP\b/d' .config
{
  echo "CONFIG_F2FS_FS=m"
  echo "CONFIG_F2FS_FS_XATTR=y"
  echo "CONFIG_F2FS_FS_POSIX_ACL=y"
  echo "CONFIG_CRYPTO_CRC32=m"
  echo "CONFIG_BLK_DEV_LOOP=m"
} >> .config
# loop.c uses vfs_getattr, which the kernel exports in the namespace
# VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver. As a module loop must
# MODULE_IMPORT_NS it, but the BSP loop.c doesn't (loop was never a module here).
# Add the import (same as other BSP modules do, e.g. focaltech/bcmdhd). The
# git-clean on exit reverts this, so the vendored source stays pristine.
if ! grep -q 'MODULE_IMPORT_NS(VFS_internal' drivers/block/loop.c; then
    sed -i '/^MODULE_LICENSE("GPL");/a MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);' drivers/block/loop.c
fi

make ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig
make ARCH=arm CROSS_COMPILE="$CROSS" -j"$(nproc)" modules_prepare
make ARCH=arm CROSS_COMPILE="$CROSS" -j"$(nproc)" \
    fs/f2fs/f2fs.ko crypto/crc32_generic.ko drivers/block/loop.ko

mkdir -p "$HERE/build"
cp fs/f2fs/f2fs.ko crypto/crc32_generic.ko drivers/block/loop.ko "$HERE/build/"

echo "built -> $HERE/build/{f2fs.ko,crc32_generic.ko,loop.ko}"
rc=0
for ko in f2fs.ko crc32_generic.ko loop.ko; do
    vm="$(strings "$HERE/build/$ko" | grep -m1 '^vermagic=' | sed 's/^vermagic=//;s/ *$//')"
    dep="$(strings "$HERE/build/$ko" | grep -m1 '^depends=')"
    printf '  %-18s vermagic=%q  %s\n' "$ko" "$vm" "$dep"
    [ "$vm" = "$WANT_VM" ] || { echo "    !! vermagic mismatch (want '$WANT_VM')"; rc=1; }
done
exit "$rc"
