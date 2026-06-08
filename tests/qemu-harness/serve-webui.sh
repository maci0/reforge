#!/usr/bin/env bash
# =============================================================================
# serve-webui.sh — boot the full ReForge stack in qemu (virt) for INTERACTIVE
# browsing: real klippy (Linux-process MCU, reaches "ready" with no hardware),
# Moonraker (:7125), and Mainsail (busybox httpd :80). Forwards both to the host
# so you can open the web UI in a browser. Long-lived: holds until you Ctrl-C /
# kill it (no timeout).
#
#   Browser:  http://localhost:${WEB_PORT}     (Mainsail -> Moonraker :${MR_PORT})
#   SSH:      ssh -p ${SSH_PORT} root@localhost
#
# Env: WEB_PORT (8080) MR_PORT (7125) SSH_PORT (2222)
# Skips if qemu / kernel / rootfs / klipper_mcu are unavailable.
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
ROOTFS="${REPO_ROOT}/build/output/images/rootfs.tar"
[ -f "${ROOTFS}" ] || ROOTFS="${REPO_ROOT}/build/output/images/rootfs.tar.xz"
PATCH="${REPO_ROOT}/br-external/package/moonraker/0002-zip-updater-for-reserved-apps.patch"
MCU_BUILDER="${SCRIPT_DIR}/build-klipper-mcu.sh"
SIM_CFG="${SCRIPT_DIR}/configs/sim-printer.cfg"
CAM="${SCRIPT_DIR}/fake-camera.py"
CAM_PORT="${CAM_PORT:-8081}"

WEB_PORT="${WEB_PORT:-8080}"
MR_PORT="${MR_PORT:-7125}"
SSH_PORT="${SSH_PORT:-2222}"
IMG="${BUILD_DIR}/webui.ext4"
SER="${BUILD_DIR}/webui-serial.log"

log() { echo "[webui] $*"; }
skip() { log "SKIP: $*"; exit 0; }

QEMU_PID=""; SCRATCH=""
cleanup() {
    [ -n "${QEMU_PID}" ] && kill "${QEMU_PID}" 2>/dev/null
    [ -n "${SCRATCH}" ] && rm -rf "${SCRATCH}"
}
trap cleanup EXIT INT TERM

command -v qemu-system-arm >/dev/null 2>&1 || skip "qemu-system-arm not installed"
command -v mke2fs >/dev/null 2>&1 || skip "mke2fs not installed"
[ -f "${ZIMAGE}" ] || skip "kernel missing (${ZIMAGE}); run 'make qemu-kernel'"
[ -f "${ROOTFS}" ] || skip "rootfs missing; run 'make rootfs'"
[ -f "${SIM_CFG}" ] || skip "sim config missing"
mkdir -p "${BUILD_DIR}"

KLIPPER_MCU="$("${MCU_BUILDER}" 2>/dev/null || true)"
[ -n "${KLIPPER_MCU}" ] && [ -x "${KLIPPER_MCU}" ] || skip "could not build klipper_mcu"

SCRATCH="$(mktemp -d /tmp/webui-stage-XXXXXX)"
stage="${SCRATCH}/root"; mkdir -p "${stage}"
log "staging rootfs ..."
case "${ROOTFS}" in
    *.xz) tar --numeric-owner -xJf "${ROOTFS}" -C "${stage}" ;;
    *)    tar --numeric-owner -xf  "${ROOTFS}" -C "${stage}" ;;
esac
[ -d "${stage}/mod" ] || skip "rootfs has no /mod tree"

# 0002 (reserved-updater zip) on top, if not already in the image.
[ -f "${PATCH}" ] && patch -s -d "${stage}/opt/moonraker" -p1 --forward < "${PATCH}" >/dev/null 2>&1 || true

# Real klippy via the Linux-process MCU. NOTE: /etc/reforge is a chroot-absolute
# symlink (-> /mod/etc/reforge) that dangles in host staging, so the sim config
# goes in a REAL dir (/opt/klipper) and klippy is pointed straight at it.
cp "${KLIPPER_MCU}" "${stage}/opt/klipper/klipper_mcu"; chmod +x "${stage}/opt/klipper/klipper_mcu"
cp "${SIM_CFG}" "${stage}/opt/klipper/sim-printer.cfg"
cat > "${stage}/mod/init.d/S60klipper" <<'EOF'
#!/bin/sh
[ "$1" = start ] || exit 0
# TWO Linux-process MCUs: main board + toolhead "eboard" (mirrors the real
# dual-N32G455 topology). Each on its own socket; then klippy connects to both.
# (No -r: two SCHED_FIFO MCUs on a 2-3 vCPU guest starve klippy itself. The
# launcher instead FIRMWARE_RESTARTs once the boot storm settles — see below.)
/opt/klipper/klipper_mcu /tmp/klipper_host_mcu   >/tmp/klipper_mcu_main.log 2>&1 &
/opt/klipper/klipper_mcu /tmp/klipper_eboard_mcu >/tmp/klipper_mcu_eboard.log 2>&1 &
i=0; while { [ ! -e /tmp/klipper_host_mcu ] || [ ! -e /tmp/klipper_eboard_mcu ]; } && [ $i -lt 20 ]; do sleep 0.5; i=$((i+1)); done
/usr/bin/python3 /opt/klipper/klippy/klippy.py /opt/klipper/sim-printer.cfg \
    -a /tmp/klippy_uds -l /var/log/klippy.log >/dev/console 2>&1 &
EOF
chmod +x "${stage}/mod/init.d/S60klipper"

# Mainsail must dial Moonraker on :7125 (it is served cross-origin by httpd :80).
mkdir -p "${stage}/var/www/mainsail"
[ -f "${stage}/var/www/mainsail/config.json" ] && \
    sed -i 's/"port": *null/"port": 7125/' "${stage}/var/www/mainsail/config.json"

# .writeable markers so OTA works if you try update_manager from the UI.
for d in klipper moonraker guppyscreen; do
    [ -d "${stage}/opt/${d}" ] && : > "${stage}/opt/${d}/.writeable"
done
: > "${stage}/mod/.writeable" 2>/dev/null || true

# Fake camera: a Pillow-backed mjpg_streamer-compatible MJPEG server on :CAM_PORT,
# plus a Moonraker [webcam] entry so Mainsail's webcam panel shows a live image.
if [ -f "${CAM}" ]; then
    cp "${CAM}" "${stage}/opt/fake-camera.py"; chmod +x "${stage}/opt/fake-camera.py"
    cat > "${stage}/mod/init.d/S71camera" <<EOF
#!/bin/sh
[ "\$1" = start ] || exit 0
# Defer + FORCE_STATIC: the camera's PIL import is heavy under ARM TCG and, run
# at boot, starves klippy's dual-MCU handshake (eboard "Unable to connect"). Wait
# for klippy to settle, then serve the lightweight embedded static frame.
( sleep 40
  FORCE_STATIC=1 PORT=${CAM_PORT} /usr/bin/python3 /opt/fake-camera.py >/tmp/fake-camera.log 2>&1
) &
EOF
    chmod 0755 "${stage}/mod/init.d/S71camera"
    # The shipped moonraker.conf already has [webcam printer] -> ustreamer on :8080.
    # In qemu there's no /dev/video0 (the device's S72camera/ustreamer no-ops) and
    # the host remaps :8080 to Mainsail, so just repoint that webcam at the fake
    # camera's forwarded port. fake-camera serves /stream + /snapshot (its
    # "snapshot in path" check covers both the ustreamer and mjpg_streamer paths).
    MR_CONF="${stage}/mod/etc/reforge/moonraker.conf"
    [ -f "${MR_CONF}" ] && sed -i -E \
        "s#((stream_url|snapshot_url): *http://)localhost:[0-9]+/#\1localhost:${CAM_PORT}/#" \
        "${MR_CONF}"
fi

# Bring eth0 up (slirp DHCP) + launch the stack headless.
cat > "${stage}/etc/init.d/S98webui" <<'EOF'
#!/bin/sh
[ "$1" = start ] || exit 0
udhcpc -i eth0 -q -n 2>/dev/null || ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null
ip route add default via 10.0.2.2 2>/dev/null || true
[ -x /mod/start.sh ] && SCREEN_MODE=HEADLESS /mod/start.sh > /dev/console 2>&1
EOF
chmod 0755 "${stage}/etc/init.d/S98webui"

log "baking ext4 ..."
rm -f "${IMG}"
mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L reforge-webui -d "${stage}" "${IMG}" 2048M
rm -rf "${SCRATCH}"; SCRATCH=""

log "booting qemu (web :${WEB_PORT}->80, moonraker :${MR_PORT}->7125, ssh :${SSH_PORT}->22) ..."
rm -f "${SER}"
setsid qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -smp 4 -m 512 \
    -kernel "${ZIMAGE}" \
    -append "console=ttyAMA0,115200 root=/dev/vda rw rootwait loglevel=4" \
    -drive "file=${IMG},if=virtio,format=raw,cache=writeback" \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${WEB_PORT}-:80,hostfwd=tcp:127.0.0.1:${MR_PORT}-:7125,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${CAM_PORT}-:${CAM_PORT}" \
    -device virtio-net-pci,netdev=n0 \
    -nographic > "${SER}" 2>&1 &
QEMU_PID=$!

log "waiting for Moonraker ..."
up=0; w=0
while [ "${w}" -lt 300 ]; do
    kill -0 "${QEMU_PID}" 2>/dev/null || { log "qemu exited early; serial tail:"; tail -20 "${SER}" | sed 's/^/  /'; exit 1; }
    if curl -sf --max-time 5 "http://127.0.0.1:${MR_PORT}/server/info" 2>/dev/null | grep -q klippy_state; then up=1; break; fi
    sleep 5; w=$((w + 5))
done

kstate_of() {
    curl -s --max-time 5 "http://127.0.0.1:${MR_PORT}/printer/info" 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"].get("state","?"))' 2>/dev/null || echo "?"
}

if [ "${up}" -eq 1 ]; then
    # Settle klippy: two Linux-process MCUs can miss their identify window during
    # the boot I/O storm under TCG (eboard "Unable to connect" / "Lost
    # communication"). A FIRMWARE_RESTART once the system is quiet reliably
    # brings both MCUs up. Retry a few times.
    kstate="$(kstate_of)"
    r=0
    while [ "${kstate}" != "ready" ] && [ "${r}" -lt 6 ]; do
        log "klippy '${kstate}' — FIRMWARE_RESTART (attempt $((r + 1))) ..."
        curl -s --max-time 10 -X POST "http://127.0.0.1:${MR_PORT}/printer/firmware_restart" >/dev/null 2>&1 || true
        sleep 18
        kstate="$(kstate_of)"
        r=$((r + 1))
    done
    echo ""
    echo "  ===================================================================="
    echo "  ReForge stack UP after ${w}s.  klippy state: ${kstate}"
    echo ""
    echo "    Web UI (Mainsail):   http://localhost:${WEB_PORT}"
    echo "    Moonraker API:       http://localhost:${MR_PORT}/server/info"
    echo "    Camera (MJPEG):      http://localhost:${CAM_PORT}/?action=stream"
    echo "    SSH:                 ssh -p ${SSH_PORT} root@localhost"
    echo ""
    echo "  Serial log: ${SER}     Stop: kill ${QEMU_PID}"
    echo "  ===================================================================="
    echo ""
else
    log "Moonraker did not come up in ${w}s; serial tail:"; tail -25 "${SER}" | sed 's/^/  /'
fi

# DETACH=1: leave qemu running independently of this launcher (it is in its own
# session via setsid), disarm the cleanup trap, and exit. The VM then survives
# this process being reaped; stop it later with `kill ${QEMU_PID}`. Default
# (DETACH unset) holds in the foreground (Ctrl-C / kill stops the VM).
if [ "${DETACH:-0}" = 1 ]; then
    trap - EXIT INT TERM
    log "DETACHED — qemu pid ${QEMU_PID} keeps running. Stop with: kill ${QEMU_PID}"
    exit 0
fi

log "qemu running (pid ${QEMU_PID}) — holding. Ctrl-C or 'kill ${QEMU_PID}' to stop."
wait "${QEMU_PID}"
