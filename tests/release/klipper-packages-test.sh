#!/usr/bin/env bash
# Check that the two Klipper hosts cannot be selected together.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export GIT_OPTIONAL_LOCKS=0
br() { make -s -C "$repo/vendor/buildroot" BR2_EXTERNAL="$repo/br-external" O="$scratch" "$@"; }
br reforge_defconfig
grep -qx 'BR2_PACKAGE_KLIPPER=y' "$scratch/.config"
grep -qx '# BR2_PACKAGE_KLIPPER13 is not set' "$scratch/.config"
"$repo/vendor/buildroot/utils/config" --file "$scratch/.config" \
    --disable BR2_PACKAGE_KLIPPER --enable BR2_PACKAGE_KLIPPER13
br olddefconfig
grep -qx '# BR2_PACKAGE_KLIPPER is not set' "$scratch/.config"
grep -qx 'BR2_PACKAGE_KLIPPER13=y' "$scratch/.config"
# Reapplying the shipping defconfig must restore the stock-compatible host.
br reforge_defconfig
grep -qx 'BR2_PACKAGE_KLIPPER=y' "$scratch/.config"
grep -qx '# BR2_PACKAGE_KLIPPER13 is not set' "$scratch/.config"
echo 'Klipper package selection: default and alternative passed'
