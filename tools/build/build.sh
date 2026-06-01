#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

verb="${1:-rootfs}"

# Single defconfig: the full ReForge stack (klipper + moonraker + mainsail +
# guppyscreen + zram). SCREEN_MODE gates the on-screen GUI at runtime, so there
# is no separate headless/guppy build. OUTPUT_DIR is build/output (from env.sh).
DEFCONFIG="reforge_defconfig"

# NOTE: $MULTICORE is intentionally unquoted so -jN expands as one arg under set -u
br() { make -C "$BUILDROOT_GIT" BR2_EXTERNAL="$BR2_EXTERNAL_DIR" O="$OUTPUT_DIR" "$@"; }

case "$verb" in
  defconfig)
    br "$DEFCONFIG"
    ;;
  rootfs)
    # IMPORTANT: always run defconfig before building so .config reflects the
    # current defconfig (Buildroot does NOT auto-apply defconfig changes).
    br "$DEFCONFIG"
    br $MULTICORE
    ;;
  clean)
    rm -rf "$OUTPUT_DIR"
    ;;
  *)
    echo "usage: build.sh {defconfig|rootfs|clean}"
    exit 1
    ;;
esac
