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

# The stock auto_run.sh already mounted the USB and runs us *from* it
# (`/mnt/flashforge_init.sh`), so we never need to find/mount a device ourselves —
# the rootfs image sits right next to this script. Derive the USB dir from $0 so
# it's correct wherever stock mounts the stick (falls back to /mnt).
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
USB_MNT="${USB_MNT:-${SELF_DIR:-/mnt}}"
LIVE_IMG="${LIVE_IMG:-${USB_MNT}/reforge-live.f2fs}"
ROOT="${REFORGE_LIVE_ROOT:-/tmp/.reforge-live}"   # chroot root (/tmp is tmpfs)
DATA="${REFORGE_LIVE_DATA:-/tmp/.reforge-data}"   # writable /data -> tmpfs

log "starting (img=${LIVE_IMG})"
# -e, not -f: LIVE_IMG is a regular file on the FAT USB, but may be a raw block
# device (e.g. the qemu zero-write gate presents the rootfs as /dev/vdb).
[ -e "${LIVE_IMG}" ] || { log "ERROR: ${LIVE_IMG} not found on USB"; exit 1; }

mkdir -p "${ROOT}" "${DATA}"

# The stock 5.4.61 kernel (verified on hardware) ships NONE of what this needs:
# no loop driver (to loop-mount the rootfs image off the FAT stick), no plain
# 'crc32' crypto (F2FS needs it at mount; the kernel only has crc32c), and no
# F2FS. Load the three matching-vermagic modules shipped next to us on the USB,
# in dependency order. All are standalone (depends= empty), built against the
# stock BSP — see modules/f2fs-bsp/. Each insmod is a no-op if already present
# (e.g. a qemu gate kernel with these built in).
MOD_DIR="${MOD_DIR:-${USB_MNT}}"
insmod_ko() {  # <name-in-/proc> <file>
    # WORD match, not substring: the device exposes 'crc32c' but NOT plain 'crc32',
    # and a substring grep would match 'crc32c' and wrongly skip crc32_generic.ko —
    # then the F2FS mount dies for lack of the plain 'crc32' shash. grep -qw 'crc32'
    # does not match 'crc32c', so the module is loaded as intended.
    grep -qw "$1" /proc/filesystems /proc/crypto /proc/devices 2>/dev/null && return 0
    [ -f "$2" ] || return 0
    log "insmod $2"
    insmod "$2" 2>/dev/null || /sbin/insmod "$2" 2>/dev/null || log "WARN: insmod $2 failed"
}
insmod_ko 'loop'  "${MOD_DIR}/loop.ko"
insmod_ko 'crc32' "${MOD_DIR}/crc32_generic.ko"
insmod_ko 'f2fs'  "${MOD_DIR}/f2fs.ko"

# Mount the ReForge rootfs image (the chroot root). A file on the FAT USB needs
# a loop device; a raw block device (e.g. the qemu zero-write gate) mounts directly.
if [ -b "${LIVE_IMG}" ]; then
    mount -t f2fs -o rw "${LIVE_IMG}" "${ROOT}" 2>/dev/null \
        || mount -o rw "${LIVE_IMG}" "${ROOT}" 2>/dev/null \
        || { log "ERROR: cannot mount ${LIVE_IMG}"; exit 1; }
elif ! mount -t f2fs -o loop,rw "${LIVE_IMG}" "${ROOT}" 2>/dev/null; then
    mount -o loop,rw "${LIVE_IMG}" "${ROOT}" 2>/dev/null \
        || { log "ERROR: cannot loop-mount ${LIVE_IMG}"; exit 1; }
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

# Mark the chroot as live so the banner (boot splash + every login) shows the LIVE
# badge. /run is tmpfs (bind from host) — the marker is ephemeral, gone once the USB
# is pulled and the printer reboots to stock, which is exactly what we want.
: > "${ROOT}/run/reforge-live" 2>/dev/null || true

# Paint the fire/ember boot splash (with the LIVE badge) on the console, the way
# reforge-boot would on a normal boot. TERM=linux so the framebuffer console colorizes.
REFORGE_LIVE=1 TERM=linux chroot "${ROOT}" /usr/bin/reforge-banner > "${LIVE_LOG}" 2>&1 || true

log "launching the ReForge stack (SCREEN_MODE=${SCREEN_MODE:-GUPPY}) ..."
# REFORGE_LIVE=1 makes the boot/LKG scripts skip persistent trial bookkeeping.
REFORGE_LIVE=1 SCREEN_MODE="${SCREEN_MODE:-GUPPY}" \
    chroot "${ROOT}" /mod/start.sh > "${LIVE_LOG}" 2>&1

log "stack started — holding (eMMC untouched; remove USB + reboot for stock)"
# Never return: stock auto_run stays blocked here, so it never umounts /mnt,
# never installs, and never launches the stock UI.
while true; do sleep 3600; done
