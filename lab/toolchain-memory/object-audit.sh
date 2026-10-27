#!/usr/bin/env bash
# Per-package compiler audit from object files: the .comment section of each
# .o under build/output-<variant>/build/<pkg>/ names the compiler that built it
# (target files are stripped of it, objects are not). Host packages skipped.
# Usage: lab/toolchain-memory/object-audit.sh build/output-<variant>
set -euo pipefail
out=${1:?usage: object-audit.sh build/output-<variant>}
printf '%-36s %6s %6s %6s\n' package clang gcc other
for d in "$out"/build/*/; do
    pkg=$(basename "$d")
    case "$pkg" in host-*|buildroot-*|toolchain*|skeleton*) continue ;; esac
    c=0 g=0 o=0
    while IFS= read -r -d '' f; do
        s=$(readelf -p .comment "$f" 2>/dev/null || true)
        case "$s" in
            *clang*) c=$((c + 1)) ;;
            *GCC*) g=$((g + 1)) ;;
            *) o=$((o + 1)) ;;
        esac
    done < <(find "$d" -name '*.o' -type f -print0)
    [ $((c + g + o)) -gt 0 ] && printf '%-36s %6d %6d %6d\n' "$pkg" "$c" "$g" "$o"
done
