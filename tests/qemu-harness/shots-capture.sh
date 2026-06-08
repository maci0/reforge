#!/usr/bin/env bash
# =============================================================================
# shots-capture.sh — boot the stock FlashForge UI under qemu and grab a numbered
# series of screendumps across boot PHASES (splash, loading/connecting, home),
# so we can pick the visually distinct frames. Fully rootless.
#
# Reuses the proven flow from stockui-render.sh (GPT-offset rootfs slice already
# materialised as build/stock-clean-rootfs.ext4, debugfs inject of the sims +
# auto_run patch + serial/PowerOff scrub, unprivileged qemu, socat screendump),
# but writes its OWN image (build/shots-stockui.ext4) + monitor socket so it does
# NOT disturb the stockui-render harness or any other concurrent qemu job.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
. "${HARNESS_DIR}/lib/common.sh"   # mkext4 + emmc deps (log/die re-defined below)
. "${HARNESS_DIR}/lib/emmc.sh"     # emmc_build_p6 -> EMMC_QEMU_ARGS + EMMC_ROOT
SIM_DIR="${HARNESS_DIR}/stockui"
ZIMAGE="${BUILD_DIR}/zImage"
CLEAN="${BUILD_DIR}/stock-clean-rootfs.ext4"
IMG="${BUILD_DIR}/shots-stockui.ext4"
MON="${BUILD_DIR}/qemu-shots-mon.sock"
SER="${BUILD_DIR}/shots-stockui-serial.log"
SHOTDIR="${BUILD_DIR}/shots"

MEM="${MEM:-256}"
PY="/opt/Python-3.7.11/bin/python3.7"
# capture times (seconds since the monitor socket appears)
TIMES="${TIMES:-4 8 12 18 25 40 60 90}"

log() { echo "[shots-capture] $*"; }
die() { echo "[shots-capture] ERROR: $*" >&2; exit 1; }

[ -f "${ZIMAGE}" ] || die "virt kernel missing: ${ZIMAGE}"
[ -f "${CLEAN}" ]  || die "clean rootfs missing: ${CLEAN} (run stockui-render.sh once)"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v debugfs >/dev/null || die "debugfs not installed"
command -v socat >/dev/null || die "socat not installed"

mkdir -p "${SHOTDIR}"
rm -f "${SHOTDIR}"/shot-*.ppm

# --- working copy --------------------------------------------------------------
log "preparing working image ${IMG}"
cp -f "${CLEAN}" "${IMG}"
e2fsck -fy "${IMG}" >/dev/null 2>&1 || true
tune2fs -e continue "${IMG}" >/dev/null 2>&1

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
: > "${BUILD_DIR}/.shots-marker"
robust_inject "${BUILD_DIR}/.shots-marker" /etc/reforge-stocksim

# scrub captured device state (power-loss modal + REAL serial) — privacy-safe
log "scrubbing captured device state (PowerOff flag + real serial)"
debugfs -w -R "rm /opt/config/PowerOff" "${IMG}" >/dev/null 2>&1 || true
A5M="${BUILD_DIR}/.shots-Adventurer5M.json"
if debugfs -R "cat /opt/config/Adventurer5M.json" "${IMG}" 2>/dev/null > "${A5M}" && [ -s "${A5M}" ]; then
    sed -i 's/"SN[A-Z0-9]\{6,\}"/"REFORGE-DEMO"/g' "${A5M}"
    robust_inject "${A5M}" /opt/config/Adventurer5M.json
fi

# patch auto_run.sh to start the sims right before ffstartup
log "patching /opt/auto_run.sh"
AR="${BUILD_DIR}/.shots-auto_run.sh"
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
: "${PY:?}"

# --- serialize behind other qemu jobs (up to ~5 min), then boot ---------------
log "waiting for any other qemu-system-arm to finish (max 5 min) ..."
WAITED=0
while pgrep -u "$(id -u)" qemu-system-arm >/dev/null 2>&1; do
    sleep 5; WAITED=$((WAITED+5))
    [ "${WAITED}" -ge 300 ] && { log "WARN: timed out waiting; proceeding (own unique sockets/images)"; break; }
done

rm -f "${MON}" "${SER}"
emmc_build_p6 "${IMG}"   # production eMMC -> stock rootfs at /dev/mmcblk0p6 (real-hw name)
log "booting qemu (MEM=${MEM} MiB) — captures at: ${TIMES}"
# shellcheck disable=SC2086  # EMMC_QEMU_ARGS is an intentional arg list
qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -m "${MEM}" \
    -kernel "${ZIMAGE}" \
    -append "console=ttyAMA0,115200 loglevel=4 ${EMMC_ROOT} rw rootwait" \
    -display none -monitor "unix:${MON},server,nowait" -serial file:"${SER}" \
    -device virtio-gpu-pci,xres=800,yres=480 \
    ${EMMC_QEMU_ARGS} \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 >/dev/null 2>&1 &
QP=$!
trap 'kill -9 "${QP}" 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do [ -S "${MON}" ] && break; sleep 1; done
[ -S "${MON}" ] || die "qemu monitor socket never appeared"

PREV=0
for T in ${TIMES}; do
    DELTA=$((T - PREV))
    [ "${DELTA}" -gt 0 ] && sleep "${DELTA}"
    PREV="${T}"
    OUT="${SHOTDIR}/shot-$(printf '%03d' "${T}").ppm"
    printf 'screendump %s\n' "${OUT}" | socat - "UNIX-CONNECT:${MON}" 2>/dev/null || true
    log "  t=${T}s -> ${OUT}"
done
sleep 2
kill -9 "${QP}" 2>/dev/null || true
trap - EXIT

log "done. shots in ${SHOTDIR}:"
ls -la "${SHOTDIR}"/shot-*.ppm 2>&1 || true
