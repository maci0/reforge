#!/usr/bin/env bash
# Size-optimized A/B build: reforge_defconfig + Thumb-2 + -Os + locale purge,
# into build/output-mem (does NOT touch the product build/output). Experiment only.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
O="$REPO/build/output-mem"
make -C "$REPO/vendor/buildroot" BR2_EXTERNAL="$REPO/br-external" O="$O" reforge_defconfig
cat >> "$O/.config" <<CFG
# BR2_OPTIMIZE_2 is not set
BR2_OPTIMIZE_S=y
BR2_ARM_INSTRUCTIONS_THUMB2=y
BR2_ENABLE_LOCALE_PURGE=y
BR2_GENERATE_LOCALE="C"
CFG
make -C "$REPO/vendor/buildroot" BR2_EXTERNAL="$REPO/br-external" O="$O" olddefconfig
grep -E 'BR2_OPTIMIZE_S|THUMB2|LOCALE_PURGE' "$O/.config"
make -C "$REPO/vendor/buildroot" BR2_EXTERNAL="$REPO/br-external" O="$O" -j"$(nproc)"
echo "VARIANT BUILD DONE -> $O/images/rootfs.tar.xz"
