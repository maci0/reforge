#!/usr/bin/env bash
# =============================================================================
# build-live-usb.sh — assemble a ReForge LIVE USB disk image (run-from-USB, no install).
#
# Produces a single dd-able disk image: an MBR with two partitions —
#   p1  vfat (~64 MiB)  — the launcher hook the stock auto_run picks up:
#                         /flashforge_init.sh + /net-up.sh + the two BSP modules
#                         (/crc32_generic.ko + /f2fs.ko)
#   p2  f2fs            — the ReForge rootfs as a real block device (the chroot
#                         root), labelled "reforge-live" so the launcher finds it
#                         by label.
#
# This replaces the OLD single-FAT layout that loop-mounted a reforge-live.f2fs
# image file from inside a FAT filesystem. The new layout:
#   * needs no loop.ko (the rootfs is a real partition, not a file)
#   * is no longer capped by FAT's 4 GiB file size limit on the rootfs
#   * lets F2FS DISCARD/TRIM actually work (real block device, not loop-on-FAT)
#
# Cost: the user `dd`'s a partitioned disk image onto a stick, instead of
# "extract a tarball onto any FAT USB" — the price for losing the loopback
# fragility. balenaEtcher works cross-platform; on Linux `xzcat | sudo dd`.
#
# Fully ROOTLESS (no sudo):
#   * sfdisk writes the MBR partition table to a regular file (no losetup).
#   * mtools (mformat + mcopy) builds the FAT partition into a separate file.
#   * mkfs.f2fs + sload.f2fs build the F2FS partition into a separate file.
#   * dd splices each partition image into the disk image at the right offset.
#
# Usage:   tools/release/build-live-usb.sh
#   VER       version tag (default: packaging/VERSION)
#   DIST_DIR  output dir (default: packaging/dist)
# Output:   <DIST_DIR>/reforge-live-<VER>.img.gz
#           write with: zcat reforge-live-<VER>.img.gz | sudo dd of=/dev/sdX bs=4M status=progress
#           (or open with balenaEtcher / Rufus / GNOME Disks "Restore Disk Image")
# Needs:    sfdisk (util-linux), mtools (mformat/mcopy), f2fs-tools
#           (mkfs.f2fs/sload.f2fs), gzip, modules/f2fs-bsp
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGING_DIR="${REPO_ROOT}/packaging"
ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar"
LAUNCHER="${PACKAGING_DIR}/live/flashforge_init.sh"
NETUP="${PACKAGING_DIR}/live/net-up.sh"

VER="${VER:-$(cat "${PACKAGING_DIR}/VERSION")}"
DIST_DIR="${DIST_DIR:-${PACKAGING_DIR}/dist}"
OUT="${DIST_DIR}/reforge-live-${VER}.img.gz"
RAW="${DIST_DIR}/reforge-live-${VER}.img"

# Partition geometry. p1 holds the launcher + 2 modules (~600 KB total) but FAT32
# needs ~32 MiB minimum to be valid in practice, so we give it 64 MiB. p2 is sized
# to the rootfs + 384 MiB slack (matches the old F2FS_SIZE rule). 1 MiB alignment
# is standard for modern devices.
ALIGN_MIB=1
P1_MIB="${P1_MIB:-64}"           # vfat (launcher + modules)
P2_SLACK_MIB="${P2_SLACK_MIB:-384}"
F2FS_LABEL="${F2FS_LABEL:-reforge-live}"

log() { echo "[build-live-usb] $*"; }
die() { echo "[build-live-usb] ERROR: $*" >&2; exit 1; }

[ -f "${ROOTFS_TAR}" ] || die "rootfs.tar missing — run 'make rootfs' first (${ROOTFS_TAR})"
[ -f "${LAUNCHER}" ]   || die "live launcher missing: ${LAUNCHER}"
[ -f "${NETUP}" ]      || die "net-up.sh missing: ${NETUP}"
for t in sfdisk mformat mcopy mkfs.f2fs sload.f2fs gzip dd; do
    command -v "$t" >/dev/null || die "$t not installed"
done

mkdir -p "${DIST_DIR}"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# --- 1. stage the rootfs (for p2) ---------------------------------------------
log "staging rootfs (${ROOTFS_TAR}) ..."
STAGE="${WORK}/root"; mkdir -p "${STAGE}"
tar -C "${STAGE}" -xf "${ROOTFS_TAR}"
[ -x "${STAGE}/mod/start.sh" ] || die "rootfs has no /mod/start.sh — wrong/old build"

# --- 2. resolve & vermagic-verify the BSP modules (for p1) --------------------
MODBASE="${REPO_ROOT}/modules/f2fs-bsp"
KOS="crc32_generic.ko f2fs.ko"
WANT_VM='5.4.61 SMP preempt mod_unload ARMv7 p2v8'
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
        *"${WANT_VM}"*) : ;;
        *) die "${ko} vermagic mismatch (${VM}) — must be the device's 5.4.61 build" ;;
    esac
done

# --- 3. build the p2 F2FS partition image -------------------------------------
LIVE_F2FS="${WORK}/p2.f2fs"
ROOTFS_MB=$(( ($(stat -c%s "${ROOTFS_TAR}") + 1048575) / 1048576 ))
P2_MIB="${P2_MIB:-$(( ROOTFS_MB + P2_SLACK_MIB ))}"
log "baking p2 (f2fs, ${P2_MIB} MiB, label=${F2FS_LABEL}) via mkfs.f2fs + sload.f2fs (rootless) ..."
truncate -s "${P2_MIB}M" "${LIVE_F2FS}"
mkfs.f2fs -q -f -l "${F2FS_LABEL}" "${LIVE_F2FS}" >/dev/null
sload.f2fs -f "${STAGE}" "${LIVE_F2FS}" >/dev/null 2>&1 \
    || die "sload.f2fs failed — P2_MIB=${P2_MIB} too small for the rootfs?"
if command -v fsck.f2fs >/dev/null; then
    fsck.f2fs "${LIVE_F2FS}" >/dev/null 2>&1 || die "p2 F2FS failed fsck after sload"
fi

# --- 4. build the p1 FAT32 partition image ------------------------------------
# mtools: rootless FAT manipulation (mformat formats a file, mcopy writes into it).
FAT_IMG="${WORK}/p1.fat"
log "baking p1 (vfat, ${P1_MIB} MiB) via mformat + mcopy (rootless) ..."
truncate -s "${P1_MIB}M" "${FAT_IMG}"
# -i: operate on file. -F: force FAT32. -v: label REFORGE_LIV (FAT label max 11 chars).
mformat -i "${FAT_IMG}" -F -v "REFORGE_LIV" :: >/dev/null
# Copy launcher + net-up + the two modules into the FAT root.
mcopy -i "${FAT_IMG}" "${LAUNCHER}" "::flashforge_init.sh"
mcopy -i "${FAT_IMG}" "${NETUP}"    "::net-up.sh"
for ko in ${KOS}; do
    mcopy -i "${FAT_IMG}" "$(ko_path "${ko}")" "::${ko}"
done
# Sanity: list what's in the FAT root.
mdir -i "${FAT_IMG}" :: > "${WORK}/p1-listing.txt" 2>/dev/null || true

# --- 5. compose the disk image: MBR + p1 + p2 ---------------------------------
# Layout (LBA, 512 B sectors):
#   [0..1MiB)        MBR + alignment slack
#   [1MiB..1+P1MiB)  p1 vfat
#   [1+P1MiB..end)   p2 f2fs
SECT=512
MIB_SECT=$(( 1024 * 1024 / SECT ))   # 2048
P1_START=$(( ALIGN_MIB * MIB_SECT ))
P1_SIZE=$((  P1_MIB    * MIB_SECT ))
P2_START=$(( P1_START + P1_SIZE ))
P2_SIZE=$((  P2_MIB    * MIB_SECT ))
DISK_MIB=$(( ALIGN_MIB + P1_MIB + P2_MIB ))

log "composing disk image (${DISK_MIB} MiB total: 1+${P1_MIB}+${P2_MIB}) ..."
rm -f "${RAW}"
truncate -s "${DISK_MIB}M" "${RAW}"
# sfdisk writes an MBR directly to a regular file (no losetup). Partition types:
#   0c = W95 FAT32 (LBA) — stock auto_run.sh probes vfat, this is what it expects
#   83 = Linux            — there is no standard MBR id for F2FS; 83 is conventional
sfdisk --no-tell-kernel --no-reread "${RAW}" >/dev/null <<EOF
label: dos
unit: sectors
start=${P1_START}, size=${P1_SIZE}, type=0c, bootable
start=${P2_START}, size=${P2_SIZE}, type=83
EOF

# Splice each partition image in at its LBA offset.
dd if="${FAT_IMG}"  of="${RAW}" bs="${SECT}" seek="${P1_START}" conv=notrunc status=none
dd if="${LIVE_F2FS}" of="${RAW}" bs="${SECT}" seek="${P2_START}" conv=notrunc status=none

# Drop the partition images (~rootfs size) before gzipping to keep peak disk use low.
rm -f "${FAT_IMG}" "${LIVE_F2FS}"

# --- 6. gzip + report ---------------------------------------------------------
log "gzipping -> ${OUT} ..."
rm -f "${OUT}"
gzip -c "${RAW}" > "${OUT}"
RAW_SIZE="$(du -h "${RAW}" | cut -f1)"
GZ_SIZE="$(du -h "${OUT}" | cut -f1)"
rm -f "${RAW}"

log "done:"
log "  raw : ${RAW_SIZE} (${DISK_MIB} MiB)"
log "  .gz : ${GZ_SIZE} -> ${OUT}"
log ""
log "Partition table:"
sfdisk -d "${OUT%.gz}" 2>/dev/null || true   # already deleted; show what we wrote
log "  p1  vfat  ${P1_MIB} MiB  /flashforge_init.sh + /net-up.sh + /crc32_generic.ko + /f2fs.ko"
log "  p2  f2fs  ${P2_MIB} MiB  label=${F2FS_LABEL}  the ReForge rootfs"
log ""
log "Flash to a USB stick (≥ ${DISK_MIB} MiB):"
log "  Linux:        zcat ${OUT} | sudo dd of=/dev/sdX bs=4M status=progress && sync"
log "  cross-plat:   open ${OUT} in balenaEtcher (https://etcher.balena.io)"
log "Then insert the stick + power on the printer. Pull stick + reboot = back to stock."
