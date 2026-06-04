#!/usr/bin/env bash
# =============================================================================
# live-mode-test.sh — prove ReForge LIVE mode writes NOTHING to the eMMC.
#
# Boots the live launcher (packaging/live/flashforge_init.sh) the way the stock
# auto_run.sh would, with three disks:
#   vda  host/stock side (boots straight into the launcher via init=)
#   vdb  the live ReForge rootfs image (the "USB" payload)
#   vdc  a stand-in for the eMMC /data partition (mmcblk0p7) — the install target
# The launcher loop-mounts vdb, gives the chroot a tmpfs /data, and runs the
# ReForge stack. It must NEVER touch vdc.
#
# ASSERTS:  (1) the ReForge stack comes up from the USB image;
#           (2) vdc (the eMMC /data) is BYTE-IDENTICAL before and after the boot.
#
# Fully ROOTLESS (no sudo): images via mke2fs -d, unprivileged qemu.
# Usage:    tests/qemu-harness/live-mode-test.sh        # NO sudo
# Needs:    qemu-system-arm, mke2fs (e2fsprogs), sha256sum, build/zImage,
#           build/output/images/rootfs.tar[.xz]
# Exit:     0 = PASS, 1 = FAIL, 0 = SKIP (missing prereqs)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
LAUNCHER="${REPO_ROOT}/packaging/live/flashforge_init.sh"

HOST_IMG="${BUILD_DIR}/live-host.ext4"   # vda
LIVE_IMG="${BUILD_DIR}/live-usb.ext4"    # vdb (the "USB" rootfs)
EMMC_IMG="${BUILD_DIR}/live-emmc.ext4"   # vdc (the eMMC /data to protect)
SER="${BUILD_DIR}/live-mode-serial.log"
SETTLE="${SETTLE:-70}"

log() { echo "[live-mode] $*"; }
die() { echo "[live-mode] FAIL: $*" >&2; exit 1; }

ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar}"
[ -f "${ROOTFS_TAR}" ] || ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar.xz"
[ -f "${ZIMAGE}" ]     || { echo "[live-mode] SKIP: no ${ZIMAGE} (make qemu-kernel)"; exit 0; }
[ -f "${ROOTFS_TAR}" ] || { echo "[live-mode] SKIP: no rootfs.tar (make rootfs)"; exit 0; }
[ -f "${LAUNCHER}" ]   || die "live launcher missing: ${LAUNCHER}"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v mke2fs >/dev/null || die "mke2fs not installed"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# --- 1. the live ReForge rootfs image (vdb) -----------------------------------
log "staging the ReForge rootfs (the USB payload) ..."
USBSTAGE="${WORK}/usb"; mkdir -p "${USBSTAGE}"
tar -C "${USBSTAGE}" -xf "${ROOTFS_TAR}"
[ -x "${USBSTAGE}/mod/start.sh" ] || die "rootfs has no /mod/start.sh — wrong/old build"
# ext4 image: the gate proves the zero-eMMC-write invariant, which is
# filesystem-agnostic, and the current virt test kernel has no F2FS (its rebuild
# needs a non-vendored mainline tarball). The real live USB uses F2FS — its
# mountability is verified on actual hardware (f2fs.ko insmod), not here. The
# launcher tries f2fs first and falls back to this ext4 image.
rm -f "${LIVE_IMG}"; mke2fs -q -F -t ext4 -L live-usb -d "${USBSTAGE}" "${LIVE_IMG}" 1843M

# --- 2. the host (vda): boots straight into the launcher via init= ------------
# Reuse the same rootfs (it has busybox mount/chroot) but a custom init runs ONLY
# the launcher, so the host's own ReForge stack does not start.
log "staging the host image (init -> live launcher) ..."
HOSTSTAGE="${WORK}/host"; mkdir -p "${HOSTSTAGE}"
tar -C "${HOSTSTAGE}" -xf "${ROOTFS_TAR}"
install -m 0755 "${LAUNCHER}" "${HOSTSTAGE}/flashforge_init.sh"
cat > "${HOSTSTAGE}/sbin/reforge-live-init" <<'EOF'
#!/bin/sh
# qemu live-mode gate init: set up just enough, then run the live launcher with
# the USB rootfs on /dev/vdb. The launcher chroots in and runs the stack.
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null
mkdir -p /mnt
echo "[live-gate] starting live launcher (F2FS_DEV=/dev/vdb, eMMC=/dev/vdc untouched)"
USB_MNT=/mnt F2FS_DEV=/dev/vdb SCREEN_MODE=HEADLESS /flashforge_init.sh AD5MPro 0024
EOF
chmod 0755 "${HOSTSTAGE}/sbin/reforge-live-init"
rm -f "${HOST_IMG}"; mke2fs -q -F -t ext4 -L live-host -d "${HOSTSTAGE}" "${HOST_IMG}" 1843M

# --- 3. the eMMC /data stand-in (vdc) — must stay byte-identical ---------------
log "building the eMMC /data stand-in (vdc) + recording its checksum ..."
DATASTAGE="${WORK}/data"; mkdir -p "${DATASTAGE}/printer_data"
echo "this is the printer's eMMC /data — live mode must NOT write it" \
    > "${DATASTAGE}/DO-NOT-TOUCH"
rm -f "${EMMC_IMG}"; mke2fs -q -F -t ext4 -L emmc-data -d "${DATASTAGE}" "${EMMC_IMG}" 128M
EMMC_BEFORE="$(sha256sum "${EMMC_IMG}" | cut -d' ' -f1)"
log "  eMMC sha256 (before): ${EMMC_BEFORE}"

# --- 4. boot (unprivileged): vda host, vdb live USB, vdc eMMC /data -----------
rm -f "${SER}"
log "booting (settle=${SETTLE}s, no sudo) — vda=host vdb=live-usb vdc=eMMC/data ..."
qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -smp 2 -m 256 \
    -kernel "${ZIMAGE}" \
    -append "root=/dev/vda rw console=ttyAMA0 loglevel=4 init=/sbin/reforge-live-init panic=1" \
    -drive "file=${HOST_IMG},if=virtio,format=raw" \
    -drive "file=${LIVE_IMG},if=virtio,format=raw" \
    -drive "file=${EMMC_IMG},if=virtio,format=raw" \
    -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
    -nographic > "${SER}" 2>&1 &
QP=$!
trap 'kill -9 "${QP}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT
sleep "${SETTLE}"
kill -9 "${QP}" 2>/dev/null || true
trap 'rm -rf "${WORK}"' EXIT

# --- 5. verdict ---------------------------------------------------------------
EMMC_AFTER="$(sha256sum "${EMMC_IMG}" | cut -d' ' -f1)"
log "  eMMC sha256 (after):  ${EMMC_AFTER}"

STACK_UP=0
grep -qiE 'Starting moonraker|Starting klipper|live mode — services up|reforge-ok' "${SER}" 2>/dev/null && STACK_UP=1

echo ""
echo "========================= LIVE MODE GATE ========================="
if [ "${EMMC_BEFORE}" = "${EMMC_AFTER}" ]; then
    echo "  [PASS] eMMC /data is BYTE-IDENTICAL — live mode wrote nothing to eMMC"
else
    echo "  [FAIL] eMMC /data CHANGED — live mode wrote to the eMMC!"
fi
if [ "${STACK_UP}" -eq 1 ]; then
    echo "  [PASS] the ReForge stack came up from the USB image"
else
    echo "  [WARN] did not see the ReForge stack start in the serial (see ${SER})"
fi
echo "  serial: ${SER}"
echo "================================================================="

[ "${EMMC_BEFORE}" = "${EMMC_AFTER}" ] || die "eMMC was modified — NOT brick-safe"
[ "${STACK_UP}" -eq 1 ] || die "ReForge stack did not start from USB"
log "PASS: live mode booted the stack from USB and left the eMMC untouched."
