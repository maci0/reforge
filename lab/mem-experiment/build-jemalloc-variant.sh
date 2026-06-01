#!/usr/bin/env bash
# jemalloc A/B build: reforge_defconfig + BR2_PACKAGE_JEMALLOC, into build/output-jemalloc
# (does NOT touch the product build/output). Experiment only — see
# docs/research/2026-06-01-jemalloc-test-plan.md.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
O="$REPO/build/output-jemalloc"
make -C "$REPO/vendor/buildroot" BR2_EXTERNAL="$REPO/br-external" O="$O" reforge_defconfig
cat >> "$O/.config" <<CFG
BR2_PACKAGE_JEMALLOC=y
CFG
make -C "$REPO/vendor/buildroot" BR2_EXTERNAL="$REPO/br-external" O="$O" olddefconfig
grep -E 'BR2_PACKAGE_JEMALLOC' "$O/.config"
make -C "$REPO/vendor/buildroot" BR2_EXTERNAL="$REPO/br-external" O="$O" -j"$(nproc)"
echo "VARIANT BUILD DONE -> $O/images/rootfs.tar.xz"
ls -la "$O/target/usr/lib/"libjemalloc.so* 2>/dev/null || echo "WARN: libjemalloc.so not found in target"
