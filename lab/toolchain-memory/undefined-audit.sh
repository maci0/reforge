#!/usr/bin/env bash
# List strong undefined dynamic symbols in a target rootfs that no ELF file in
# that rootfs defines, with the files that need them. Catches runtime-ABI gaps
# such as clang calling compiler-rt helpers that libgcc does not export.
# Usage: lab/toolchain-memory/undefined-audit.sh build/output-<variant>/target
set -euo pipefail
root=${1:?usage: undefined-audit.sh <target dir>}
mapfile -d '' elfs < <(find "$root" -type f \( -perm -u+x -o -name '*.so*' \) -print0)
defined=$(mktemp -p "$root/.." audit.XXXXXX)
trap 'rm -f "$defined"' EXIT
for f in "${elfs[@]}"; do
    # nm fails on non-ELF files (scripts, data); skip them, keep the pipeline alive.
    { nm -D --defined-only "$f" 2>/dev/null || true; } | awk '{print $NF}'
done | sed 's/@.*//' | sort -u > "$defined"
for f in "${elfs[@]}"; do
    # Strong undefined only: weak references ("w"/"v") may stay unresolved.
    { nm -D --undefined-only "$f" 2>/dev/null || true; } | awk '$1 == "U" {print $2}' | sed 's/@.*//' |
        sort -u | comm -23 - "$defined" | sed "s|^|${f#"$root"}: |"
done
