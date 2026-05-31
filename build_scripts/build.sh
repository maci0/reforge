#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
verb="${1:-rootfs}"
# NOTE: $MULTICORE is intentionally unquoted so -jN expands as one arg under set -u
br() { make -C "$BUILDROOT_GIT" BR2_EXTERNAL="$BR2_EXTERNAL_DIR" O="$OUTPUT_DIR" "$@"; }
case "$verb" in
  defconfig) br reforge_defconfig ;;
  rootfs)    br reforge_defconfig; br $MULTICORE ;;
  clean)     rm -rf "$OUTPUT_DIR" ;;
  *) echo "usage: build.sh {defconfig|rootfs|clean}"; exit 1 ;;
esac
