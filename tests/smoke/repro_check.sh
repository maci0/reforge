#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMPDIR_REPRO="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_REPRO"' EXIT
manifest() { # $1 = extract dir -> sorted "mode size sha path"
  cd "$1"; find . -type f -printf '%m %s ' -exec sha256sum {} \; | sort -k4
}
hashtree() {
  EXTRACT="$TMPDIR_REPRO/repro-$1"
  rm -rf "$EXTRACT"; mkdir -p "$EXTRACT"
  tar -C "$EXTRACT" -xf "$ROOT/output/images/rootfs.tar.xz"
  manifest "$EXTRACT" > "$TMPDIR_REPRO/repro-$1.manifest"
  cd "$ROOT"
}
make -C "$ROOT" clean && make -C "$ROOT" rootfs && hashtree a
make -C "$ROOT" clean && make -C "$ROOT" rootfs && hashtree b
if diff -u "$TMPDIR_REPRO/repro-a.manifest" "$TMPDIR_REPRO/repro-b.manifest"; then
  echo "PASS: reproducible (identical file manifests)"
else
  echo "FAIL: build is not reproducible"; exit 1
fi
