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
# zram is fast RAM-backed swap, so tune the VM to use it:
#   swappiness=100  — push cold anon pages to (compressed) zram readily, freeing
#                     RAM. 100 is the max on the 5.4 kernel (>100 needs 5.8+).
#   page-cluster=0  — disable swap read-ahead. zram is fast random-access, so
#                     reading one page at a time avoids decompressing unneeded pages.
echo "${ZRAM_SWAPPINESS:-100}" > /proc/sys/vm/swappiness  2>/dev/null || true
echo 0                        > /proc/sys/vm/page-cluster 2>/dev/null || true
echo "zram active (algo=$ALGO, prio=$PRIO, swappiness=${ZRAM_SWAPPINESS:-100}, page-cluster=0); eMMC swapfile (if any) stays low-prio overflow:"
cat /proc/swaps
