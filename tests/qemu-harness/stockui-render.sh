#!/usr/bin/env bash
# =============================================================================
# stockui-render.sh — render the stock FlashForge UI (firmwareExe) to a PNG-able
# PPM under qemu, with the eboard MCU + klippy SIMULATED so the GUI fully boots
# to its home screen (not the "No detected eboard mcu." modal).
#
# Fully ROOTLESS (no sudo): the boot ext4 is built/patched with debugfs (no loop
# mount), the clean stock rootfs is sliced from the golden image by GPT offset +
# dd, and qemu-system-arm runs as the normal user (cortex-a7 TCG needs no kvm).
# Because qemu is unprivileged its -monitor unix socket is user-owned, so the
# screendump goes through plain socat with no sudo.
#
# Two startup gates firmwareExe checks (both must pass for the home screen):
#   1. eboard serial handshake on /dev/ttyS1 (+/dev/ttyS5) @230400 — satisfied by
#      stockui/mcu-sim.py (a gcode-MCU pty stand-in), launched right before
#      ffstartup so udev coldplug can't churn the node out from under it.
#   2. klippy "ready" on /tmp/uds — satisfied by stockui/fake-klippy.py.
#
# Usage:   tests/qemu-harness/stockui-render.sh            # NO sudo
#          SETTLE=95 stockui-render.sh
# Output:  tests/qemu-harness/build/stockui-home.ppm  (convert to PNG with magick)
#          tests/qemu-harness/build/stockui-home-serial.log
# Needs:   qemu-system-arm, socat, debugfs/mke2fs (e2fsprogs), gzip, sfdisk
#          build/zImage (make qemu-kernel) and tools/recovery/golden.img.gz
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
SIM_DIR="${HARNESS_DIR}/stockui"
ZIMAGE="${BUILD_DIR}/zImage"
GOLDEN="${REPO_ROOT}/tools/recovery/golden.img.gz"
CLEAN="${BUILD_DIR}/stock-clean-rootfs.ext4"
IMG="${BUILD_DIR}/stockui-root.ext4"
MON="${BUILD_DIR}/qemu-stockui-mon.sock"
SHOT="${BUILD_DIR}/stockui-home.ppm"
SER="${BUILD_DIR}/stockui-home-serial.log"

MEM="${MEM:-256}"
SETTLE="${SETTLE:-95}"
PY="/opt/Python-3.7.11/bin/python3.7"

log() { echo "[stockui-render] $*"; }
die() { echo "[stockui-render] ERROR: $*" >&2; exit 1; }

[ -f "${ZIMAGE}" ] || die "virt kernel missing: ${ZIMAGE} (run: make qemu-kernel)"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v debugfs >/dev/null || die "debugfs not installed (e2fsprogs)"
command -v socat >/dev/null || die "socat not installed"

# --- 1. clean stock rootfs (slice p6 from the golden by GPT offset, rootless) --
if [ ! -f "${CLEAN}" ]; then
    [ -f "${GOLDEN}" ] || die "need ${GOLDEN} (clean stock) to slice the rootfs"
    RAW="${BUILD_DIR}/golden-raw.img"
    if [ ! -f "${RAW}" ] || [ "$(stat -c%s "${RAW}" 2>/dev/null || echo 0)" != "7818182656" ]; then
        log "decompressing golden -> ${RAW} (~7.3 GB, several minutes) ..."
        gzip -dc "${GOLDEN}" > "${RAW}"
    fi
    # p6 = rootfs. Read its start sector + length from the GPT (no losetup).
    read -r START SECTORS < <(sfdisk -d "${RAW}" 2>/dev/null \
        | awk -F'[ ,]+' '/img6 *:/ {for(i=1;i<=NF;i++){if($i=="start=")s=$(i+1);if($i=="size=")z=$(i+1)} print s, z}')
    [ -n "${START:-}" ] && [ -n "${SECTORS:-}" ] || die "could not read p6 offset from GPT"
    log "slicing p6 (start=${START} sectors, size=${SECTORS}) -> ${CLEAN}"
    dd if="${RAW}" of="${CLEAN}" bs=512 skip="${START}" count="${SECTORS}" status=none
fi

# --- 2. working copy + make it tolerant of fsck/trim remount-ro ---------------
log "preparing working image ${IMG}"
cp -f "${CLEAN}" "${IMG}"
e2fsck -fy "${IMG}" >/dev/null 2>&1 || true   # rc=1 just means errors were fixed
tune2fs -e continue "${IMG}" >/dev/null 2>&1   # don't remount-ro when /data p7 is absent

# --- 3. inject the sims + marker + patch auto_run.sh (robust vs debugfs trunc) -
# debugfs 'write' can silently drop the file's tail; verify size and retry.
robust_inject() {
    local src="$1" dst="$2" want got
    want=$(wc -c < "${src}")
    for _ in 1 2 3 4 5; do
        debugfs -w -R "rm ${dst}" "${IMG}" >/dev/null 2>&1 || true
        debugfs -w -R "write ${src} ${dst}" "${IMG}" >/dev/null 2>&1 || true
        got=$(debugfs -R "stat ${dst}" "${IMG}" 2>/dev/null | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1)
        [ "${got}" = "${want}" ] && return 0
    done
    die "failed to inject ${dst} at full size (want ${want}, got ${got:-0})"
}

log "injecting mcu-sim + fake-klippy"
robust_inject "${SIM_DIR}/mcu-sim.py" /opt/mcu-sim.py
robust_inject "${SIM_DIR}/fake-klippy.py" /opt/fake-klippy.py
: > "${BUILD_DIR}/.stocksim-marker"
robust_inject "${BUILD_DIR}/.stocksim-marker" /etc/reforge-stocksim

# Clean the captured device state so the render is generic + privacy-safe:
#  * /opt/config/PowerOff is a power-loss-recovery flag (PowerFlag:ON) left from
#    the dumped device's interrupted print — it makes firmwareExe pop a
#    "recovery print?" modal. Remove it for a clean home screen.
#  * Adventurer5M.json carries the dumped device's REAL serial (printerName /
#    printerSerialNumber). Replace with a demo SN so we don't ship it.
log "scrubbing captured device state (PowerOff flag + real serial)"
debugfs -w -R "rm /opt/config/PowerOff" "${IMG}" >/dev/null 2>&1 || true
#  * general.CheckAppFrist gates firmwareExe's checkAppTip() — the boot-time
#    "Please upgrade the slicer software to V1.7.3" nag. Flip it false to clear.
A5M="${BUILD_DIR}/.Adventurer5M.json"
if debugfs -R "cat /opt/config/Adventurer5M.json" "${IMG}" 2>/dev/null > "${A5M}" && [ -s "${A5M}" ]; then
    sed -i 's/"SN[A-Z0-9]\{6,\}"/"REFORGE-DEMO"/g' "${A5M}"
    sed -i 's/"CheckAppFrist"[[:space:]]*:[[:space:]]*true/"CheckAppFrist" : false/g' "${A5M}"
    robust_inject "${A5M}" /opt/config/Adventurer5M.json
fi

# patch /opt/auto_run.sh to launch the sims right before ffstartup (so udev
# coldplug, which runs earlier, can't remove /dev/ttyS1 before firmwareExe opens it)
log "patching /opt/auto_run.sh to start the sims before ffstartup"
AR="${BUILD_DIR}/.auto_run.sh"
debugfs -R "cat /opt/auto_run.sh" "${IMG}" 2>/dev/null > "${AR}"
if ! grep -q reforge-stocksim "${AR}"; then
    awk '/\/opt\/PROGRAM\/ffstartup-arm -f/ && !done {
        print "if [ -f /etc/reforge-stocksim ]; then";
        print "  grep -q devpts /proc/mounts || mount -t devpts devpts /dev/pts 2>/dev/null";
        print "  P=/opt/Python-3.7.11/bin/python3.7";
        print "  \"$P\" /opt/mcu-sim.py /dev/ttyS1 &";
        print "  \"$P\" /opt/mcu-sim.py /dev/ttyS5 &";
        print "  \"$P\" /opt/fake-klippy.py &";
        print "  touch /tmp/printer; sleep 3";
        print "fi";
        done=1
    } {print}' "${AR}" > "${AR}.new"
    robust_inject "${AR}.new" /opt/auto_run.sh
    debugfs -w -R "sif /opt/auto_run.sh mode 0100755" "${IMG}" >/dev/null 2>&1
fi
: "${PY:?}"  # referenced in the patched guest script; keep shellcheck aware

# --- 4. boot (unprivileged) + screendump via the user-owned monitor socket ----
pkill -9 -u "$(id -u)" qemu-system-arm 2>/dev/null || true
sleep 1
rm -f "${MON}" "${SHOT}" "${SER}"
log "booting qemu (MEM=${MEM} MiB, settle=${SETTLE}s, no sudo) ..."
qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -m "${MEM}" \
    -kernel "${ZIMAGE}" \
    -append "console=ttyAMA0,115200 loglevel=4 root=/dev/vda rw rootwait" \
    -display none -monitor "unix:${MON},server,nowait" -serial file:"${SER}" \
    -device virtio-gpu-pci,xres=800,yres=480 \
    -drive "file=${IMG},if=virtio,format=raw,cache=writeback" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 >/dev/null 2>&1 &
QP=$!
trap 'kill -9 "${QP}" 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do [ -S "${MON}" ] && break; sleep 1; done
[ -S "${MON}" ] || die "qemu monitor socket never appeared"
sleep "${SETTLE}"

printf 'screendump %s\n' "${SHOT}" | socat - "UNIX-CONNECT:${MON}" 2>/dev/null || true
sleep 3
kill -9 "${QP}" 2>/dev/null || true
trap - EXIT

# --- 5. verdict ---------------------------------------------------------------
if grep -q 'open fail' "${SER}" 2>/dev/null; then
    log "WARN: firmwareExe could not open /dev/ttyS1 — serial gate failed (check ${SER})"
fi
[ -s "${SHOT}" ] || die "no screendump produced (see ${SER})"
log "PASS: rendered ${SHOT}"
log "  serial: ${SER}"
log "  to view: magick ${SHOT} stockui-home.png"
