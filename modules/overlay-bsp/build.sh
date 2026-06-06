#!/bin/bash
# Build overlay.ko for the stock 5.4.61 BSP kernel, so we can `insmod
# overlay.ko` on the running stock firmware and prototype the atomic /
# immutable-ReForge design from docs/research/2026-06-05-overlayfs-on-bsp-spike.md
# without first reflashing the kernel.
#
# The stock kernel (verified on hardware via /proc/config.gz + the cached copy
# at docs/board-notes/stock-kernel-config-5.4.61.txt.gz) has
#   # CONFIG_OVERLAY_FS is not set
# so the running kernel cannot mount overlay today. fs/overlayfs/Kconfig is
# tristate and the BSP source is vanilla (no Allwinner patches — confirmed in
# the spike doc), so building =m against the EXACT stock config produces a
# loadable module with vermagic '5.4.61 SMP preempt mod_unload ARMv7 p2v8'.
#
# Same recipe as modules/{f2fs,zram}-bsp/build.sh.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
KSRC=${KSRC:-$REPO_ROOT/vendor/kernels/tina-bsp-kernel}
CROSS=$REPO_ROOT/vendor/toolchains/gcc-9.5.0-nolibc/arm-linux-gnueabi/bin/arm-linux-gnueabi-
STOCKCFG=$HERE/../../docs/board-notes/stock-kernel-config-5.4.61.txt.gz
WANT_VM='5.4.61 SMP preempt mod_unload ARMv7 p2v8'

cd "$KSRC"
# IN-TREE build; restore-to-pristine on exit so the shared BSP source doesn't
# wedge other consumers (the qemu test kernel uses OUT-OF-TREE build via O=).
cleanup() { git -C "$KSRC" clean -dfxq >/dev/null 2>&1 || make -C "$KSRC" mrproper >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Empty .scmversion so scripts/setlocalversion doesn't append a '+' for an
# untagged tree — vermagic must be exactly '5.4.61', not '5.4.61+'.
printf '' > .scmversion
zcat "$STOCKCFG" > .config

# Enable overlay as a module. We keep the default sub-options (NO REDIRECT_DIR,
# INDEX=y, XINO_AUTO=y, NO NFS_EXPORT, NO METACOPY) which match what the spike
# proved works correctly under qemu.
sed -i '/CONFIG_OVERLAY_FS\b/d;/CONFIG_OVERLAY_FS_REDIRECT_DIR\b/d;/CONFIG_OVERLAY_FS_INDEX\b/d;/CONFIG_OVERLAY_FS_XINO_AUTO\b/d;/CONFIG_OVERLAY_FS_NFS_EXPORT\b/d;/CONFIG_OVERLAY_FS_METACOPY\b/d' .config
{
  echo "CONFIG_OVERLAY_FS=m"
  echo "# CONFIG_OVERLAY_FS_REDIRECT_DIR is not set"
  echo "CONFIG_OVERLAY_FS_INDEX=y"
  echo "CONFIG_OVERLAY_FS_XINO_AUTO=y"
  echo "# CONFIG_OVERLAY_FS_NFS_EXPORT is not set"
  echo "# CONFIG_OVERLAY_FS_METACOPY is not set"
} >> .config

make ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig
make ARCH=arm CROSS_COMPILE="$CROSS" -j"$(nproc)" modules_prepare
make ARCH=arm CROSS_COMPILE="$CROSS" -j"$(nproc)" fs/overlayfs/overlay.ko

mkdir -p "$HERE/build"
cp fs/overlayfs/overlay.ko "$HERE/build/"

echo "built -> $HERE/build/overlay.ko"
rc=0
ko="overlay.ko"
vm="$(strings "$HERE/build/$ko" | grep -m1 '^vermagic=' | sed 's/^vermagic=//;s/ *$//')"
dep="$(strings "$HERE/build/$ko" | grep -m1 '^depends=')"
printf '  %-12s vermagic=%q  %s\n' "$ko" "$vm" "$dep"
[ "$vm" = "$WANT_VM" ] || { echo "    !! vermagic mismatch (want '$WANT_VM')"; rc=1; }
exit "$rc"
