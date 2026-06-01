#!/bin/sh
# qemu-user smoke test of the built ReForge rootfs.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAR="$ROOT/build/output/images/rootfs.tar.xz"
EXTRACT="$ROOT/build/output/smoke-root"
[ -f "$TAR" ] || { echo "FAIL: no rootfs at $TAR"; exit 1; }
rm -rf "$EXTRACT"; mkdir -p "$EXTRACT"
tar -C "$EXTRACT" -xf "$TAR"

# 1) busybox must be ARM and must run under qemu-user
file "$EXTRACT/bin/busybox" | grep -q "ARM" || { echo "FAIL: busybox not ARM"; exit 1; }
OUT=$(QEMU_LD_PREFIX="$EXTRACT" qemu-arm-static "$EXTRACT/bin/busybox" echo reforge-ok)
[ "$OUT" = "reforge-ok" ] || { echo "FAIL: busybox did not run under qemu ($OUT)"; exit 1; }

# 2) our overlay + post-build markers must be present
grep -q "ID=reforge" "$EXTRACT/etc/os-release" || { echo "FAIL: os-release branding missing"; exit 1; }
[ "$(cat "$EXTRACT/etc/reforge-stage")" = "reforge-foundation" ] || { echo "FAIL: post-build marker missing"; exit 1; }

echo "PASS: rootfs runs under qemu-user and is branded ReForge"
