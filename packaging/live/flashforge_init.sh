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

# The stock auto_run.sh already mounted the USB and runs us *from* it
# (`/mnt/flashforge_init.sh`), so we never need to find/mount a device ourselves —
# the rootfs image sits right next to this script. Derive the USB dir from $0 so
# it's correct wherever stock mounts the stick (falls back to /mnt).
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
USB_MNT="${USB_MNT:-${SELF_DIR:-/mnt}}"
LIVE_IMG="${LIVE_IMG:-${USB_MNT}/reforge-live.f2fs}"

# Logging goes to the console AND a persistent log file ON THE USB, so a pulled stick is
# debuggable with no network. Writing to the USB is fine — it is the live medium, NOT the
# eMMC, so the zero-eMMC-write invariant is unaffected. Prefer the framebuffer console
# (the panel, /dev/tty1) so HEADLESS output is visible on screen, not just on the serial
# /dev/console; fall back to /dev/console.
LIVE_LOG=/dev/console
for _t in /dev/tty1 /dev/tty0; do [ -c "${_t}" ] && [ -w "${_t}" ] && { LIVE_LOG="${_t}"; break; }; done
USB_LOG="${USB_MNT}/reforge-live.log"
: > "${USB_LOG}" 2>/dev/null || true   # fresh log each boot
log() { echo "[reforge-live] $*" | tee -a "${USB_LOG}" 2>/dev/null > "${LIVE_LOG}" 2>&1; }
ROOT="${REFORGE_LIVE_ROOT:-/tmp/.reforge-live}"   # chroot root (/tmp is tmpfs)
DATA="${REFORGE_LIVE_DATA:-/tmp/.reforge-data}"   # writable /data -> tmpfs

# Screen mode: env wins, else an optional `screen_mode` file at the USB root (so you
# can drop "HEADLESS" next to the launcher to debug — the boot console + net-up + klippy
# errors then show on the panel instead of GuppyScreen), else default GUPPY.
if [ -z "${SCREEN_MODE:-}" ] && [ -r "${USB_MNT}/screen_mode" ]; then
    SCREEN_MODE="$(tr -d ' \t\r\n' < "${USB_MNT}/screen_mode" 2>/dev/null)"
fi
SCREEN_MODE="${SCREEN_MODE:-GUPPY}"

log "starting (img=${LIVE_IMG}, screen=${SCREEN_MODE})"
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
# nodiscard: the loop device over a FAT-hosted image can't service DISCARD/TRIM, so
# F2FS's discards fail (loop0 I/O error, ret -5) and spam the log — disable them.
if [ -b "${LIVE_IMG}" ]; then
    mount -t f2fs -o rw,nodiscard "${LIVE_IMG}" "${ROOT}" 2>/dev/null \
        || mount -o rw "${LIVE_IMG}" "${ROOT}" 2>/dev/null \
        || { log "ERROR: cannot mount ${LIVE_IMG}"; exit 1; }
elif ! mount -t f2fs -o loop,rw,nodiscard "${LIVE_IMG}" "${ROOT}" 2>/dev/null; then
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

# Bring up the network (best-effort) BEFORE the chroot: in live mode we block stock's
# auto_run, so the stock WiFi init never runs and the box has no LAN. net-up.sh reuses
# the stock driver + /etc/wpa_supplicant.conf creds (read-only) to join, so Moonraker /
# Mainsail / SSH are reachable. See docs/specs/2026-06-02-live-mode-wifi.md. wlan0 is in
# the host net namespace; the chroot shares it. Never blocks the boot.
if [ -f "${USB_MNT}/net-up.sh" ]; then
    # shellcheck source=/dev/null
    . "${USB_MNT}/net-up.sh"
    # Send net-up's step log to the USB log so a failed WiFi join is debuggable offline.
    REFORGE_LIVE_NET_LOG="${USB_LOG}" reforge_live_netup || true
    log "net: $(ip -o addr show 2>/dev/null | grep -o 'inet [0-9.]*' | grep -v '127.0.0.1' | tr '\n' ' ')"
fi

# Append a diagnostics snapshot to the USB log (and console) — net, loaded modules,
# and the chroot's klippy/moonraker logs + dmesg — so a pulled stick shows WHY the
# stack is in whatever state it's in, with no network needed.
snapshot() {
    {
        echo "==== reforge-live snapshot (uptime $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s) ===="
        echo "-- net --";        ip -o addr show 2>/dev/null | grep -o 'inet [0-9.]*'
        echo "-- modules --";    lsmod 2>/dev/null | grep -E 'f2fs|^loop|crc32|8821|cfg80211' || echo "(none)"
        echo "-- klippy.log (tail) --"; tail -n 40 "${ROOT}/var/log/klippy.log" 2>/dev/null || echo "(no klippy.log)"
        echo "-- moonraker.log (tail) --"; tail -n 20 "${ROOT}/var/lib/moonraker/logs/moonraker.log" "${ROOT}/var/log/moonraker.log" 2>/dev/null
        echo "-- dmesg (tail) --"; dmesg 2>/dev/null | tail -n 25
        echo ""
    } >> "${USB_LOG}" 2>/dev/null || true
    sync 2>/dev/null || true
}

log "launching the ReForge stack (SCREEN_MODE=${SCREEN_MODE}) ..."
# REFORGE_LIVE=1 makes the boot/LKG scripts skip persistent trial bookkeeping.
# Tee the boot chain to the console AND the USB log.
REFORGE_LIVE=1 SCREEN_MODE="${SCREEN_MODE}" \
    chroot "${ROOT}" /mod/start.sh 2>&1 | tee -a "${USB_LOG}" > "${LIVE_LOG}" 2>&1

log "stack started — holding (eMMC untouched; remove USB + reboot for stock)"
# Never return: stock auto_run stays blocked here so it never umounts /mnt, installs,
# or launches the stock UI. Snapshot a few times early (to capture klippy/MCU startup
# + errors onto the USB), then idle.
i=0
while true; do
    if [ "${i}" -lt 8 ]; then sleep 15; snapshot; i=$((i + 1)); else sleep 3600; fi
done
