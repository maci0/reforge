#!/usr/bin/env bash
# autoresearch benchmark wrapper for the "close the +128 B gap" experiment.
#
# Runs tools/build/build-bsp-kernel-stock.sh (which applies the byte-identical
# reproduction patch, builds, and reverts the BSP submodule), then computes
# three metrics vs the cached stock Image:
#
#   size_delta      = bytes(Image.ours-linaro) - bytes(Image.stock)   [PRIMARY]
#   cmp_l_count     = number of differing bytes (cmp -l)              [SECONDARY]
#   first_diff_off  = first byte offset where they differ (hex)       [SECONDARY]
#
# Emits one JSON line on stdout: {"size_delta": ..., "cmp_l_count": ...,
#                                   "first_diff_off": "...", "ok": true}
# Exit 0 on success, non-zero on build failure.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

BUILD_LOG=/tmp/autoresearch-build.log
ART=build/bsp-kernel-rebuild-stock/artifacts
STOCK_IMG="$(realpath build/bsp-kernel-rebuild/artifacts/Image.stock 2>/dev/null || true)"

if [ ! -f "$STOCK_IMG" ]; then
    echo '{"ok":false,"error":"Image.stock missing"}' >&2; exit 2
fi

rm -rf "${ART%/artifacts}"  # clean build dir for reproducibility
START=$(date +%s)
if ! tools/build/build-bsp-kernel-stock.sh > "$BUILD_LOG" 2>&1; then
    echo "{\"ok\":false,\"error\":\"build failed; tail $BUILD_LOG\",\"elapsed\":$(( $(date +%s) - START ))}" >&2
    tail -30 "$BUILD_LOG" >&2
    exit 3
fi
ELAPSED=$(( $(date +%s) - START ))

if [ ! -f "$ART/Image.ours-linaro" ]; then
    echo '{"ok":false,"error":"Image.ours-linaro missing after build"}' >&2; exit 4
fi

OURS="$ART/Image.ours-linaro"
SZ_O=$(stat -c %s "$OURS")
SZ_S=$(stat -c %s "$STOCK_IMG")
SIZE_DELTA=$(( SZ_O - SZ_S ))
SIZE_DELTA_ABS=$(( SIZE_DELTA < 0 ? -SIZE_DELTA : SIZE_DELTA ))

# cmp -l returns first-differing byte (or empty if identical); count lines
# Drop pipefail around cmp pipelines so SIGPIPE from `head -1` doesn't abort.
set +o pipefail
CMP_L_COUNT=$(cmp -l "$OURS" "$STOCK_IMG" 2>/dev/null | wc -l)
FIRST_DIFF_OFF=$(cmp -l "$OURS" "$STOCK_IMG" 2>/dev/null | head -1 | awk '{printf "0x%x", $1-1}')
set -o pipefail
[ -z "$FIRST_DIFF_OFF" ] && FIRST_DIFF_OFF="(none)"

printf '{"ok":true,"size_delta":%d,"size_delta_abs":%d,"cmp_l_count":%d,"first_diff_off":"%s","elapsed_s":%d,"sz_ours":%d,"sz_stock":%d}\n' \
    "$SIZE_DELTA" "$SIZE_DELTA_ABS" "$CMP_L_COUNT" "$FIRST_DIFF_OFF" "$ELAPSED" "$SZ_O" "$SZ_S"
