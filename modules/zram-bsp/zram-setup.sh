#!/bin/sh
# Bring up zstd-compressed zram swap on the STOCK 5.4.61 kernel as the PRIMARY swap.
# Works on forge-x and ReForge P1-P3 (both ride the stock kernel).
# Modules must match vermagic: 5.4.61 SMP preempt mod_unload ARMv7 p2v8
set -e
DIR=$(dirname "$0")/dist
SIZE=${ZRAM_SIZE:-256M}
ALGO=${ZRAM_ALGO:-zstd}          # zstd (best ratio ~4x) | lzo-rle (cheaper CPU ~2.7x)
PRIO=${ZRAM_PRIO:-100}
/sbin/insmod "$DIR/zsmalloc.ko" 2>/dev/null || true   # idempotent
/sbin/insmod "$DIR/zram.ko"     2>/dev/null || true
/sbin/swapoff /dev/zram0 2>/dev/null || true
echo 1 > /sys/block/zram0/reset 2>/dev/null || true
echo "$ALGO" > /sys/block/zram0/comp_algorithm
echo "$SIZE" > /sys/block/zram0/disksize
/sbin/mkswap /dev/zram0 >/dev/null
# CRITICAL: swap on at HIGH priority so zram is preferred over any eMMC swapfile.
# busybox swapon has no -p, so use the static helper (SWAP_FLAG_PREFER|prio).
"$DIR/swapon_prio" /dev/zram0 "$PRIO"
# zram is fast RAM-backed swap, so tune the VM to use it. These mirror the shipped
# ReForge profile (.shell/reforge-vmtune.sh); per-knob rationale is in
# docs/research/2026-06-02-stock-kernel-runtime-tuning.md. No fixed RAM cost.
echo "${ZRAM_SWAPPINESS:-100}" > /proc/sys/vm/swappiness            2>/dev/null || true
echo 0                        > /proc/sys/vm/page-cluster           2>/dev/null || true
echo 50                       > /proc/sys/vm/vfs_cache_pressure     2>/dev/null || true
echo 40                       > /proc/sys/vm/watermark_scale_factor 2>/dev/null || true
echo 10                       > /proc/sys/vm/dirty_ratio            2>/dev/null || true
echo 5                        > /proc/sys/vm/dirty_background_ratio 2>/dev/null || true
echo "zram active (algo=$ALGO, prio=$PRIO, swappiness=${ZRAM_SWAPPINESS:-100}, page-cluster=0, +VM tuning); eMMC swapfile (if any) stays low-prio overflow:"
cat /proc/swaps
