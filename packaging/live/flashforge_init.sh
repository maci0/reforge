#!/bin/sh
# =============================================================================
# ReForge LIVE launcher — run ReForge from a USB stick, writing NOTHING to eMMC.
#
# The stock FlashForge auto_run.sh runs any `flashforge_init.sh` found at the USB
# root, directly from /mnt, on every boot:
#     /mnt/flashforge_init.sh <MACHINE> <PID>
#     if [ $? -eq 0 ]; then umount /mnt; sleep 100000; fi
# So we mirror reforge-boot — but root the chroot on the USB's reforge-live.ext4
# and give it a **tmpfs /data** instead of binding the eMMC (mmcblk0p7). We then
# block forever, so the stock flow never reaches `umount /mnt` and never installs
# or launches the stock UI. The eMMC is never touched: pull the USB + reboot →
# pristine stock.
#
# Layout on the FAT USB:  /flashforge_init.sh  (this)  +  /reforge-live.ext4
# =============================================================================
set -u

LIVE_LOG=/dev/console
log() { echo "[reforge-live] $*" > "${LIVE_LOG}" 2>&1; }

USB_MNT="${USB_MNT:-/mnt}"                 # where stock mounted the FAT USB
LIVE_IMG="${LIVE_IMG:-${USB_MNT}/reforge-live.ext4}"
ROOT="${REFORGE_LIVE_ROOT:-/tmp/.reforge-live}"   # chroot root (/tmp is tmpfs)
DATA="${REFORGE_LIVE_DATA:-/tmp/.reforge-data}"   # writable /data -> tmpfs

log "starting (img=${LIVE_IMG})"
# -e, not -f: LIVE_IMG is a regular file on the FAT USB, but may be a raw block
# device (e.g. the qemu zero-write gate presents the rootfs as /dev/vdb).
[ -e "${LIVE_IMG}" ] || { log "ERROR: ${LIVE_IMG} not found on USB"; exit 1; }

mkdir -p "${ROOT}" "${DATA}"

# Mount the ReForge rootfs image (the chroot root). A file on the FAT USB needs
# a loop device; a raw block device (e.g. the qemu zero-write gate) mounts directly.
if [ -b "${LIVE_IMG}" ]; then
    mount -o rw "${LIVE_IMG}" "${ROOT}" 2>/dev/null || { log "ERROR: cannot mount ${LIVE_IMG}"; exit 1; }
elif ! mount -o loop,rw "${LIVE_IMG}" "${ROOT}" 2>/dev/null; then
    log "ERROR: cannot loop-mount ${LIVE_IMG}"
    exit 1
fi
[ -x "${ROOT}/mod/start.sh" ] || { log "ERROR: ${ROOT}/mod/start.sh missing — bad image"; exit 1; }

# Chroot filesystems (mirrors reforge-boot) — but /data is tmpfs, NOT the eMMC.
for d in proc sys dev run tmp data; do mkdir -p "${ROOT}/${d}"; done
mount -t proc  proc  "${ROOT}/proc"  2>/dev/null
mount --rbind  /sys  "${ROOT}/sys"   2>/dev/null
mount --rbind  /dev  "${ROOT}/dev"   2>/dev/null
mount --bind   /run  "${ROOT}/run"   2>/dev/null
mount -t tmpfs tmpfs "${ROOT}/tmp"   2>/dev/null
mount --bind   "${DATA}" "${ROOT}/data" 2>/dev/null   # tmpfs /data — zero eMMC writes

log "launching the ReForge stack (SCREEN_MODE=${SCREEN_MODE:-GUPPY}) ..."
# REFORGE_LIVE=1 makes the boot/LKG scripts skip persistent trial bookkeeping.
REFORGE_LIVE=1 SCREEN_MODE="${SCREEN_MODE:-GUPPY}" \
    chroot "${ROOT}" /mod/start.sh > "${LIVE_LOG}" 2>&1

log "stack started — holding (eMMC untouched; remove USB + reboot for stock)"
# Never return: stock auto_run stays blocked here, so it never umounts /mnt,
# never installs, and never launches the stock UI.
while true; do sleep 3600; done
