#!/usr/bin/env bash
# =============================================================================
# build-live-usb.sh — assemble a ReForge LIVE USB image (run-from-USB, no install).
#
# Produces a FAT image holding: the live launcher, f2fs.ko (built against the
# stock BSP), and the ReForge rootfs as an F2FS image. The stock FlashForge
# auto_run.sh picks up the launcher via its `/mnt/flashforge_init.sh` hook (see
# docs/specs/2026-06-02-reforge-live-mode.md); the launcher insmods f2fs.ko and
# mounts the F2FS rootfs. dd the result to a USB stick; boot the printer with it
# inserted; pull it + reboot to return to pristine stock. NOTHING touches eMMC.
#
# Fully ROOTLESS (no sudo): mkfs.f2fs + sload.f2fs for the rootfs, mkfs.vfat +
# mcopy (mtools) for the FAT image — no loop mounts.
#
# Usage:   tools/release/build-live-usb.sh
#   VER       version tag (default: packaging/VERSION)
#   DIST_DIR  output dir (default: packaging/dist)
# Output:   <DIST_DIR>/reforge-live-<VER>.img   (dd to a USB stick)
# Needs:    f2fs-tools, mkfs.vfat (dosfstools), mcopy/mmd (mtools), modules/f2fs-bsp
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

# --- 1. the ReForge rootfs as an F2FS image (the live chroot root) ------------
# F2FS is flash-friendly; the stock 5.4.61 kernel has no built-in F2FS, so we also
# ship f2fs.ko (built against the stock BSP, matching vermagic) and the launcher
# insmods it. Built rootlessly: mkfs.f2fs + sload.f2fs (loads files, no mount).
command -v mkfs.f2fs >/dev/null || die "mkfs.f2fs not installed (f2fs-tools)"
command -v sload.f2fs >/dev/null || die "sload.f2fs not installed (f2fs-tools)"
F2FS_KO="${REPO_ROOT}/modules/f2fs-bsp/dist/f2fs.ko"
[ -f "${F2FS_KO}" ] || F2FS_KO="${REPO_ROOT}/modules/f2fs-bsp/build/f2fs.ko"
if [ ! -f "${F2FS_KO}" ]; then
    log "f2fs.ko missing — building it (modules/f2fs-bsp/build.sh) ..."
    "${REPO_ROOT}/modules/f2fs-bsp/build.sh" >/dev/null 2>&1 || die "f2fs.ko build failed — see modules/f2fs-bsp/build.sh"
fi
VM="$(strings "${F2FS_KO}" | grep -m1 '^vermagic=' || true)"
case "${VM}" in
    *'5.4.61 SMP preempt mod_unload ARMv7 p2v8'*) : ;;
    *) die "f2fs.ko vermagic mismatch (${VM}) — must be the device's 5.4.61 build" ;;
esac

log "staging rootfs (${ROOTFS_TAR}) ..."
STAGE="${WORK}/root"; mkdir -p "${STAGE}"
tar -C "${STAGE}" -xf "${ROOTFS_TAR}"
[ -x "${STAGE}/mod/start.sh" ] || die "rootfs has no /mod/start.sh — wrong/old build"

LIVE_F2FS="${WORK}/reforge-live.f2fs"
log "baking reforge-live.f2fs via mkfs.f2fs + sload.f2fs (rootless) ..."
truncate -s 1843M "${LIVE_F2FS}"
mkfs.f2fs -q -f -l reforge-live "${LIVE_F2FS}" >/dev/null
sload.f2fs -f "${STAGE}" "${LIVE_F2FS}" >/dev/null 2>&1

# --- 2. the FAT carrier the stock firmware mounts -----------------------------
# Holds the launcher, f2fs.ko, and the F2FS rootfs image (real data under 1 GB).
log "creating FAT image ${OUT} ..."
rm -f "${OUT}"
truncate -s 2300M "${OUT}"
mkfs.vfat -F 32 -n REFORGE-LIVE "${OUT}" >/dev/null

log "copying launcher + f2fs.ko + rootfs image onto the FAT image (mcopy) ..."
mcopy -i "${OUT}" "${LAUNCHER}" ::flashforge_init.sh
mcopy -i "${OUT}" "${F2FS_KO}"  ::f2fs.ko
mcopy -i "${OUT}" "${LIVE_F2FS}" ::reforge-live.f2fs

log "verifying FAT contents ..."
mdir -i "${OUT}" :: | sed 's/^/  /'

log "done: ${OUT}"
log "  Flash:  dd if=${OUT} of=/dev/sdX bs=4M conv=fsync   (X = your USB stick)"
log "  Then boot the printer with the stick in; remove it + reboot for stock."
