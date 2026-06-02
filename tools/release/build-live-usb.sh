#!/usr/bin/env bash
# =============================================================================
# build-live-usb.sh — assemble a ReForge LIVE USB image (run-from-USB, no install).
#
# Produces a FAT image holding the live launcher + the ReForge rootfs as an ext4
# image, which the stock FlashForge auto_run.sh picks up via its
# `/mnt/flashforge_init.sh` hook (see docs/specs/2026-06-02-reforge-live-mode.md).
# dd the result to a USB stick; boot the printer with it inserted; pull it +
# reboot to return to pristine stock. NOTHING is written to eMMC.
#
# Fully ROOTLESS (no sudo): mke2fs -d for the ext4, mkfs.vfat + mcopy (mtools)
# for the FAT image — no loop mounts.
#
# Usage:   tools/release/build-live-usb.sh
#   VER       version tag (default: packaging/VERSION)
#   DIST_DIR  output dir (default: packaging/dist)
# Output:   <DIST_DIR>/reforge-live-<VER>.img   (dd to a USB stick)
# Needs:    mke2fs (e2fsprogs), mkfs.vfat (dosfstools), mcopy/mmd (mtools)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGING_DIR="${REPO_ROOT}/packaging"
ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar"
LAUNCHER="${PACKAGING_DIR}/live/flashforge_init.sh"

VER="${VER:-$(cat "${PACKAGING_DIR}/VERSION")}"
DIST_DIR="${DIST_DIR:-${PACKAGING_DIR}/dist}"
OUT="${DIST_DIR}/reforge-live-${VER}.img"

log() { echo "[build-live-usb] $*"; }
die() { echo "[build-live-usb] ERROR: $*" >&2; exit 1; }

[ -f "${ROOTFS_TAR}" ] || die "rootfs.tar missing — run 'make rootfs' first (${ROOTFS_TAR})"
[ -f "${LAUNCHER}" ]   || die "live launcher missing: ${LAUNCHER}"
command -v mke2fs   >/dev/null || die "mke2fs not installed (e2fsprogs)"
command -v mkfs.vfat >/dev/null || die "mkfs.vfat not installed (dosfstools)"
command -v mcopy    >/dev/null || die "mcopy not installed (mtools)"

mkdir -p "${DIST_DIR}"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# --- 1. the ReForge rootfs as an ext4 image (the live chroot root) ------------
log "staging rootfs (${ROOTFS_TAR}) ..."
STAGE="${WORK}/root"; mkdir -p "${STAGE}"
tar -C "${STAGE}" -xf "${ROOTFS_TAR}"
[ -x "${STAGE}/mod/start.sh" ] || die "rootfs has no /mod/start.sh — wrong/old build"

LIVE_EXT4="${WORK}/reforge-live.ext4"
log "baking reforge-live.ext4 via mke2fs -d (rootless) ..."
mke2fs -q -F -t ext4 -L "reforge-live" -d "${STAGE}" "${LIVE_EXT4}" 1843M

# --- 2. the FAT carrier the stock firmware mounts -----------------------------
# Sized to hold the ext4 image (real data well under 1 GB) + the launcher.
log "creating FAT image ${OUT} ..."
rm -f "${OUT}"
truncate -s 2300M "${OUT}"
mkfs.vfat -F 32 -n REFORGE-LIVE "${OUT}" >/dev/null

log "copying launcher + rootfs image onto the FAT image (mcopy) ..."
mcopy -i "${OUT}" "${LAUNCHER}" ::flashforge_init.sh
mcopy -i "${OUT}" "${LIVE_EXT4}" ::reforge-live.ext4

log "verifying FAT contents ..."
mdir -i "${OUT}" :: | sed 's/^/  /'

log "done: ${OUT}"
log "  Flash:  dd if=${OUT} of=/dev/sdX bs=4M conv=fsync   (X = your USB stick)"
log "  Then boot the printer with the stick in; remove it + reboot for stock."
