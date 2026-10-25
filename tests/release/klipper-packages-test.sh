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
grep -qx 'BR2_TOOLCHAIN_BARE_METAL_BUILDROOT=y' "$scratch/.config"
grep -qx 'BR2_TOOLCHAIN_BARE_METAL_BUILDROOT_ARCH="arm-none-eabi"' "$scratch/.config"
grep -qx '# BR2_TOOLCHAIN_BARE_METAL_BUILDROOT_MULTILIB is not set' "$scratch/.config"
grep -qx 'BR2_PACKAGE_NEWLIB_BARE_METAL=y' "$scratch/.config"
compiler_opts=$(br printvars VARS=HOST_GCC_BARE_METAL_CONF_OPTS)
[[ "$compiler_opts" == *--with-cpu=cortex-m4* ]]
[[ "$compiler_opts" == *--with-mode=thumb* ]]
[[ "$compiler_opts" == *--with-float=soft* ]]
# Reapplying the shipping defconfig must restore the stock-compatible host.
br reforge_defconfig
grep -qx 'BR2_PACKAGE_KLIPPER=y' "$scratch/.config"
grep -qx '# BR2_PACKAGE_KLIPPER13 is not set' "$scratch/.config"
echo 'Klipper package selection: default and alternative passed'
