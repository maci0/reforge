#!/bin/sh
# =============================================================================
# ReForge LIVE launcher — boot ReForge from a USB stick.
#
# Live mode here means "booted off USB" — not "read-only" or "zero eMMC writes".
# We share reforge-boot's chroot layout (the reforge_chroot_mounts helper): the
# F2FS USB partition mounts at /reforge — the SAME mountpoint the installer uses
# — and we bind the host's /data (eMMC mmcblk0p7) into the chroot at /data. So
# debugging, paths and behaviour are identical to install mode; the only
# difference is that the rootfs at /reforge comes from a USB partition instead
# of a bind of /data/.mod/.reforge on eMMC.
#
# Write topology (F2FS USB mounted at /reforge):
#   - Our OS writes to USB: klippy.log, moonraker DB, SAVE_CONFIG appends, /tmp.
#   - User gcodes via Mainsail land on eMMC /data (the `[virtual_sdcard] path:
#     /data/` from the factory config). They persist across stick pull/reboot
#     and are visible to an install on the same unit — same path, same files.
#   - The eMMC sees ONE OS-level write: the mkdir of /data/.mod/.reforge (a single
#     directory inode) the first time live mode runs on a fresh unit. After
#     that the dir exists; subsequent live boots reuse it; an install reuses
#     the same dir for its own state (live mode mounts the F2FS over it, so
#     the install's files are hidden but intact — pull stick, reboot, install
#     comes back).
#
# The stock FlashForge auto_run.sh runs any `flashforge_init.sh` found at the USB
# root, directly from /mnt, on every boot:
#     /mnt/flashforge_init.sh <MACHINE> <PID>
#     if [ $? -eq 0 ]; then umount /mnt; sleep 100000; fi
# We chroot into the F2FS USB partition + run /mod/start.sh + block forever, so
# the stock flow never reaches `umount /mnt`, never installs, never launches
# the stock UI.
#
# USB layout (MBR, 2 partitions):
#   p1 vfat  — /flashforge_init.sh (this) + net-up.sh + crc32_generic.ko + f2fs.ko
#              (stock auto_run mounts this at /mnt and runs the launcher from it)
#   p2 f2fs  — the ReForge rootfs as a real block device (no loopback). Labelled
#              "reforge-live" so we can find it without parsing partition tables.
# Replaces the earlier model (single FAT partition + loop-mounted reforge-live.f2fs
# image file): no `loop.ko`, no DISCARD-on-loop log spam, no 4 GiB FAT file cap.
# =============================================================================
set -u

# The stock auto_run.sh already mounted the USB's FAT partition and runs us *from*
# it (`/mnt/flashforge_init.sh`), so we never need to find/mount the FAT side
# ourselves. Derive the USB dir from $0 so it's correct wherever stock mounts the
# stick (falls back to /mnt).
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
USB_MNT="${USB_MNT:-${SELF_DIR:-/mnt}}"
# The F2FS rootfs lives on the sibling partition (p2). The launcher finds it by
# label "reforge-live" via blkid, falling back to derive-from-p1 (e.g. /dev/sda1
# -> /dev/sda2). Test rigs can set F2FS_DEV (or legacy LIVE_IMG) to a block device
# directly. LIVE_IMG kept for backwards-compat with the qemu gates.
F2FS_DEV="${F2FS_DEV:-${LIVE_IMG:-}}"
F2FS_LABEL="${F2FS_LABEL:-reforge-live}"
# Chroot root + /data bind — identical to install mode (reforge-boot) so the
# host-side paths are uniform across modes.
ROOT="${REFORGE_LIVE_ROOT:-/reforge}"
DATA="${REFORGE_LIVE_DATA:-/data}"

# Logging goes to the console AND a persistent log file ON THE USB, so a pulled stick is
# debuggable with no network. Writing to the USB is fine — it is the live medium, NOT the
# eMMC, so the zero-eMMC-write invariant is unaffected. Prefer the framebuffer console
# (the panel, /dev/tty1) so HEADLESS output is visible on screen, not just on the serial
# /dev/console; fall back to /dev/console.
# An env-provided LIVE_LOG wins (qemu test rigs set it to /dev/console so the
# launcher output is captured in the serial log alongside the gate init's).
if [ -n "${LIVE_LOG:-}" ]; then
    :  # honour the env override
else
    LIVE_LOG=/dev/console
    for _t in /dev/tty1 /dev/tty0; do [ -c "${_t}" ] && [ -w "${_t}" ] && { LIVE_LOG="${_t}"; break; }; done
fi
USB_LOG="${USB_MNT}/reforge-live.log"
: > "${USB_LOG}" 2>/dev/null || true   # fresh log each boot
log() { echo "[reforge-live] $*" | tee -a "${USB_LOG}" 2>/dev/null > "${LIVE_LOG}" 2>&1; }
# (ROOT and DATA are set above, near the F2FS_DEV declarations.)

# Make sure an SSH daemon is listening on :22 so the box stays reachable for debugging
# even when the printer stack (klippy/GuppyScreen) is wedged. Stock starts dropbear early
# in a normal boot, but in live mode we block stock's auto_run before that point, so on
# the full-stack path nothing brings sshd up — start one if absent. Best-effort, never
# fatal; -R generates a host key on demand if the stock rootfs has none.
ensure_sshd() {
    if ps w 2>/dev/null | grep -q '[d]ropbear' || ps w 2>/dev/null | grep -q '[s]shd'; then
        log "ssh daemon already running"; return 0
    fi
    for _d in /usr/sbin/dropbear /bin/dropbear /sbin/dropbear; do
        [ -x "${_d}" ] && { log "starting ${_d} -R -p 22"; "${_d}" -R -p 22 2>/dev/null; return 0; }
    done
    log "no dropbear/sshd binary found — SSH will be unavailable"
}

# Screen mode: env wins, else an optional `screen_mode` file at the USB root (so you
# can drop "HEADLESS" next to the launcher to debug — the boot console + net-up + klippy
# errors then show on the panel instead of GuppyScreen), else default GUPPY.
if [ -z "${SCREEN_MODE:-}" ] && [ -r "${USB_MNT}/screen_mode" ]; then
    SCREEN_MODE="$(tr -d ' \t\r\n' < "${USB_MNT}/screen_mode" 2>/dev/null)"
fi
SCREEN_MODE="${SCREEN_MODE:-GUPPY}"

# NET-ONLY debug mode: skip the ENTIRE ReForge stack — no f2fs mount, no chroot, no
# klippy/moonraker/guppy. Just bring up WiFi + make sure an SSH daemon is listening,
# then hold forever (so stock auto_run never resumes → eMMC stays untouched). Lets us
# isolate "is the box reachable on the network?" from the printer stack. Enabled by a
# `net_only` file at the USB root (drop it next to this script) or NET_ONLY=1.
[ -z "${NET_ONLY:-}" ] && [ -e "${USB_MNT}/net_only" ] && NET_ONLY=1
if [ "${NET_ONLY:-0}" = 1 ]; then
    log "NET-ONLY mode — skipping klippy/moonraker/guppy; WiFi + sshd + hold"
    if [ -f "${USB_MNT}/net-up.sh" ]; then
        # shellcheck source=/dev/null
        . "${USB_MNT}/net-up.sh"
        REFORGE_LIVE_NET_LOG="${USB_LOG}" reforge_live_netup || true
    fi
    ensure_sshd
    while true; do
        log "net-only: ip=[$(ip addr show 2>/dev/null | grep -o 'inet [0-9.]*' | grep -v 127.0.0.1 | tr '\n' ' ')]"
        sleep 30
    done
fi

log "starting (screen=${SCREEN_MODE})"

# Ensure mountpoints exist on the host. mkdir -p on ROOT (/reforge) is the ONE
# eMMC-side OS write live mode makes (a single empty directory inode, on the
# stock p6 rootfs); on a unit that previously ran live mode or has an install
# the dir already exists and this no-ops.
mkdir -p "${ROOT}"
[ -d "${DATA}" ] || mkdir -p "${DATA}"

# The stock 5.4.61 kernel (verified on hardware) ships NONE of what this needs:
# no plain 'crc32' crypto (F2FS needs it at mount; the kernel only has crc32c),
# and no F2FS. Load the two matching-vermagic modules shipped next to us on the
# USB FAT partition, in dependency order. Both are standalone (depends= empty),
# built against the stock BSP — see modules/f2fs-bsp/. Each insmod is a no-op if
# already present (e.g. a qemu gate kernel with these built in).
#
# Note: this used to also insmod loop.ko (to loop-mount a reforge-live.f2fs file
# off the FAT stick). The new 2-partition layout puts the rootfs on a real F2FS
# partition (p2), so the loop driver is no longer needed.
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
insmod_ko 'crc32' "${MOD_DIR}/crc32_generic.ko"
insmod_ko 'f2fs'  "${MOD_DIR}/f2fs.ko"

# Discover the F2FS rootfs partition (p2 on the USB stick). Order:
#   1. F2FS_DEV / LIVE_IMG env override (test rigs pass a raw block device here).
#   2. blkid -L reforge-live  (label baked in by tools/release/build-live-usb.sh).
#   3. Derive from the FAT partition we were launched off of: /proc/mounts says
#      what's backing USB_MNT (e.g. /dev/sda1); the sibling partition is /dev/sda2.
#   4. Brute-force scan /dev/sd[a-z][2-4] for an F2FS magic (last-ditch fallback).
find_f2fs_dev() {
    [ -n "${F2FS_DEV}" ] && [ -e "${F2FS_DEV}" ] && { echo "${F2FS_DEV}"; return 0; }
    if command -v blkid >/dev/null 2>&1; then
        _d="$(blkid -L "${F2FS_LABEL}" 2>/dev/null || true)"
        [ -n "${_d}" ] && [ -e "${_d}" ] && { echo "${_d}"; return 0; }
        _d="$(blkid -t TYPE=f2fs -o device 2>/dev/null | head -n1 || true)"
        [ -n "${_d}" ] && [ -e "${_d}" ] && { echo "${_d}"; return 0; }
    fi
    _usb_dev="$(awk -v m="${USB_MNT}" '$2==m {print $1; exit}' /proc/mounts 2>/dev/null || true)"
    case "${_usb_dev}" in
        *[0-9])
            _sibling="${_usb_dev%[0-9]}2"
            [ -e "${_sibling}" ] && { echo "${_sibling}"; return 0; }
            ;;
    esac
    # F2FS superblock magic 0xF2F52010 sits at offset 0x400 (1024) on the partition.
    for _d in /dev/sd[a-z]2 /dev/sd[a-z]3 /dev/sd[a-z]4; do
        [ -b "${_d}" ] || continue
        # busybox dd + od; check for 10 20 f5 f2 (little-endian) at offset 1024.
        _magic="$(dd if="${_d}" bs=1 skip=1024 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n' || true)"
        [ "${_magic}" = "1020f5f2" ] && { echo "${_d}"; return 0; }
    done
    return 1
}
F2FS_DEV="$(find_f2fs_dev || true)"
[ -n "${F2FS_DEV}" ] && [ -e "${F2FS_DEV}" ] || {
    log "ERROR: could not find ReForge F2FS rootfs (label=${F2FS_LABEL}); is the USB partitioned correctly?"
    exit 1
}
log "rootfs device: ${F2FS_DEV}"

# Mount the F2FS rootfs (the chroot root). Real block device — no `loop` mount
# option, DISCARD/TRIM works (USB sticks ignore it but no -EIO spam), and the
# rootfs is no longer capped by the FAT 4 GiB file size limit. The fallback to
# auto-detected FS type keeps the qemu gates working (they present an ext4 image
# on /dev/vdb instead of F2FS — the launcher-level gate is filesystem-agnostic).
mount -t f2fs -o rw "${F2FS_DEV}" "${ROOT}" 2>/dev/null \
    || mount -o rw "${F2FS_DEV}" "${ROOT}" 2>/dev/null \
    || { log "ERROR: cannot mount ${F2FS_DEV}"; exit 1; }
[ -x "${ROOT}/mod/start.sh" ] || { log "ERROR: ${ROOT}/mod/start.sh missing — bad image"; exit 1; }

# Chroot filesystems via the shared helper (same layout as install mode,
# reforge-boot). tmp_mode=tmpfs: live wants an ephemeral /tmp, not the stock
# one. /data is bound from the host's /data (eMMC mmcblk0p7), so gcode uploads
# via Mainsail (factory `[virtual_sdcard] path: /data/`) persist on the printer
# and are visible to an install on the same unit.
HELPER="${ROOT}/.shell/reforge-chroot.sh"
[ -f "${HELPER}" ] || { log "ERROR: ${HELPER} missing — bad image"; exit 1; }
# shellcheck source=/dev/null
. "${HELPER}"
reforge_chroot_mounts "${ROOT}" "${DATA}" tmpfs

# Mark the chroot as live so the banner (boot splash + every login) shows the LIVE
# badge. /run is tmpfs (bind from host) — the marker is ephemeral, gone once the USB
# is pulled and the printer reboots to stock, which is exactly what we want.
: > "${ROOT}/run/reforge-live" 2>/dev/null || true

# Boot the toolhead ("eboard") MCU NOW — as early as possible, the moment the
# rootfs is mounted and /dev is wired into the chroot, before net/banner/stack.
# The eboard (/dev/ttyS1) powers up in a serial bootloader that waits for the
# host to send 'A' before starting its Klipper app; the mainboard MCU auto-boots
# and needs no trigger. Stock does this (firmwareExe "bootserial eboard:") and so
# does forge-x (its boot_mcu binary, run from boot.sh regardless of screen mode) —
# live mode must too, or klippy can never identify the eboard ("Serial connection
# closed") and the toolhead stays dark. Best-effort: a warm reboot (eboard already
# in its app) simply no-ops the handshake. Needs the rootfs python + termios, so
# run it inside the chroot.
log "booting eboard MCU (toolhead) ..."
chroot "${ROOT}" /usr/bin/reforge-boot-eboard >> "${USB_LOG}" 2>&1 \
    || log "eboard boot handshake returned non-zero (already up? see log) — continuing"

# Paint the fire/ember boot splash (with the LIVE badge) on the console, the way
# reforge-boot would on a normal boot. TERM=linux so the framebuffer console colorizes.
REFORGE_LIVE=1 TERM=linux chroot "${ROOT}" /usr/bin/reforge-banner > "${LIVE_LOG}" 2>&1 || true

# Bring up the network (best-effort) BEFORE the chroot: in live mode we block stock's
# auto_run, so the stock WiFi init never runs and the box has no LAN. net-up.sh reuses
# the stock driver + /etc/wpa_supplicant.conf creds (read-only) to join, so Moonraker /
# Mainsail / SSH are reachable. See docs/live-mode.md. wlan0 is in
# the host net namespace; the chroot shares it. Never blocks the boot.
if [ -f "${USB_MNT}/net-up.sh" ]; then
    # shellcheck source=/dev/null
    . "${USB_MNT}/net-up.sh"
    # Send net-up's step log to the USB log so a failed WiFi join is debuggable offline.
    REFORGE_LIVE_NET_LOG="${USB_LOG}" reforge_live_netup || true
    log "net: $(ip addr show 2>/dev/null | grep -o 'inet [0-9.]*' | grep -v '127.0.0.1' | tr '\n' ' ')"
fi

# Bring SSH up NOW — before the (slow, possibly-wedged) stack launch below — so the box
# is reachable for debugging even if klippy never reaches 'ready'. In live mode stock's
# own dropbear init is blocked, so without this the full-stack path has no SSH.
ensure_sshd

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
