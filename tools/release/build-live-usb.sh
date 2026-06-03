#!/usr/bin/env bash
# =============================================================================
# build-live-usb.sh — assemble a ReForge LIVE USB payload (run-from-USB, no install).
#
# Produces a .tar.gz holding (at the archive root): the live launcher, three BSP
# kernel modules (loop+crc32+f2fs), and the ReForge rootfs as an F2FS image. NO dd
# and no dedicated stick needed — the stock FlashForge auto_run.sh scans ANY FAT USB
# for /flashforge_init.sh (see docs/live-mode.md), so the
# trial is just: extract this tarball onto the root of a FAT32 stick, insert it, and
# power on. The launcher insmods the three modules and loop-mounts the F2FS rootfs.
# Pull the stick + reboot to return to pristine stock. NOTHING touches eMMC.
#
# Fully ROOTLESS (no sudo): mkfs.f2fs + sload.f2fs bake the rootfs image, tar+gzip
# pack the payload — no loop mounts, no FAT tooling.
#
# Usage:   tools/release/build-live-usb.sh
#   VER       version tag (default: packaging/VERSION)
#   DIST_DIR  output dir (default: packaging/dist)
# Output:   <DIST_DIR>/reforge-live-<VER>.tar.gz   (extract onto a FAT32 USB root)
# Needs:    f2fs-tools (mkfs.f2fs/sload.f2fs), tar, gzip, modules/f2fs-bsp
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGING_DIR="${REPO_ROOT}/packaging"
ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar"
LAUNCHER="${PACKAGING_DIR}/live/flashforge_init.sh"
NETUP="${PACKAGING_DIR}/live/net-up.sh"

VER="${VER:-$(cat "${PACKAGING_DIR}/VERSION")}"
DIST_DIR="${DIST_DIR:-${PACKAGING_DIR}/dist}"
OUT="${DIST_DIR}/reforge-live-${VER}.tar.gz"

log() { echo "[build-live-usb] $*"; }
die() { echo "[build-live-usb] ERROR: $*" >&2; exit 1; }

[ -f "${ROOTFS_TAR}" ] || die "rootfs.tar missing — run 'make rootfs' first (${ROOTFS_TAR})"
[ -f "${LAUNCHER}" ]   || die "live launcher missing: ${LAUNCHER}"
[ -f "${NETUP}" ]      || die "net-up.sh missing: ${NETUP}"
command -v tar >/dev/null || die "tar not installed"
command -v gzip >/dev/null || die "gzip not installed"

mkdir -p "${DIST_DIR}"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# --- 1. the ReForge rootfs as an F2FS image (the live chroot root) ------------
# F2FS is flash-friendly; the stock 5.4.61 kernel has no built-in F2FS, so we also
# ship f2fs.ko (built against the stock BSP, matching vermagic) and the launcher
# insmods it. Built rootlessly: mkfs.f2fs + sload.f2fs (loads files, no mount).
command -v mkfs.f2fs >/dev/null || die "mkfs.f2fs not installed (f2fs-tools)"
command -v sload.f2fs >/dev/null || die "sload.f2fs not installed (f2fs-tools)"
# Three modules the stock kernel lacks (loop to loop-mount the image, crc32 for
# F2FS's mount checksum, f2fs itself). Prefer the committed dist/ copies; build
# them if absent. All must match the device vermagic.
MODBASE="${REPO_ROOT}/modules/f2fs-bsp"
KOS="loop.ko crc32_generic.ko f2fs.ko"
need_build=0
for ko in ${KOS}; do [ -f "${MODBASE}/dist/${ko}" ] || [ -f "${MODBASE}/build/${ko}" ] || need_build=1; done
if [ "${need_build}" -eq 1 ]; then
    log "live-mode modules missing — building (modules/f2fs-bsp/build.sh) ..."
    "${MODBASE}/build.sh" >/dev/null 2>&1 || die "module build failed — see modules/f2fs-bsp/build.sh"
fi
ko_path() { [ -f "${MODBASE}/dist/$1" ] && echo "${MODBASE}/dist/$1" || echo "${MODBASE}/build/$1"; }
for ko in ${KOS}; do
    p="$(ko_path "${ko}")"
    VM="$(strings "${p}" | grep -m1 '^vermagic=' || true)"
    case "${VM}" in
        *'5.4.61 SMP preempt mod_unload ARMv7 p2v8'*) : ;;
        *) die "${ko} vermagic mismatch (${VM}) — must be the device's 5.4.61 build" ;;
    esac
done

log "staging rootfs (${ROOTFS_TAR}) ..."
STAGE="${WORK}/root"; mkdir -p "${STAGE}"
tar -C "${STAGE}" -xf "${ROOTFS_TAR}"
[ -x "${STAGE}/mod/start.sh" ] || die "rootfs has no /mod/start.sh — wrong/old build"

LIVE_F2FS="${WORK}/reforge-live.f2fs"
# Size the F2FS image to the rootfs + slack, NOT a fixed 1.8 GB. FAT (the USB) has
# no sparse-file support, so the image is written byte-for-byte onto the stick —
# keeping it small makes the trial extract fast and the footprint honest. Runtime
# state (klippy logs, moonraker DB, zram) goes to the tmpfs /data, not here; the
# image only needs the rootfs + headroom for an OTA update. Override via F2FS_SIZE.
ROOTFS_MB=$(( ($(stat -c%s "${ROOTFS_TAR}") + 1048575) / 1048576 ))
F2FS_SIZE="${F2FS_SIZE:-$(( ROOTFS_MB + 384 ))M}"   # rootfs + 384 MB slack
log "baking reforge-live.f2fs (${F2FS_SIZE}) via mkfs.f2fs + sload.f2fs (rootless) ..."
truncate -s "${F2FS_SIZE}" "${LIVE_F2FS}"
mkfs.f2fs -q -f -l reforge-live "${LIVE_F2FS}" >/dev/null
sload.f2fs -f "${STAGE}" "${LIVE_F2FS}" >/dev/null 2>&1 \
    || die "sload.f2fs failed — F2FS_SIZE=${F2FS_SIZE} too small for the rootfs?"
# integrity: the loaded image must fsck clean (catches a silently-truncated load).
if command -v fsck.f2fs >/dev/null; then
    fsck.f2fs "${LIVE_F2FS}" >/dev/null 2>&1 || die "reforge-live.f2fs failed fsck after sload"
fi

# --- 2. the payload tarball the user extracts onto a FAT USB -------------------
# No dd / no dedicated stick needed: the stock auto_run.sh scans ANY FAT USB for
# /flashforge_init.sh, so the trial is just "extract these files onto the root of a
# FAT32 stick". The tarball holds the launcher + 3 modules + the F2FS rootfs image,
# all at the archive root, so extracting onto the USB root puts them where the
# launcher (and auto_run) expect them.
log "assembling payload tarball ${OUT} ..."
PAYLOAD="${WORK}/payload"; mkdir -p "${PAYLOAD}"
# symlink the inputs in (tar -h dereferences) — avoids copying the ~2 GB image.
ln -sf "${LAUNCHER}"  "${PAYLOAD}/flashforge_init.sh"
ln -sf "${NETUP}"     "${PAYLOAD}/net-up.sh"
ln -sf "${LIVE_F2FS}" "${PAYLOAD}/reforge-live.f2fs"
for ko in ${KOS}; do ln -sf "$(ko_path "${ko}")" "${PAYLOAD}/${ko}"; done
rm -f "${OUT}"
tar -C "${PAYLOAD}" -czhf "${OUT}" flashforge_init.sh net-up.sh ${KOS} reforge-live.f2fs

log "done: ${OUT} ($(du -h "${OUT}" | cut -f1))"
log "  Contents:"; tar -tzf "${OUT}" | sed 's/^/    /'
log "  Trial:  mount a FAT32 USB stick, then:"
log "          tar xzf ${OUT} -C /path/to/usb/   (files land at the USB root)"
log "          Insert the stick, power on the printer -> ReForge runs from USB."
log "          Pull the stick + reboot to return to pristine stock. eMMC is never touched."
