#!/bin/bash
# Build zram/zsmalloc/zpool/zbud as loadable modules for the stock 5.4.61 BSP kernel.
# UPSTREAM source FAILED (ABI mismatch, see README RESULT) — adapt KSRC to the Tina
# sun8iw20 BSP source for the layout-exact build.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
# Vendored third-party trees live under vendor/ (see docs/REPO-LAYOUT.md).
# Default = the Tina sun8iw20 BSP submodule (layout-exact; upstream linux-5.4.61
# Oopsed — see README). Override KSRC only to diff against a fetched mainline tree.
KSRC=${KSRC:-$REPO_ROOT/vendor/kernels/tina-bsp-kernel}
CROSS=$REPO_ROOT/vendor/toolchains/gcc-9.5.0-nolibc/arm-linux-gnueabi/bin/arm-linux-gnueabi-
STOCKCFG=$HERE/../../docs/board-notes/stock-kernel-config-5.4.61.txt.gz
cd "$KSRC"
zcat "$STOCKCFG" > .config
for s in ZSMALLOC ZRAM ZPOOL ZBUD; do sed -i "/CONFIG_$s\b/d" .config; echo "CONFIG_$s=m" >> .config; done
make ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig
make ARCH=arm CROSS_COMPILE="$CROSS" -j"$(nproc)" modules_prepare
make ARCH=arm CROSS_COMPILE="$CROSS" -j"$(nproc)" mm/zsmalloc.ko mm/zpool.ko mm/zbud.ko drivers/block/zram/zram.ko
mkdir -p "$HERE/build"; cp mm/zsmalloc.ko mm/zpool.ko mm/zbud.ko drivers/block/zram/zram.ko "$HERE/build/"
echo "built modules -> $HERE/build/ ; verify vermagic == '5.4.61 SMP preempt mod_unload ARMv7 p2v8'"
