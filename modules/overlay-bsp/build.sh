#!/bin/bash
# Build overlay.ko for the stock 5.4.61 BSP kernel, so we can `insmod
# overlay.ko` on the running stock firmware and prototype the atomic /
# immutable-ReForge design from docs/research/kernel/2026-06-05-overlayfs-on-bsp-spike.md
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
# Cleanup ALSO reverts our patches so the next consumer of the BSP tree sees
# pristine sources — we apply patches via `patch -p1 <` and revert with
# `git checkout` so a `git clean -dfxq` doesn't leave a half-patched .c.
cleanup() {
    git -C "$KSRC" checkout -- fs/overlayfs/ >/dev/null 2>&1 || true
    git -C "$KSRC" clean -dfxq >/dev/null 2>&1 || make -C "$KSRC" mrproper >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Apply the VFS-namespace-import patch needed for the stock kernel to resolve
# the .ko's vfs_link / vfs_create / vfs_rename / vfs_getattr / vfs_setxattr /
# vfs_listxattr / dentry_open references at insmod time. The stock kernel has
# v5.6-era namespaced VFS exports backported (__kstrtabns_vfs_link etc are in
# /proc/kallsyms) but the BSP fs/overlayfs/ source pre-dates the matching
# MODULE_IMPORT_NS(...) declaration in fs/overlayfs/super.c (upstream commit
# f3e57aac4262, v5.7-rc1). Add it so the module declares the import.
PATCH="$HERE/patches/0001-overlay-import-vfs-ns.patch"
if ! patch -p1 --dry-run < "$PATCH" >/dev/null 2>&1; then
    # Idempotency: if the patch is already applied (e.g. retry build), skip.
    if grep -q 'MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem' fs/overlayfs/super.c; then
        echo "[overlay-bsp] patch already applied"
    else
        echo "[overlay-bsp] FAIL: cannot apply $PATCH" >&2
        exit 1
    fi
else
    patch -p1 < "$PATCH"
fi

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
