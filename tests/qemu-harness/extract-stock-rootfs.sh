#!/usr/bin/env bash
# =============================================================================
# ReForge P3 Task 5: extract-stock-rootfs.sh
# Extract mmcblk0p6 (stock rootfs, ~1.31 GB) from the golden eMMC dump.
#
# REQUIRES: nothing privileged — fully rootless (sfdisk + dd + debugfs, no sudo)
# OUTPUT:   tests/qemu-harness/build/stock-rootfs.ext4
#
# Usage:
#   tests/qemu-harness/extract-stock-rootfs.sh
#   (or via: make qemu-stock-rootfs)
#
# What it does:
#   1. Decompress tools/recovery/golden.img.gz (clean stock) → build/golden-raw.img  (~7.3 GB)
#   2. Read p6 offset from the GPT (sfdisk) — no losetup
#   3. dd p6 (by byte offset) → build/stock-rootfs.ext4                  (~1.31 GB)
#   4. Delete golden-raw.img (saves ~6 GB)
#   5. Verify /opt/PROGRAM + /etc via debugfs (no mount)
#      → prints PASS or FAIL with findings
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
# Golden dumps live under tools/recovery/ (post-reorg). Honour an override so
# callers can point at an archived dump elsewhere.
RECOVERY_DIR="${RECOVERY_DIR:-${REPO_ROOT}/tools/recovery}"

RAW_IMG="${BUILD_DIR}/golden-raw.img"
ROOTFS_EXT4="${BUILD_DIR}/stock-rootfs.ext4"

log()  { echo "[extract-stock-rootfs] $*"; }
die()  { echo "[extract-stock-rootfs] ERROR: $*" >&2; exit 1; }
warn() { echo "[extract-stock-rootfs] WARN:  $*" >&2; }

# Rootless extraction: no loop devices, no mounts — nothing to clean up beyond
# the raw image (deleted in Step 4). VERIFY_MNT is unused (verify via debugfs).

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v sfdisk  >/dev/null || die "sfdisk not installed (util-linux) — needed to read the GPT"
command -v debugfs >/dev/null || die "debugfs not installed (e2fsprogs) — needed to verify"

mkdir -p "${BUILD_DIR}"

# ---------------------------------------------------------------------------
# Step 1: Find + decompress golden dump
# ---------------------------------------------------------------------------
log "Step 1: Locating golden eMMC dump in ${RECOVERY_DIR} ..."
# Prefer the curated pristine-stock image (golden.img.gz). Fall back to any
# golden-*.img.gz. We deliberately do NOT use forge-x-*.img.gz here: that is a
# forge-x-installed device dump (mod overlay in /data, patched init), not stock.
DUMP_GZ=$(find "${RECOVERY_DIR}" -maxdepth 1 -name 'golden.img.gz' | sort | tail -1)
[[ -n "${DUMP_GZ}" ]] || DUMP_GZ=$(find "${RECOVERY_DIR}" -maxdepth 1 -name 'golden-*.img.gz' | sort | tail -1)
[[ -n "${DUMP_GZ}" ]] || die "No golden.img.gz (clean stock) found in ${RECOVERY_DIR} — run make-clean-golden.sh"
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
# Step 2: Read the p6 (rootfs) offset + size from the GPT (rootless, no losetup)
# ---------------------------------------------------------------------------
log "Step 2: Reading p6 offset from the GPT via sfdisk ..."
read -r P6_START P6_SECTORS < <(sfdisk -d "${RAW_IMG}" 2>/dev/null \
    | awk -F'[ ,]+' '/img6 *:/ {for(i=1;i<=NF;i++){if($i=="start=")s=$(i+1);if($i=="size=")z=$(i+1)} print s, z}')
[[ -n "${P6_START:-}" && -n "${P6_SECTORS:-}" ]] || die "could not read p6 (rootfs) offset from GPT"
log "  p6: start=${P6_START} sectors, size=${P6_SECTORS} sectors ($(( P6_SECTORS / 2048 )) MiB)"

# ---------------------------------------------------------------------------
# Step 3: Slice p6 → stock-rootfs.ext4 by byte offset (dd, no root)
# ---------------------------------------------------------------------------
log "Step 3: Slicing p6 → ${ROOTFS_EXT4} ..."
local_t0=$(date +%s)
rm -f "${ROOTFS_EXT4}"
dd if="${RAW_IMG}" of="${ROOTFS_EXT4}" bs=512 skip="${P6_START}" count="${P6_SECTORS}" status=none
local_t1=$(date +%s)
log "  dd completed in $(( local_t1 - local_t0 ))s; size: $(du -sh "${ROOTFS_EXT4}" | cut -f1)"

# ---------------------------------------------------------------------------
# Step 3b: fsck the extracted rootfs.
#
# The golden eMMC dump was taken from a RUNNING system (the unit was up when
# `dd` ran), so the ext4 has an unclean journal — last in-memory writes never
# made it to disk, and the journal flag still says "needs recovery". Kernels
# refuse to mount such an FS without recovery; some test harnesses see the
# refusal as an unsolvable boot failure and report misleading panics. Run
# e2fsck -fy now so the on-disk image is in a clean, mountable state.
# ---------------------------------------------------------------------------
log "Step 3b: fsck the extracted rootfs (golden was dumped live -> unclean journal) ..."
if e2fsck -fy "${ROOTFS_EXT4}" >/tmp/extract-fsck.log 2>&1; then
    log "  e2fsck: clean ($(tail -1 /tmp/extract-fsck.log))"
else
    rc=$?
    # e2fsck returns 1 if it fixed problems, 2 if it fixed but reboot needed.
    # Both are OK for an offline image — we just want clean-on-disk.
    if [ "${rc}" -le 2 ]; then
        log "  e2fsck: fixed $(grep -c 'Fix' /tmp/extract-fsck.log) issue(s) [$(tail -1 /tmp/extract-fsck.log)]"
    else
        warn "  e2fsck returned ${rc} (problems left unfixed); inspect /tmp/extract-fsck.log"
    fi
fi
rm -f /tmp/extract-fsck.log

# ---------------------------------------------------------------------------
# Step 4: Delete the raw image (saves ~6 GB)
# ---------------------------------------------------------------------------
log "Step 4: Deleting raw image to reclaim space: ${RAW_IMG} ..."
rm -f "${RAW_IMG}"
log "  Freed: raw image deleted."

# ---------------------------------------------------------------------------
# Step 5: Verify rootfs contents (rootless, via debugfs — no mount)
# ---------------------------------------------------------------------------
log "Step 5: Verifying stock-rootfs.ext4 (debugfs) ..."
# The filesystem was live when dumped; debugfs reads it read-only without a
# journal replay, so no e2fsck/mount is needed just to inspect.
PASS=1

log "  Root directory:"
debugfs -R "ls -p /" "${ROOTFS_EXT4}" 2>/dev/null | tr '/' ' ' | awk -F' ' '{for(i=1;i<=NF;i++) if($i!="" && $i!="0") printf "%s ", $i} END{print ""}' | while read -r line; do log "    ${line}"; done

log "  Checking /opt/PROGRAM ..."
FWE=$(debugfs -R "ls -p /opt/PROGRAM/software" "${ROOTFS_EXT4}" 2>/dev/null | tr '/' '\n' | grep -E '^[0-9]+\.[0-9]+' | head -1 || true)
if [[ -n "${FWE}" ]] && debugfs -R "stat /opt/PROGRAM/software/${FWE}/firmwareExe" "${ROOTFS_EXT4}" 2>/dev/null | grep -q 'Inode:'; then
    log "  firmwareExe: FOUND at /opt/PROGRAM/software/${FWE}/firmwareExe"
    log "  stock rootfs CONFIRMED (/opt/PROGRAM/firmwareExe present)"
else
    warn "  firmwareExe not found under /opt/PROGRAM/software/*"
    warn "  This p6 may be forge-x-modified (firmwareExe removed/replaced)"
    PASS=0
fi

log "  Checking /etc ..."
if debugfs -R "stat /etc" "${ROOTFS_EXT4}" 2>/dev/null | grep -q 'Type: directory'; then
    log "  /etc: FOUND"
else
    warn "  /etc not found"
    PASS=0
fi

# Note if forge-x sentinel is present (expected if the dump was a forge-x unit)
if debugfs -R "stat /THIS_IS_NOT_YOUR_ROOT_FILESYSTEM" "${ROOTFS_EXT4}" 2>/dev/null | grep -q 'Inode:'; then
    warn "  NOTE: forge-x sentinel 'THIS_IS_NOT_YOUR_ROOT_FILESYSTEM' present"
    warn "        The dump was a forge-x unit; p6 is forge-x-modified rootfs."
fi

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
