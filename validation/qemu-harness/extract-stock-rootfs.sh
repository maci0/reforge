#!/usr/bin/env bash
# =============================================================================
# ReForge P3 Task 5: extract-stock-rootfs.sh
# Extract mmcblk0p6 (stock rootfs, ~1.31 GB) from the golden eMMC dump.
#
# REQUIRES: sudo  (losetup + mount for loop-mount verification)
# OUTPUT:   validation/qemu-harness/build/stock-rootfs.ext4
#
# Usage:
#   sudo validation/qemu-harness/extract-stock-rootfs.sh
#   (or via: make qemu-stock-rootfs)
#
# What it does:
#   1. Decompress recovery/golden-kunos-*.img.gz → build/golden-raw.img  (~7.3 GB)
#   2. Attach GPT image via losetup -fP                                   → /dev/loopN
#   3. dd /dev/loopNp6 → build/stock-rootfs.ext4                         (~1.31 GB)
#   4. Detach loop; delete golden-raw.img (saves ~6 GB)
#   5. Loop-mount stock-rootfs.ext4 ro + verify /opt/PROGRAM + /etc
#      → prints PASS or FAIL with findings
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/validation/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
RECOVERY_DIR="${REPO_ROOT}/recovery"

RAW_IMG="${BUILD_DIR}/golden-raw.img"
ROOTFS_EXT4="${BUILD_DIR}/stock-rootfs.ext4"
VERIFY_MNT="/tmp/reforge-verify-$$"

log()  { echo "[extract-stock-rootfs] $*"; }
die()  { echo "[extract-stock-rootfs] ERROR: $*" >&2; exit 1; }
warn() { echo "[extract-stock-rootfs] WARN:  $*" >&2; }

# Cleanup trap — detaches loop + unmounts on any exit
LOOP_DEV=""
cleanup() {
    if [[ -n "${LOOP_DEV}" ]]; then
        log "Cleanup: detaching ${LOOP_DEV} ..."
        sudo losetup -d "${LOOP_DEV}" 2>/dev/null || true
        LOOP_DEV=""
    fi
    if mountpoint -q "${VERIFY_MNT}" 2>/dev/null; then
        sudo umount "${VERIFY_MNT}" 2>/dev/null || true
    fi
    rmdir "${VERIFY_MNT}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "Must be run as root (sudo $0)"

mkdir -p "${BUILD_DIR}"
mkdir -p "${VERIFY_MNT}"

# ---------------------------------------------------------------------------
# Step 1: Find + decompress golden dump
# ---------------------------------------------------------------------------
log "Step 1: Locating golden eMMC dump in ${RECOVERY_DIR} ..."
DUMP_GZ=$(find "${RECOVERY_DIR}" -maxdepth 1 -name 'golden-kunos-*.img.gz' | sort | tail -1)
[[ -n "${DUMP_GZ}" ]] || die "No golden-kunos-*.img.gz found in ${RECOVERY_DIR}"
log "  Found: ${DUMP_GZ} ($(du -sh "${DUMP_GZ}" | cut -f1))"

if [[ -f "${RAW_IMG}" ]]; then
    log "  Raw image already exists: ${RAW_IMG} — skipping decompress"
else
    log "  Decompressing → ${RAW_IMG}  (this may take several minutes) ..."
    local_t0=$(date +%s)
    gzip -dc "${DUMP_GZ}" > "${RAW_IMG}"
    local_t1=$(date +%s)
    log "  Decompressed in $(( local_t1 - local_t0 ))s; size: $(du -sh "${RAW_IMG}" | cut -f1)"
fi

# ---------------------------------------------------------------------------
# Step 2: Attach via losetup -fP (GPT-aware: creates /dev/loopNpX)
# ---------------------------------------------------------------------------
log "Step 2: Attaching GPT image via losetup -fP ..."
LOOP_DEV=$(sudo losetup -fP --show "${RAW_IMG}")
log "  Loop device: ${LOOP_DEV}"
log "  Waiting for partition nodes to settle ..."
sleep 1

# Verify p6 exists
P6="${LOOP_DEV}p6"
if [[ ! -b "${P6}" ]]; then
    # Try triggering partition re-read
    sudo partprobe "${LOOP_DEV}" 2>/dev/null || true
    sleep 1
fi
[[ -b "${P6}" ]] || die "Partition node not found: ${P6}  (check GPT + losetup support)"
log "  Partition 6: ${P6} ($(sudo blockdev --getsize64 "${P6}" 2>/dev/null | numfmt --to=si || echo 'size unknown'))"

# ---------------------------------------------------------------------------
# Step 3: dd p6 → stock-rootfs.ext4
# ---------------------------------------------------------------------------
log "Step 3: Copying p6 → ${ROOTFS_EXT4} ..."
local_t0=$(date +%s)
sudo dd if="${P6}" of="${ROOTFS_EXT4}" bs=4M status=progress 2>&1 || \
    sudo dd if="${P6}" of="${ROOTFS_EXT4}" bs=4M
local_t1=$(date +%s)
log "  dd completed in $(( local_t1 - local_t0 ))s; size: $(du -sh "${ROOTFS_EXT4}" | cut -f1)"

# ---------------------------------------------------------------------------
# Step 4: Detach loop + delete raw image (saves ~6 GB)
# ---------------------------------------------------------------------------
log "Step 4: Detaching loop device ${LOOP_DEV} ..."
sudo losetup -d "${LOOP_DEV}"
LOOP_DEV=""   # prevent double-detach in cleanup

log "  Deleting raw image to reclaim space: ${RAW_IMG} ..."
rm -f "${RAW_IMG}"
log "  Freed: raw image deleted."

# ---------------------------------------------------------------------------
# Step 5: Verify rootfs contents
# ---------------------------------------------------------------------------
log "Step 5: Verifying stock-rootfs.ext4 ..."

# The filesystem was live when dumped — replay journal so mount -ro succeeds.
log "  Running e2fsck (journal replay) ..."
sudo e2fsck -y "${ROOTFS_EXT4}" 2>&1 | tail -5 || true   # non-zero = fixed; that's fine

log "  Loop-mounting read-only at ${VERIFY_MNT} ..."
sudo mount -o loop,ro -t ext4 "${ROOTFS_EXT4}" "${VERIFY_MNT}" \
    || sudo mount -o loop,ro "${ROOTFS_EXT4}" "${VERIFY_MNT}" \
    || { warn "mount failed — cannot verify contents"; echo "VERIFY: SKIPPED"; exit 0; }

PASS=1

log "  Root directory:"
sudo ls "${VERIFY_MNT}/" 2>/dev/null | tr '\n' ' ' | while read -r line; do log "    ${line}"; done

log "  Checking /opt/PROGRAM ..."
if sudo ls "${VERIFY_MNT}/opt/PROGRAM" >/dev/null 2>&1; then
    log "  /opt/PROGRAM found:"
    sudo ls "${VERIFY_MNT}/opt/PROGRAM" | while read -r f; do log "    $f"; done

    # firmwareExe may be in a versioned subdirectory (e.g. /opt/PROGRAM/software/x.y.z/firmwareExe)
    FWE=$(sudo find "${VERIFY_MNT}/opt/PROGRAM" -name 'firmwareExe' 2>/dev/null | head -1)
    if [[ -n "${FWE}" ]]; then
        log "  firmwareExe: FOUND at ${FWE#${VERIFY_MNT}}"
        log "  firmwareExe size: $(sudo du -sh "${FWE}" 2>/dev/null | cut -f1)"
        log "  stock rootfs CONFIRMED (/opt/PROGRAM/firmwareExe present)"
    else
        warn "  firmwareExe not found anywhere under /opt/PROGRAM"
        warn "  This p6 may be forge-x-modified (firmwareExe removed/replaced)"
        PASS=0
    fi
else
    warn "  /opt/PROGRAM not found — this is NOT the expected stock rootfs"
    log "  /opt contents:"
    sudo ls "${VERIFY_MNT}/opt/" 2>/dev/null || echo "  (empty or missing)"
    PASS=0
fi

log "  Checking /etc ..."
if sudo [[ -d "${VERIFY_MNT}/etc" ]] 2>/dev/null || sudo test -d "${VERIFY_MNT}/etc" 2>/dev/null; then
    log "  /etc: FOUND"
else
    warn "  /etc not found"
    PASS=0
fi

# Note if forge-x sentinel is present (expected since unit was running forge-x when dumped)
if sudo test -e "${VERIFY_MNT}/THIS_IS_NOT_YOUR_ROOT_FILESYSTEM" 2>/dev/null; then
    warn "  NOTE: forge-x sentinel 'THIS_IS_NOT_YOUR_ROOT_FILESYSTEM' present"
    warn "        The unit was running forge-x when dumped; p6 is forge-x-modified rootfs."
    warn "        However /opt/PROGRAM/firmwareExe IS present — stock app binaries intact."
fi

sudo umount "${VERIFY_MNT}"
rmdir "${VERIFY_MNT}" 2>/dev/null || true

echo ""
if [[ "${PASS}" -eq 1 ]]; then
    log "========================================="
    log "  PASS: stock-rootfs.ext4 verified"
    log "        /opt/PROGRAM/firmwareExe present + /etc present"
    log "        Size: $(du -sh "${ROOTFS_EXT4}" | cut -f1)"
    log "========================================="
else
    log "========================================="
    warn "  FAIL: rootfs verification found issues (see above)"
    log "        The ext4 was extracted but may be forge-x-modified (p6 as mounted when dumped)"
    log "        Check /opt/PROGRAM contents above."
    log "========================================="
    exit 2
fi

log "Done.  ${ROOTFS_EXT4}"
