#!/usr/bin/env bash
# Build the mainline T113 board kernel: allnoconfig + linux-mainline-t113.config.
# Size proxy only (no board DTS, not booted); never flash.
#
# Source: the linux-mainline row in pins.lock, fetched into vendor/kernels/ and
# checked against its SHA-256. Toolchain: the Buildroot gcc in build/output
# (override with CROSS_COMPILE). Output: build/kernel-mainline/{.config,vmlinux}.
set -euo pipefail
repo=$(cd "$(dirname "$0")" && until [ -e pins.lock ]; do cd ..; done; pwd)
die() { echo "build-mainline-kernel: $*" >&2; exit 1; }

read -r _ _ ver sha url < <(grep '^linux-mainline[[:space:]]' "$repo/pins.lock") \
    || die "no linux-mainline row in pins.lock"
src=$repo/vendor/kernels/linux-$ver
tarball=$repo/vendor/kernels/linux-$ver.tar.xz
frag=$repo/br-external/board/reforge/linux-mainline-t113.config
out=$repo/build/kernel-mainline
cross=${CROSS_COMPILE:-$repo/build/output/host/bin/arm-buildroot-linux-gnueabihf-}
[ -x "${cross}gcc" ] || die "no compiler at ${cross}gcc (run make rootfs, or set CROSS_COMPILE)"

if [ ! -f "$src/Makefile" ]; then
    [ -f "$tarball" ] || curl -fL --retry 3 -o "$tarball" "$url"
    echo "$sha  $tarball" | sha256sum -c --quiet - || die "sha256 mismatch: $tarball"
    tar -xJf "$tarball" -C "$repo/vendor/kernels"
fi

k() { make -C "$src" O="$out" ARCH=arm CROSS_COMPILE="$cross" "$@"; }
mkdir -p "$out"
KCONFIG_ALLCONFIG=$frag k allnoconfig >/dev/null

# Every requested value must survive Kconfig dependency resolution.
missing=0
while IFS='=' read -r sym val; do
    if [ "$val" = n ]; then
        grep -q "^$sym=" "$out/.config" || continue
    else
        grep -qx "$sym=$val" "$out/.config" && continue
    fi
    echo "not applied: $sym=$val (got: $(grep -E "^$sym=|^# $sym is not set" "$out/.config" || echo absent))" >&2
    missing=1
done < <(grep -E '^CONFIG_[A-Z0-9_]+=' "$frag")
[ "$missing" = 0 ] || die "config fragment did not apply"

k -j"$(nproc)" vmlinux
"${cross}size" "$out/vmlinux"
