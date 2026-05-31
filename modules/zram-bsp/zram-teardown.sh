#!/bin/sh
# Revert: remove zram swap + modules (stock eMMC swapfile remains).
/sbin/swapoff /dev/zram0 2>/dev/null || true
/sbin/rmmod zram 2>/dev/null || true
/sbin/rmmod zsmalloc 2>/dev/null || true
echo "zram removed:"; cat /proc/swaps
