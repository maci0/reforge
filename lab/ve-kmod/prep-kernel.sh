#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
KSRC=$REPO/vendor/kernels/tina-bsp-kernel
CROSS=$REPO/vendor/toolchains/gcc-9.5.0-nolibc/arm-linux-gnueabi/bin/arm-linux-gnueabi-
STOCKCFG=$REPO/docs/board-notes/stock-kernel-config-5.4.61.txt.gz
cd "$KSRC"
zcat "$STOCKCFG" > .config
make ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig >/dev/null
make ARCH=arm CROSS_COMPILE="$CROSS" -j"$(nproc)" modules_prepare
echo "PREP DONE"
