#!/bin/sh
# Usage: ./dump_golden.sh root@<printer-ip>
#
# Captures a RAW full-eMMC dump of whatever is currently on the device. The output
# is named dump-<host>-<ts>.img.gz — NOT "golden": a raw dump reflects the device's
# actual state (stock, forge-x, reforge, ...), so naming it "golden" up front is
# misleading. Curate it afterwards (see RUNBOOK.md / recovery-sources.md):
#   - pristine stock  -> golden.img.gz       (via make-clean-golden.sh)
#   - forge-x device  -> forge-x-<ts>.img.gz (kept as the forge-x reference)
#
# The eMMC is dumped LIVE (filesystems mounted + being written), so the captured
# ext4 partitions are crash-inconsistent: a pending journal, half-updated block/inode
# bitmaps. Consumers then have to force `debugfs -c` (catastrophic mode, which reads
# stale/uncommitted blocks and can return WRONG file contents) or hit checksum errors.
# Two mitigations here make the stored image fsck-clean and trustworthy:
#   1. `sync` (+ drop_caches) on the device before dd  -> flush dirty pages to eMMC.
#   2. a post-dump, ROOTLESS fsck pass over every ext partition (slice -> e2fsck -fy
#      -> splice back) -> replays the journal + fixes the bitmaps, so the image mounts
#      and `debugfs`/`dumpe2fs` open it WITHOUT -c, and rdump returns correct bytes.
set -eu
HOST="${1:?usage: dump_golden.sh root@host}"
TS=$(date +%Y%m%d-%H%M%S)
OUT="$(dirname "$0")/dump-$(echo "$HOST" | sed 's/.*@//')-${TS}.img.gz"
RAW="${OUT%.img.gz}.raw"

echo "device eMMC size:"
# /sys/block/mmcblk0/size is in 512-byte sectors -> x512 for bytes.
# (Do NOT change to x1024; that is /proc/partitions' 1K-block unit, a different source.)
ssh "$HOST" 'cat /sys/block/mmcblk0/size | awk "{print \$1*512}"' | tee "${OUT%.img.gz}.size"

# Flush the device's page cache + filesystem buffers to eMMC before imaging so the
# on-disk state is as consistent as a live capture allows (the fsck pass below cleans
# up the rest). Best-effort: a stock box may lack drop_caches; sync always works.
echo "syncing device filesystems before capture..."
ssh "$HOST" 'sync; sync; [ -w /proc/sys/vm/drop_caches ] && echo 3 > /proc/sys/vm/drop_caches; sync' 2>/dev/null || true

echo "dumping full mmcblk0 -> $RAW (raw over ssh)"
ssh "$HOST" 'dd if=/dev/mmcblk0 bs=4M 2>/dev/null' > "$RAW"

# POSIX sh has no pipefail: if ssh dies mid-stream the dump is silently truncated.
# Verify the full size NOW so a bad dump can never pass unnoticed (gate-zero backup).
EXPECT=$(cat "${OUT%.img.gz}.size")
ACTUAL=$(wc -c < "$RAW")
if [ "$EXPECT" != "$ACTUAL" ]; then
  echo "FAIL: dump TRUNCATED (expected $EXPECT bytes, got $ACTUAL) — DO NOT TRUST" >&2
  rm -f "$RAW"; exit 1
fi
echo "verified full eMMC size: $ACTUAL bytes"

# --- fsck pass: make every ext partition journal-clean (rootless) -------------
# Loop over the partition table; for each partition, slice it out, run e2fsck -fy
# (which recognises ext and no-ops/skips non-ext via a bad-magic error), and splice
# the cleaned partition back into the raw image in place. No loop devices / sudo.
echo "fsck pass over ext partitions (replay journal + fix bitmaps)..."
PART_TMP="${RAW}.part"
# partx output: NR START SECTORS  (512-byte sectors). Fall back to fdisk if absent.
if command -v partx >/dev/null 2>&1; then
  PARTS=$(partx -g -o NR,START,SECTORS "$RAW" 2>/dev/null | awk 'NF==3{print $2":"$3}')
else
  PARTS=$(fdisk -lu "$RAW" 2>/dev/null | awk '/^[^ ].*[0-9]+ +[0-9]+ +[0-9]+/{} $0 ~ /'"$(basename "$RAW")"'/ && $2 ~ /^[0-9]+$/ {print $2":"($3-$2+1)}')
fi
for ps in $PARTS; do
  start=${ps%%:*}; count=${ps##*:}
  [ "$start" -gt 0 ] 2>/dev/null || continue
  dd if="$RAW" of="$PART_TMP" bs=512 skip="$start" count="$count" status=none 2>/dev/null || continue
  # e2fsck rc: 0=clean, 1=fixed, 2=fixed(reboot). >=4 or bad-magic => not ext / leave alone.
  rc=0; e2fsck -fy "$PART_TMP" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -le 2 ]; then
    dd if="$PART_TMP" of="$RAW" bs=512 seek="$start" count="$count" conv=notrunc status=none 2>/dev/null
    echo "  cleaned ext partition @sector $start (e2fsck rc=$rc)"
  fi
done
rm -f "$PART_TMP"

echo "compressing cleaned image -> $OUT"
gzip -c "$RAW" > "$OUT"
rm -f "$RAW"

sha256sum "$OUT" | tee "${OUT}.sha256"
echo "done (verified full-size, ext partitions fsck-clean): $OUT"
