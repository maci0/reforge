#!/bin/sh
# Usage: ./dump_golden.sh root@<printer-ip>
set -eu
HOST="${1:?usage: dump_golden.sh root@host}"
TS=$(date +%Y%m%d-%H%M%S)
OUT="$(dirname "$0")/golden-$(echo "$HOST" | sed 's/.*@//')-${TS}.img.gz"
echo "device eMMC size:"
# /sys/block/mmcblk0/size is in 512-byte sectors -> x512 for bytes.
# (Do NOT change to x1024; that is /proc/partitions' 1K-block unit, a different source.)
ssh "$HOST" 'cat /sys/block/mmcblk0/size | awk "{print \$1*512}"' | tee "${OUT%.img.gz}.size"
echo "dumping full mmcblk0 -> $OUT (raw over ssh, gzip local)"
ssh "$HOST" 'dd if=/dev/mmcblk0 bs=4M 2>/dev/null' | gzip > "$OUT"
sha256sum "$OUT" | tee "${OUT}.sha256"
echo "done: $OUT"
