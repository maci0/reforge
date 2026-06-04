#!/usr/bin/env bash
# =============================================================================
# build-bsp-kernel.sh — rebuild the stock AD5M Pro BSP kernel from source.
#
# Plan: docs/plans/2026-06-04-bsp-kernel-rebuild-and-diff.md
#
# Pure host-side, no device touched. Uses:
#   - BSP source: vendor/kernels/tina-bsp-kernel @ 349a0b9 (5.4.61)
#   - Captured stock .config: docs/board-notes/stock-kernel-config-5.4.61.txt.gz
#   - Pinned toolchain: vendor/toolchains/gcc-9.5.0-nolibc/arm-linux-gnueabi/
#
# Outputs into build/bsp-kernel-rebuild/ (gitignored under /build/):
#   .config           — the captured stock .config, normalised by olddefconfig
#   diff-config.txt   — diff of captured-vs-normalised (empty = good)
#   arch/arm/boot/Image, zImage
#   vmlinux + System.map
#   arch/arm/boot/dts/*.dtb
#   artifacts/        — staged for the comparison step
#
# Reproducibility env: SOURCE_DATE_EPOCH + KBUILD_BUILD_TIMESTAMP/USER/HOST
# pinned to stock build metadata (extracted from the embedded version banner).
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KSRC="${REPO_ROOT}/vendor/kernels/tina-bsp-kernel"
TC_PREFIX="${REPO_ROOT}/vendor/toolchains/gcc-9.5.0-nolibc/arm-linux-gnueabi/bin/arm-linux-gnueabi-"
STOCK_CFG_GZ="${REPO_ROOT}/docs/board-notes/stock-kernel-config-5.4.61.txt.gz"
OUT="${OUT:-${REPO_ROOT}/build/bsp-kernel-rebuild}"

# Build metadata, pinned to the stock version banner so embedded __DATE__ /
# __TIME__ / KBUILD_BUILD_* strings don't add noise to the diff. The stock
# embedded "Linux version 5.4.61 ... #52 SMP PREEMPT Wed Aug 23 15:33:33 CST 2023"
# Wed 2023-08-23 15:33:33 CST (UTC+8) == 2023-08-23 07:33:33 UTC == epoch 1692776013
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1692776013}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Wed Aug 23 15:33:33 CST 2023}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-root}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-linux-virtual-machine}"
# Match stock build number (#52). Used by make to pick a fresh number; we pin
# it via KBUILD_BUILD_VERSION (some kernels honour it; otherwise the version
# string differs in the #N field only — easy to filter out of the diff).
export KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION:-52}"

JOBS="${BUILD_JOBS:-$(nproc)}"

log()  { echo "[build-bsp-kernel] $*"; }
die()  { echo "[build-bsp-kernel] ERROR: $*" >&2; exit 1; }

[ -d "${KSRC}" ]              || die "BSP source not found at ${KSRC} (./vendor/fetch.sh)"
[ -x "${TC_PREFIX}gcc" ]      || die "toolchain not found: ${TC_PREFIX}gcc (./vendor/fetch.sh)"
[ -f "${STOCK_CFG_GZ}" ]      || die "captured .config not found: ${STOCK_CFG_GZ}"

# Cross-compile flags reused by every make invocation
MAKE_ARGS=(
    -C "${KSRC}"
    O="${OUT}"
    ARCH=arm
    CROSS_COMPILE="${TC_PREFIX}"
)

mkdir -p "${OUT}/artifacts"

# -- 0. suppress trailing '+' in the kernel version string -------------------
# scripts/setlocalversion appends '+' when HEAD is not on an annotated tag and
# CONFIG_LOCALVERSION_AUTO=n (our case). An empty .scmversion file tells it to
# stop. Stock built from a tagged tree, so its vermagic is plain "5.4.61".
# Without this, modules built against either kernel would not load on the
# other due to vermagic mismatch ("5.4.61" ≠ "5.4.61+").
: > "${KSRC}/.scmversion"

# -- 1. seed the .config from the captured stock config ----------------------
log "Seeding .config from ${STOCK_CFG_GZ##*/}"
zcat "${STOCK_CFG_GZ}" > "${OUT}/.config"
cp "${OUT}/.config" "${OUT}/.config.captured"

# -- 2. olddefconfig + capture the delta -------------------------------------
log "Running olddefconfig (auto-defaults for any new symbols vs captured) ..."
make "${MAKE_ARGS[@]}" olddefconfig >/dev/null
# Plain `diff` so the '^[<>]' counter works as documented in the plan.
diff "${OUT}/.config.captured" "${OUT}/.config" > "${OUT}/diff-config.txt" || true
n_diff=$(grep -cE '^[<>]' "${OUT}/diff-config.txt" || true)
log "  olddefconfig delta: ${n_diff} lines (see diff-config.txt)"

# -- 3. build the kernel -----------------------------------------------------
#
# Note on dtbs: the Allwinner Tina BSP's `dtbs` target expects a `board.dtb`
# that the higher-level Lichee/Longan SDK injects from outside the kernel tree.
# Stock's on-disk boot.img has NO DTB in the second slot (second_size=0
# confirmed by unpack-android-bootimg.py against mmcblk0p4), so U-Boot loads
# the DTB from boot-resource (mmcblk0p1) instead. For this rebuild we are
# comparing the kernel Image only — DTB is a separate concern. Skip `dtbs`.
log "Building Image + zImage + modules  (JOBS=${JOBS}) ..."
make "${MAKE_ARGS[@]}" -j"${JOBS}" Image zImage modules

# -- 4. stage artifacts ------------------------------------------------------
log "Staging artifacts ..."
cp "${OUT}/arch/arm/boot/Image"     "${OUT}/artifacts/Image.ours"
cp "${OUT}/arch/arm/boot/zImage"    "${OUT}/artifacts/zImage.ours"
cp "${OUT}/vmlinux"                 "${OUT}/artifacts/vmlinux.ours"
cp "${OUT}/System.map"              "${OUT}/artifacts/System.map.ours"

# Find every DTB whose name might match an AD5M / sun8i T113 board (none
# expected here — dtbs target skipped above — but stage if present)
find "${OUT}/arch/arm/boot/dts" -maxdepth 2 -name '*.dtb' -print 2>/dev/null | while read -r dtb; do
    base=$(basename "${dtb}")
    case "${base}" in
        *t113*|*ad5m*|*flashforge*|*sun8i*) cp "${dtb}" "${OUT}/artifacts/${base}.ours" ;;
    esac
done

# Save the .config we actually built with (post-olddefconfig)
cp "${OUT}/.config" "${OUT}/artifacts/.config.ours"

log "Build complete. Artifacts:"
# shellcheck disable=SC2012  # diagnostic listing only; ls is fine here
ls -la "${OUT}/artifacts/" | sed 's/^/  /'
log "Next: run the Tier 1-4 comparison against artifacts/Image.stock + .config.captured"
