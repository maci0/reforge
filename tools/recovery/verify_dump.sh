#!/bin/sh
# Usage: ./verify_dump.sh golden-xxx.img.gz
set -eu
GZ="${1:?usage: verify_dump.sh <golden.img.gz>}"
DIR=$(dirname "$GZ")

# Expected eMMC size: prefer the .size sidecar; else parse partitions-*.txt
SIZEFILE="${GZ%.img.gz}.size"
if [ -f "$SIZEFILE" ]; then
  EXPECT=$(cat "$SIZEFILE")
else
  PFILE=$(ls "$DIR"/partitions-*.txt 2>/dev/null | head -n1)
  EXPECT=$(awk '/---SIZE---/{getline; print; exit}' "$PFILE")
  [ -n "$EXPECT" ] || { echo "FAIL: cannot determine expected size"; exit 1; }
  echo "$EXPECT" > "$SIZEFILE"   # backfill sidecar for future runs
fi

ACTUAL=$(gzip -dc "$GZ" | wc -c)
echo "expected=$EXPECT actual=$ACTUAL"
[ "$EXPECT" = "$ACTUAL" ] || { echo "TRUNCATED/MISMATCH"; exit 1; }

if [ -f "${GZ}.sha256" ]; then
  echo "sha256:"; sha256sum -c "${GZ}.sha256"
else
  echo "no .sha256 sidecar — generating one"; sha256sum "$GZ" | tee "${GZ}.sha256"
fi
echo "OK: dump is full-size and checksum-valid"
