#!/usr/bin/env bash
# Run one autoresearch iteration:
#   $1 = iter number
#   $2 = hypothesis string (short label)
#
# Assumes the experimental edit has ALREADY been made to
# vendor/kernels/patches/0001-byte-identical-reproduction.patch.
# Runs bash autoresearch.sh, prints "<iter> | <hypothesis> | size_delta=N",
# and writes a JSONL line to autoresearch.jsonl.
#
# Caller is responsible for deciding keep/revert based on output and
# either calling `git commit` or `git checkout -- ...` afterward.

set -euo pipefail
ITER="${1:?iter num}"
HYP="${2:?hypothesis label}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

OUT=$(./autoresearch.sh) || { echo "BUILD FAILED"; exit 3; }

# parse
SIZE_DELTA=$(echo "$OUT" | python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["size_delta"])')
SIZE_ABS=$(echo "$OUT" | python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["size_delta_abs"])')
CMP=$(echo "$OUT" | python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["cmp_l_count"])')
FIRST=$(echo "$OUT" | python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["first_diff_off"])')
ELAPSED=$(echo "$OUT" | python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["elapsed_s"])')

# log
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"iter":%s,"hypothesis":"%s","size_delta":%s,"size_delta_abs":%s,"cmp_l_count":%s,"first_diff_off":"%s","elapsed_s":%s,"ts":"%s"}\n' \
    "$ITER" "$HYP" "$SIZE_DELTA" "$SIZE_ABS" "$CMP" "$FIRST" "$ELAPSED" "$TS" \
    >> autoresearch.jsonl

printf "iter %s | %-50s | size_delta=%+d  cmp=%d  first=%s  (%ds)\n" \
    "$ITER" "$HYP" "$SIZE_DELTA" "$CMP" "$FIRST" "$ELAPSED"
