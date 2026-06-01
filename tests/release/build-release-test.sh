#!/usr/bin/env bash
# build-release-test.sh — host unit test for the release builder (no qemu).
#
# Runs tools/release/build-release.sh --no-publish against the real build/output
# and asserts the per-component zips, their root-level 4-key release_info.json,
# the component payload spot-checks, and the USB .tgz.
#
# SKIPs cleanly (exit 0) when build/output/images/rootfs.tar is absent.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

if [ ! -f "$REPO/build/output/images/rootfs.tar" ]; then
    echo "SKIP: no build/output/images/rootfs.tar — run 'make rootfs' first"
    exit 0
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

VER=9.9.9 DIST_DIR="$OUT" "$REPO/tools/release/build-release.sh" --no-publish

for a in klipper moonraker guppyscreen reforge; do
    [ -f "$OUT/$a.zip" ] || { echo "FAIL: $a.zip missing"; exit 1; }

    # release_info.json MUST sit at the ZIP ROOT — not nested in a wrapper dir,
    # or net_deploy reads <path>/release_info.json and the component is silently
    # un-updatable. "$NF" is the path column from `unzip -l`.
    unzip -l "$OUT/$a.zip" | awk '{print $NF}' | grep -qx 'release_info.json' \
        || { echo "FAIL: $a.zip release_info.json not at zip root (nested wrapper?)"; exit 1; }

    # all four keys present + the right owner + the right version
    info="$(unzip -p "$OUT/$a.zip" release_info.json)"
    printf '%s' "$info" | grep -q '"project_name"'              || { echo "FAIL: $a release_info missing project_name"; exit 1; }
    printf '%s' "$info" | grep -q '"project_owner": "maci0"'    || { echo "FAIL: $a release_info missing/incorrect project_owner"; exit 1; }
    printf '%s' "$info" | grep -q '"version": "9.9.9"'          || { echo "FAIL: $a release_info version wrong"; exit 1; }
    printf '%s' "$info" | grep -q "\"asset_name\": \"$a.zip\""  || { echo "FAIL: $a release_info asset_name wrong"; exit 1; }
done

# component payload spot-checks
unzip -l "$OUT/klipper.zip" | grep -q 'klippy/chelper/c_helper.so' \
    || { echo "FAIL: klipper.zip missing prebuilt c_helper.so"; exit 1; }
unzip -l "$OUT/reforge.zip" | grep -qE 'etc/init\.d/S60klipper' \
    || { echo "FAIL: reforge.zip missing init scripts (S60klipper)"; exit 1; }
unzip -l "$OUT/reforge.zip" | grep -qE 'modules/zram\.ko' \
    || { echo "FAIL: reforge.zip missing modules/zram.ko"; exit 1; }
unzip -l "$OUT/reforge.zip" | grep -qE 'modules/swapon_prio' \
    || { echo "FAIL: reforge.zip missing modules/swapon_prio"; exit 1; }
unzip -l "$OUT/reforge.zip" | grep -qE 'usr/bin/reforge-banner' \
    || { echo "FAIL: reforge.zip missing usr/bin/reforge-banner"; exit 1; }

# the USB .tgz, renamed to the requested VER
[ -f "$OUT/reforge-9.9.9.tgz" ] || { echo "FAIL: USB reforge-9.9.9.tgz missing"; exit 1; }

echo "PASS: build-release"
