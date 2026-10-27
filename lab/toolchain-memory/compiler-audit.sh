#!/usr/bin/env bash
# Per-package compiler audit of a Buildroot log: for each package's Building
# step, count compile lines run by clang-cc vs the gcc wrapper, and by -O level.
# Usage: lab/toolchain-memory/compiler-audit.sh build/output-<variant>.log
set -euo pipefail
log=${1:?usage: compiler-audit.sh <buildroot log>}
awk '
/^\x1b\[7m>>> / {
    pkg = $2
    building = ($0 ~ / Building/) && pkg !~ /^host-/
    next
}
building && / -c / {
    cc = /clang-cc|clang-c\+\+/ ? "clang" : (/gnueabihf-(gcc|g\+\+|c\+\+)/ ? "gcc" : "")
    if (cc == "") next
    n[pkg, cc]++
    if (/ -Oz /) oz[pkg]++
    else if (/ -Os /) os[pkg]++
    else if (/ -O[1-3] /) o2[pkg]++
    seen[pkg] = 1
}
END {
    printf "%-28s %6s %6s %6s %6s %6s\n", "package", "clang", "gcc", "-Oz", "-Os", "-O1-3"
    for (p in seen)
        printf "%-28s %6d %6d %6d %6d %6d\n", p, n[p, "clang"], n[p, "gcc"], oz[p], os[p], o2[p]
}' "$log" | sort -k1,1
