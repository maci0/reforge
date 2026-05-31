#!/bin/sh
# Load vendor-BSP-built zram+zsmalloc and bring up a zstd-compressed swap on the
# STOCK 5.4.61 kernel. Works on forge-x and ReForge P1-P3 (both ride the stock kernel).
# Modules must match vermagic: 5.4.61 SMP preempt mod_unload ARMv7 p2v8
set -e
DIR=$(dirname "$0")/dist
SIZE=${ZRAM_SIZE:-256M}
ALGO=${ZRAM_ALGO:-zstd}
/sbin/insmod "$DIR/zsmalloc.ko" 2>/dev/null || true   # idempotent
/sbin/insmod "$DIR/zram.ko"     2>/dev/null || true
echo "$ALGO" > /sys/block/zram0/comp_algorithm
echo "$SIZE" > /sys/block/zram0/disksize
/sbin/mkswap /dev/zram0 >/dev/null
/sbin/swapon /dev/zram0
# make zram the preferred swap over any eMMC swapfile: re-add the file at lower prio
EMMC=$(grep -E '/swap( |$)' /proc/swaps | awk '{print $1}' | grep -v zram | head -1)
if [ -n "$EMMC" ]; then /sbin/swapoff "$EMMC" 2>/dev/null; /sbin/swapon "$EMMC" 2>/dev/null || true; fi
echo "zram active:"; cat /proc/swaps
