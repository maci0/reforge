#!/bin/sh
# ReForge rootfs post-build hook. Real service install lands in Plan 2.
set -e
TARGET_DIR="$1"
echo "reforge-foundation" > "$TARGET_DIR/etc/reforge-stage"
