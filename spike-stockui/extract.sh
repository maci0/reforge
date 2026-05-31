#!/usr/bin/env bash
# =============================================================================
# ReForge P3 Task 8: spike-stockui/extract.sh
#
# Extract firmwareExe + Qt libs from the stock environment into
# spike-stockui/extracted/  (GITIGNORED — proprietary blobs, never commit).
#
# Sources (in order of preference):
#   1. stock-rootfs.ext4 — loop-mount and copy /opt/PROGRAM/software/5.1.4/
#      + /opt/qt-4.8.6/lib/ + /opt/tslib-1.12/lib/ + other needed libs.
#   2. ../fw-analysis/software-5.1.4/  — direct copy of firmwareExe.
#   3. ../fw-analysis/library-5.1.4/   — env.cfg and ffstartup config.
#
# Usage:
#   sudo spike-stockui/extract.sh
#   (sudo needed for loop mount of stock-rootfs.ext4)
#
# Output:
#   spike-stockui/extracted/
#     firmwareExe          — the ARM ELF (unstripped, debug_info)
#     env.cfg              — Qt + tslib + LD_LIBRARY_PATH env (from library pkg)
#     ffstartup.cfg        — process startup config (AppArgs: -1;-D;-qws)
#     qt-libs/             — libQtCore.so.4, libQtGui.so.4, libQtNetwork.so.4
#     tslib-libs/          — libts.so.0
#     manifest.txt         — md5 + source for each extracted file
#
# Environment:
#   ROOTFS_IMG=<path>     override stock-rootfs.ext4 location
#   FW_ANALYSIS_DIR=<path> override ../fw-analysis location
#   SKIP_LOOP_MOUNT=1     skip loop mount (use fw-analysis only)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SPIKE_DIR="${SCRIPT_DIR}"
EXTRACTED="${SPIKE_DIR}/extracted"

FW_ANALYSIS_DIR="${FW_ANALYSIS_DIR:-${REPO_ROOT}/../fw-analysis}"
ROOTFS_IMG="${ROOTFS_IMG:-${REPO_ROOT}/validation/qemu-harness/build/stock-rootfs.ext4}"
SKIP_LOOP_MOUNT="${SKIP_LOOP_MOUNT:-0}"

log()  { echo "[extract] $*"; }
die()  { echo "[extract] ERROR: $*" >&2; exit 1; }
warn() { echo "[extract] WARN:  $*" >&2; }

# ---------------------------------------------------------------------------
# Safety: confirm extracted/ is gitignored
# ---------------------------------------------------------------------------
if ! grep -q 'spike-stockui/extracted' "${REPO_ROOT}/.gitignore" 2>/dev/null; then
    die "spike-stockui/extracted/ is NOT in .gitignore — add it before extracting!"
fi
log "Confirmed: spike-stockui/extracted/ is gitignored."

# ---------------------------------------------------------------------------
# Create output dir
# ---------------------------------------------------------------------------
mkdir -p "${EXTRACTED}/qt-libs"
mkdir -p "${EXTRACTED}/tslib-libs"
> "${EXTRACTED}/manifest.txt"

record() {
    local file="$1" src="$2"
    local md5
    md5="$(md5sum "${file}" | awk '{print $1}')"
    echo "${md5}  $(basename "${file}")  [from: ${src}]" >> "${EXTRACTED}/manifest.txt"
}

# ---------------------------------------------------------------------------
# STEP 1: firmwareExe from fw-analysis (direct — no loop mount needed)
# ---------------------------------------------------------------------------
FW_EXE="${FW_ANALYSIS_DIR}/software-5.1.4/firmwareExe"
if [ -f "${FW_EXE}" ]; then
    log "Copying firmwareExe from fw-analysis/software-5.1.4/ ..."
    cp "${FW_EXE}" "${EXTRACTED}/firmwareExe"
    chmod a+x "${EXTRACTED}/firmwareExe"
    record "${EXTRACTED}/firmwareExe" "${FW_EXE}"
    log "  firmwareExe: $(du -sh "${EXTRACTED}/firmwareExe" | cut -f1)  $(file "${EXTRACTED}/firmwareExe" | cut -d: -f2 | sed 's/^ //')"
else
    warn "firmwareExe not found at ${FW_EXE} — will try loop mount"
fi

# ---------------------------------------------------------------------------
# STEP 2: env.cfg + ffstartup.cfg from fw-analysis/library-5.1.4/
# ---------------------------------------------------------------------------
LIB_DIR="${FW_ANALYSIS_DIR}/library-5.1.4"
for cfg in env.cfg ffstartup.cfg; do
    src="${LIB_DIR}/${cfg}"
    if [ -f "${src}" ]; then
        cp "${src}" "${EXTRACTED}/${cfg}"
        record "${EXTRACTED}/${cfg}" "${src}"
        log "Copied ${cfg} from fw-analysis/library-5.1.4/"
    else
        warn "${cfg} not found at ${src}"
    fi
done

# ---------------------------------------------------------------------------
# STEP 3: Qt libs + tslib from stock-rootfs.ext4 (requires sudo loop mount)
# ---------------------------------------------------------------------------
MNT_DIR=""
LOOP_DEV=""
cleanup_loop() {
    [ -n "${MNT_DIR}" ] && mountpoint -q "${MNT_DIR}" 2>/dev/null && \
        umount "${MNT_DIR}" 2>/dev/null || true
    [ -n "${LOOP_DEV}" ] && losetup "${LOOP_DEV}" &>/dev/null 2>&1 && \
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    [ -n "${MNT_DIR}" ] && rm -rf "${MNT_DIR}" 2>/dev/null || true
}

if [ "${SKIP_LOOP_MOUNT}" = "1" ]; then
    warn "SKIP_LOOP_MOUNT=1 — skipping loop mount; Qt/tslib libs will not be extracted."
elif [ ! -f "${ROOTFS_IMG}" ]; then
    warn "stock-rootfs.ext4 not found at ${ROOTFS_IMG} — skipping Qt/tslib extraction."
elif [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root — loop mount requires sudo.  Re-run with: sudo $0"
    warn "Skipping Qt/tslib lib extraction."
else
    trap cleanup_loop EXIT INT TERM

    log "Loop-mounting ${ROOTFS_IMG} ..."
    MNT_DIR="$(mktemp -d /tmp/spike-extract-mnt-XXXXXX)"
    LOOP_DEV="$(losetup --find --show "${ROOTFS_IMG}")"
    mount -o ro "${LOOP_DEV}" "${MNT_DIR}"
    log "  mounted at ${MNT_DIR}"

    # firmwareExe from rootfs if not already extracted
    if [ ! -f "${EXTRACTED}/firmwareExe" ]; then
        ROOTFS_EXE="${MNT_DIR}/opt/PROGRAM/software/5.1.4/firmwareExe"
        if [ -f "${ROOTFS_EXE}" ]; then
            log "Copying firmwareExe from rootfs ..."
            cp "${ROOTFS_EXE}" "${EXTRACTED}/firmwareExe"
            chmod a+x "${EXTRACTED}/firmwareExe"
            record "${EXTRACTED}/firmwareExe" "${ROOTFS_EXE}"
        fi
    fi

    # Qt libs: libQtCore.so.4, libQtGui.so.4, libQtNetwork.so.4
    QT_LIB_DIR="${MNT_DIR}/opt/qt-4.8.6/lib"
    if [ -d "${QT_LIB_DIR}" ]; then
        log "Extracting Qt4 libs from rootfs ..."
        for soname in libQtCore.so.4 libQtGui.so.4 libQtNetwork.so.4; do
            # Copy the versioned file that the symlink points to
            found="$(ls "${QT_LIB_DIR}/${soname}"* 2>/dev/null | grep -v '\.so\.4$' | head -1 || true)"
            if [ -n "${found}" ]; then
                cp "${found}" "${EXTRACTED}/qt-libs/"
                # Create the expected symlink
                ln -sf "$(basename "${found}")" "${EXTRACTED}/qt-libs/${soname}" 2>/dev/null || true
                record "${EXTRACTED}/qt-libs/$(basename "${found}")" "${found}"
                log "  ${soname} -> $(basename "${found}")"
            else
                warn "  ${soname} not found in ${QT_LIB_DIR}"
            fi
        done
    else
        warn "Qt lib dir not found: ${QT_LIB_DIR}"
    fi

    # tslib: libts.so.0
    TSLIB_DIR="${MNT_DIR}/opt/tslib-1.12/lib"
    if [ -d "${TSLIB_DIR}" ]; then
        log "Extracting tslib from rootfs ..."
        for soname in libts.so.0; do
            found="$(ls "${TSLIB_DIR}/${soname}"* 2>/dev/null | grep -v '\.so\.0$' | head -1 || true)"
            if [ -n "${found}" ]; then
                cp "${found}" "${EXTRACTED}/tslib-libs/"
                ln -sf "$(basename "${found}")" "${EXTRACTED}/tslib-libs/${soname}" 2>/dev/null || true
                record "${EXTRACTED}/tslib-libs/$(basename "${found}")" "${found}"
                log "  ${soname} -> $(basename "${found}")"
            else
                warn "  ${soname} not found in ${TSLIB_DIR}"
            fi
        done
    else
        warn "tslib dir not found: ${TSLIB_DIR}"
    fi

    # Unmount
    umount "${MNT_DIR}" 2>/dev/null || true
    losetup -d "${LOOP_DEV}" 2>/dev/null || true
    rm -rf "${MNT_DIR}" 2>/dev/null || true
    MNT_DIR=""
    LOOP_DEV=""
    trap - EXIT INT TERM
    log "Loop unmounted."
fi

# ---------------------------------------------------------------------------
# STEP 4: Verify + print summary
# ---------------------------------------------------------------------------
log ""
log "=== Extraction complete ==="
log "Contents of ${EXTRACTED}:"
find "${EXTRACTED}" -type f | sort | while read -r f; do
    echo "  $(du -sh "${f}" | cut -f1)  ${f#${EXTRACTED}/}"
done

if [ -f "${EXTRACTED}/firmwareExe" ]; then
    log ""
    log "firmwareExe: $(file "${EXTRACTED}/firmwareExe" | cut -d: -f2 | sed 's/^ //')"
    log "NEEDED libs: $(readelf -d "${EXTRACTED}/firmwareExe" 2>/dev/null | grep NEEDED | awk '{print $5}' | tr -d '[]' | tr '\n' ' ')"
fi

log ""
log "Manifest:"
cat "${EXTRACTED}/manifest.txt" | sed 's/^/  /'

log ""
log "IMPORTANT: ${EXTRACTED}/ is gitignored — do NOT commit blobs."
