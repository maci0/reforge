#!/usr/bin/env bash
# =============================================================================
# build-bsp-kernel-stock.sh — rebuild the BSP kernel attempting BYTE-IDENTICAL
# reproduction of stock.
#
# Differences vs the sibling `build-bsp-kernel.sh`:
#
#   - Uses **Linaro GCC 5.3.1 20160412 + binutils 2.25.0** (the exact stock
#     toolchain). vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/
#     The vanilla build script uses our pinned GCC 9.5.0 (deliberate, for
#     ReForge's shipping toolchain validation).
#
#   - Builds **from the exact stock source path**
#     `/home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4/`
#     (via a sudo-created symlink to our submodule), so `__FILE__` macros and
#     `.rodata` strings match stock byte-for-byte. Without this, every
#     `WARN_ON`/`BUG_ON` site embeds our local path string instead.
#
#   - Output: build/bsp-kernel-rebuild-stock/ (separate from the GCC 9.5
#     build under build/bsp-kernel-rebuild/), gitignored.
#
# Status: experiment toward L3 (byte-identical Image) per
# docs/research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md.
# Plan: docs/plans/2026-06-04-bsp-kernel-rebuild-and-diff.md
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The stock-path symlink that points at our submodule (set up once via:
#   sudo mkdir -p /home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/
#   sudo chown -R $USER /home/linux
#   ln -sfn "${REPO_ROOT}/vendor/kernels/tina-bsp-kernel" \
#       /home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4
# )
STOCK_PATH="/home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4"

LINARO_DIR="${REPO_ROOT}/vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi"
TC_PREFIX="${LINARO_DIR}/bin/arm-linux-gnueabi-"

STOCK_CFG_GZ="${REPO_ROOT}/docs/board-notes/stock-kernel-config-5.4.61.txt.gz"
OUT="${OUT:-${REPO_ROOT}/build/bsp-kernel-rebuild-stock}"

# Build metadata pinned to stock's embedded banner (Wed Aug 23 15:33:33 CST 2023)
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1692776013}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Wed Aug 23 15:33:33 CST 2023}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-root}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-linux-virtual-machine}"
export KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION:-52}"

JOBS="${BUILD_JOBS:-$(nproc)}"

# Stock build host did not have g++ available, so olddefconfig saw
# CONFIG_PLUGIN_HOSTCC="" and left CONFIG_GCC_PLUGINS off. With g++ on our
# host olddefconfig auto-enables GCC_PLUGINS + STACKPROTECTOR_PER_TASK +
# GCC_PLUGIN_ARM_SSP_PER_TASK, which adds plugin code to the Image and
# diverges from stock. Forcing HOSTCXX to a non-functional command makes
# scripts/Kconfig.include's $(success,$(HOSTCXX) -E ...) check fail, which
# leaves PLUGIN_HOSTCC empty and matches stock's behaviour.
export HOSTCXX=/bin/false

log()  { echo "[build-bsp-kernel-stock] $*"; }
die()  { echo "[build-bsp-kernel-stock] ERROR: $*" >&2; exit 1; }

# Stock path can be a symlink (point at our submodule) OR a bind-mount.
# Both work; the bind-mount approach gets __FILE__ macros stamped with the
# stock path (because kbuild realpath stops at the mount point), while a
# symlink leaks the real path back through `realpath`. Prefer bind-mount.
[ -e "${STOCK_PATH}" ]        || die "Stock-path not set up: ${STOCK_PATH} (run the symlink-or-bind-mount setup)"
[ -d "${STOCK_PATH}/arch" ]   || die "Stock-path doesn't expose arch/ — setup broken"
[ -x "${TC_PREFIX}gcc" ]      || die "Linaro toolchain not found: ${TC_PREFIX}gcc"
[ -f "${STOCK_CFG_GZ}" ]      || die "captured .config not found: ${STOCK_CFG_GZ}"

# --- patch overlay ----------------------------------------------------------
# Apply the byte-identical-reproduction patches on top of the clean BSP
# submodule. Patches add CAN_SUN8I wiring, reconstruct sunxi_can_asm.h, stub
# RTL8821CU, hide 14 newer Kconfig symbols, and force PLUGIN_HOSTCC="".
# The trap reverts everything on exit so the submodule never has dirty state.
KSRC_REAL="${REPO_ROOT}/vendor/kernels/tina-bsp-kernel"
PATCH="${REPO_ROOT}/vendor/kernels/patches/0001-byte-identical-reproduction.patch"
[ -f "${PATCH}" ] || die "reproduction patch not found: ${PATCH}"

revert_patch() {
    log "Reverting patch (returning submodule to clean state)"
    git -C "${KSRC_REAL}" checkout -- . 2>/dev/null || true
    rm -rf "${KSRC_REAL}/drivers/staging/rtl8821cu"
    rm -f  "${KSRC_REAL}/drivers/net/can/sunxi_can_asm.h"
    rm -f  "${KSRC_REAL}/.scmversion"
}
trap revert_patch EXIT INT TERM

log "Applying reproduction patch ..."
if ! git -C "${KSRC_REAL}" apply --check "${PATCH}" 2>/dev/null; then
    die "patch fails --check; submodule may have stale state. Run: git -C ${KSRC_REAL} checkout -- .  &&  rm -rf ${KSRC_REAL}/drivers/staging/rtl8821cu ${KSRC_REAL}/drivers/net/can/sunxi_can_asm.h"
fi
git -C "${KSRC_REAL}" apply "${PATCH}"
log "  patch applied (§CAN_SUN8I wiring, sunxi_can_asm.h, RTL8821CU stub, 14 Kconfig hides, PLUGIN_HOSTCC=\"\")"

mkdir -p "${OUT}/artifacts"

# Pin build-version to 51 so the next link increments to 52 (matches stock).
echo 51 > "${OUT}/.version"

# Suppress the '+' scmversion suffix; stock built from a tagged tree.
: > "${STOCK_PATH}/.scmversion"

MAKE_ARGS=(
    -C "${STOCK_PATH}"
    O="${OUT}"
    ARCH=arm
    CROSS_COMPILE="${TC_PREFIX}"
)

# --- 1. seed the .config from the captured stock config ---------------------
log "Seeding .config from ${STOCK_CFG_GZ##*/}"
zcat "${STOCK_CFG_GZ}" > "${OUT}/.config"
cp "${OUT}/.config" "${OUT}/.config.captured"

# Stock's build had no g++ on the host (PLUGIN_HOSTCC="") so GCC_PLUGINS
# stayed off. Our build host DOES have g++ + plugin headers, so olddefconfig
# would auto-enable GCC_PLUGINS + GCC_PLUGIN_ARM_SSP_PER_TASK +
# STACKPROTECTOR_PER_TASK — adding plugin-emitted code to the Image and
# diverging from stock. Force these off in the seed so olddefconfig keeps them
# off (no need to override after).
cat >> "${OUT}/.config" <<'EOF'
# CONFIG_GCC_PLUGINS is not set
# CONFIG_GCC_PLUGIN_ARM_SSP_PER_TASK is not set
# CONFIG_STACKPROTECTOR_PER_TASK is not set
EOF

# --- 2. olddefconfig + diff -------------------------------------------------
log "Running olddefconfig with Linaro 5.3.1 ..."
make "${MAKE_ARGS[@]}" olddefconfig >/dev/null
diff "${OUT}/.config.captured" "${OUT}/.config" > "${OUT}/diff-config.txt" || true
n_diff=$(grep -cE '^[<>]' "${OUT}/diff-config.txt" || true)
log "  olddefconfig delta: ${n_diff} lines (should be near 0 with matching toolchain)"

# --- 3. build the kernel ----------------------------------------------------
log "Building Image (Linaro 5.3.1 + stock build path)  JOBS=${JOBS} ..."
make "${MAKE_ARGS[@]}" -j"${JOBS}" Image 2>&1 | tail -20

# --- 4. stage artifacts -----------------------------------------------------
log "Staging artifacts ..."
cp "${OUT}/arch/arm/boot/Image" "${OUT}/artifacts/Image.ours-linaro"
cp "${OUT}/vmlinux"             "${OUT}/artifacts/vmlinux.ours-linaro"
cp "${OUT}/System.map"          "${OUT}/artifacts/System.map.ours-linaro"
cp "${OUT}/.config"             "${OUT}/artifacts/.config.ours-linaro"

# Cross-link the previously-built stock artifact for diffing
STOCK_REF="${REPO_ROOT}/build/bsp-kernel-rebuild/artifacts/Image.stock"
[ -f "${STOCK_REF}" ] && ln -sfn "${STOCK_REF}" "${OUT}/artifacts/Image.stock"

log "Build complete. Artifacts:"
# shellcheck disable=SC2012
ls -la "${OUT}/artifacts/" | sed 's/^/  /'
log "Next: diff Image.ours-linaro against Image.stock"
