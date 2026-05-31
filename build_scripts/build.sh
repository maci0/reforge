#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

verb="${1:-rootfs}"
variant="${2:-}"   # optional: "guppyscreen" selects the full-stack variant

# Select defconfig + output dir based on variant
if [ "$variant" = "guppyscreen" ]; then
  DEFCONFIG="reforge_guppyscreen_defconfig"
  OUTPUT_DIR="$REFORGE_ROOT/output-guppy"
else
  DEFCONFIG="reforge_defconfig"
  # OUTPUT_DIR already set by env.sh
fi

# NOTE: $MULTICORE is intentionally unquoted so -jN expands as one arg under set -u
br() { make -C "$BUILDROOT_GIT" BR2_EXTERNAL="$BR2_EXTERNAL_DIR" O="$OUTPUT_DIR" "$@"; }

case "$verb" in
  defconfig)
    br "$DEFCONFIG"
    ;;
  rootfs|guppyscreen)
    # IMPORTANT: always run defconfig before building so .config reflects the
    # current defconfig (Buildroot does NOT auto-apply defconfig changes).
    br "$DEFCONFIG"
    br $MULTICORE
    ;;
  clean)
    rm -rf "$OUTPUT_DIR"
    ;;
  *)
    echo "usage: build.sh {defconfig|rootfs|clean} [guppyscreen]"
    exit 1
    ;;
esac
