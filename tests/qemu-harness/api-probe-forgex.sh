#!/usr/bin/env bash
# Boot forge-x beta under qemu virt and expose guest Moonraker on
# 127.0.0.1:18125. Read-only curls from the host. The qemu process is killed
# from the host. This script never reboots or powers off the host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
ROOTFS_SRC="${BUILD_DIR}/forgex-rootfs.ext4"
DATA_SRC="${BUILD_DIR}/forgex-data.ext4"
ROOTFS="${BUILD_DIR}/api-probe-forgex-rootfs.ext4"
DATA="${BUILD_DIR}/api-probe-forgex-data.ext4"
SERIAL="${BUILD_DIR}/api-probe-forgex.log"
HOST_PORT="${HOST_PORT:-18125}"
KLIPPY_PORT="${KLIPPY_PORT:-17130}"
# Static arm-linux-musleabihf phobos. Empty leaves the guest on Moonraker only.
# Phobos listens on guest :7126 and never takes Moonraker's :7125.
PHOBOS_BIN="${PHOBOS_BIN:-}"
PHOBOS_HOST_PORT="${PHOBOS_HOST_PORT:-17126}"
MEM="${MEM:-256}"
SMP="${SMP:-2}"
TIMEOUT="${TIMEOUT:-360}"
OUT_DIR="${OUT_DIR:-${BUILD_DIR}/api-probe-forgex}"

log() { echo "[api-probe-forgex] $*"; }
die() { echo "[api-probe-forgex] ERROR: $*" >&2; exit 1; }

[ -f "${ZIMAGE}" ] || die "virt kernel missing: ${ZIMAGE}"
[ -f "${ROOTFS_SRC}" ] || die "forge-x rootfs slice missing: ${ROOTFS_SRC}"
[ -f "${DATA_SRC}" ] || die "forge-x /data slice missing: ${DATA_SRC}"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v debugfs >/dev/null || die "debugfs not installed"

if ss -ltn | awk '{print $4}' | grep -q ":${HOST_PORT}$"; then
    die "host port ${HOST_PORT} is already in use"
fi
if [ -n "${PHOBOS_BIN}" ]; then
    [ -f "${PHOBOS_BIN}" ] || die "phobos binary missing: ${PHOBOS_BIN}"
    if ss -ltn | awk '{print $4}' | grep -q ":${PHOBOS_HOST_PORT}$"; then
        die "host port ${PHOBOS_HOST_PORT} is already in use"
    fi
fi

log "preparing working copies (golden images stay read-only) ..."
cp -f "${ROOTFS_SRC}" "${ROOTFS}"
cp -f "${DATA_SRC}" "${DATA}"
e2fsck -fy "${ROOTFS}" >/dev/null 2>&1 || true
e2fsck -fy "${DATA}" >/dev/null 2>&1 || true
tune2fs -e continue "${ROOTFS}" >/dev/null 2>&1 || true
tune2fs -e continue "${DATA}" >/dev/null 2>&1 || true

TMP=$(mktemp -d)
QPID=""
cleanup() {
    if [ -n "${QPID}" ]; then
        kill "${QPID}" 2>/dev/null || true
        wait "${QPID}" 2>/dev/null || true
    fi
    rm -rf "${TMP}"
}
trap cleanup EXIT

debugfs_inject() {
    local src="$1" dst="$2" mode="$3"
    local want got
    want=$(wc -c < "${src}")
    for _ in 1 2 3 4 5; do
        debugfs -w -R "rm ${dst}" "${ROOTFS}" >/dev/null 2>&1 || true
        debugfs -w -R "write ${src} ${dst}" "${ROOTFS}" >/dev/null 2>&1
        got=$(debugfs -R "stat ${dst}" "${ROOTFS}" 2>/dev/null \
            | grep -oE 'Size: [0-9]+' | head -n1 | awk '{print $2}')
        [ "${got}" = "${want}" ] && break
    done
    [ "${got}" = "${want}" ] || die "debugfs_inject ${dst}: size ${got} != ${want}"
    debugfs -w -R "sif ${dst} mode 0${mode}" "${ROOTFS}" >/dev/null 2>&1 || true
}

log "patching /opt/auto_run.sh: skip ffstartup-arm ..."
debugfs -R "dump /opt/auto_run.sh ${TMP}/auto_run.sh" "${ROOTFS}" 2>/dev/null
sed -i 's#^[[:space:]]*/opt/PROGRAM/ffstartup-arm.*#: "ffstartup-arm UI launch skipped by api-probe-forgex.sh"#' "${TMP}/auto_run.sh"
debugfs_inject "${TMP}/auto_run.sh" "/opt/auto_run.sh" 100755

debugfs_inject "${HARNESS_DIR}/board_mcu.py" "/opt/board_mcu.py" 100755
cat > "${TMP}/uds-bridge.py" <<'PY'
import os, select, socket, threading, time
def splice(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 30)
            if not r:
                continue
            for s in r:
                try:
                    data = s.recv(65536)
                except Exception:
                    return
                if not data:
                    return
                other = b if s is a else a
                other.sendall(data)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try:
                s.close()
            except Exception:
                pass
def handle(conn):
    u = None
    for _ in range(100):
        try:
            u = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            u.connect("/tmp/uds")
            break
        except Exception:
            time.sleep(0.1)
            u = None
    if u is None:
        conn.close()
        return
    splice(conn, u)
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 7130))
s.listen(8)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,)).start()
PY
debugfs_inject "${TMP}/uds-bridge.py" "/opt/uds-bridge.py" 100644

if [ -n "${PHOBOS_BIN}" ]; then
    log "injecting phobos ($(wc -c < "${PHOBOS_BIN}") bytes) on guest :7126 ..."
    debugfs_inject "${PHOBOS_BIN}" "/opt/phobos-bin" 100755
    # Forge-x moonraker.conf, with provider none so this process cannot run
    # the guest poweroff/reboot scripts under .root/. Port 7126 leaves
    # Moonraker on 7125. Reboot and shutdown stay no-ops in the binary.
    cat > "${TMP}/phobos.cfg" <<'CFG'
[server]
host: 0.0.0.0
port: 7126
klippy_uds_address: /tmp/uds

[klippy_apis]
hidden_objects:
    output_pin level_h1
    output_pin level_h2
    output_pin level_h3
    output_pin level_clear
    output_pin power_off
    output_pin clear_power_off

[machine]
provider: none

[file_manager]
file_system_observer: none
excludes:
    gcodes/.mod
    gcodes/logFiles
    gcodes/lost+found
    config/mod/.bin
    config/mod/.git
    config/mod/.py
    config/mod/.root
    config/mod/.shell
    config/mod/.zsh
    config/mod/tests
    config/mod_data/log
    config/mod_data/database

[authorization]
enable_api_key: false
trusted_clients:
    0.0.0.0/0
cors_domains:
    *

[octoprint_compat]

[history]

[webcam cam]
enabled: true
icon: mdiWebcam
service: mjpegstreamer
stream_url: /webcam/?action=stream
snapshot_url: /webcam/?action=snapshot

[update_manager]
enable_auto_refresh: False
enable_system_updates: False

[feather_updates]
update_key: forge-x

[update_manager forge-x]
type: git_repo
channel: dev
path: /opt/config/mod
origin: https://github.com/DrA1ex/ff5m.git
primary_branch: 1.4.2
managed_services: forge-x

[update_manager fluidd]
type: web
repo: fluidd-core/fluidd
path: /root/www/fluidd

[update_manager mainsail]
type: web
channel: stable
repo: DrA1ex/mainsail
path: /root/www/mainsail

[update_manager guppyscreen]
type: zip
channel: stable
path: /root/guppyscreen
repo: DrA1ex/guppyscreen
managed_services: guppyscreen
CFG
    debugfs_inject "${TMP}/phobos.cfg" "/opt/phobos.cfg" 100644
fi

cat > "${TMP}/S00aprep" <<'PREP'
#!/bin/sh
[ "$1" = start ] || exit 0
[ -b /dev/mmcblk0p7 ] || ln -sf /dev/vdb /dev/mmcblk0p7
# Main board (/dev/ttyS5) and toolhead (/dev/ttyS1) before Klippy or boot_mcu.
export LD_LIBRARY_PATH=/opt/Python-3.7.11/lib:/opt/openssl-1.0.2d/lib:/opt/libffi-3.4.4/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
PY=/opt/Python-3.7.11/bin/python3.7
[ -x "$PY" ] || PY=/usr/bin/python3
if [ -f /opt/board_mcu.py ]; then
  "$PY" /opt/board_mcu.py /dev/ttyS5 main >/var/log/board-mcu-main.log 2>&1 &
  "$PY" /opt/board_mcu.py /dev/ttyS1 eboard >/var/log/board-mcu-eboard.log 2>&1 &
  echo "[api-probe] board mcus started with $PY" > /dev/console
fi
PREP
debugfs_inject "${TMP}/S00aprep" "/etc/init.d/S00aprep" 100755

# Bring up the virt NIC and announce when Moonraker is listening. The guest
# stays up; the host kills qemu. No guest poweroff, so a stuck script cannot
# be confused with a host shutdown.
cat > "${TMP}/S99api-probe" <<'PROBE'
#!/bin/sh
[ "$1" = start ] || exit 0
(
  sleep 8
  if [ -x /opt/klipper/start.sh ]; then
    echo "[api-probe] launching /opt/klipper/start.sh" > /dev/console
    /opt/klipper/start.sh > /var/log/klippy-launch.log 2>&1 &
  else
    echo "[api-probe] WARN: /opt/klipper/start.sh missing" > /dev/console
  fi
  for i in /sys/class/net/*; do
    n=${i##*/}
    [ "$n" = "lo" ] && continue
    ip link set "$n" up 2>/dev/null || true
    if command -v udhcpc >/dev/null 2>&1; then
      udhcpc -i "$n" -n -q -t 5 -T 2 >/dev/null 2>&1 || true
    fi
    ip -4 addr show "$n" > /dev/console 2>/dev/null || true
  done
  ip addr add 10.0.2.15/24 dev eth0 2>/dev/null || true
  ip route add default via 10.0.2.2 dev eth0 2>/dev/null || true
  i=0
  while [ "$i" -lt 80 ]; do
    if grep -qi ':1BD5 ' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
      if [ -x /opt/Python-3.7.11/bin/python3.7 ] && [ -f /opt/uds-bridge.py ]; then
        echo "[api-probe] klippy uds bridge :7130" > /dev/console
        LD_LIBRARY_PATH=/opt/Python-3.7.11/lib:/opt/openssl-1.0.2d/lib:/opt/libffi-3.4.4/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} \
          /opt/Python-3.7.11/bin/python3.7 /opt/uds-bridge.py >/var/log/uds-bridge.log 2>&1 &
      fi
      if [ -x /opt/phobos-bin ] && [ -f /opt/phobos.cfg ]; then
        echo "[api-probe] phobos :7126" > /dev/console
        # Keep the two daemons on separate databases.
        mkdir -p /root/phobos-probe-data
        for dir in config logs gcodes; do
          ln -s /root/printer_data/"$dir" /root/phobos-probe-data/"$dir"
        done
        /opt/phobos-bin -c /opt/phobos.cfg -d /root/phobos-probe-data >/var/log/phobos.log 2>&1 &
      fi
      echo "===APIPROBE-UP===" > /dev/console
      ip -4 addr > /dev/console 2>/dev/null || true
      (
        sleep 15
        echo "===KLILOG===" > /dev/console
        tail -c 4000 /data/logFiles/printer.log > /dev/console 2>/dev/null
        echo > /dev/console
        echo "===MCU-MAIN===" > /dev/console
        tail -c 1500 /var/log/board-mcu-main.log > /dev/console 2>/dev/null
        echo > /dev/console
        echo "===MCU-EBOARD===" > /dev/console
        tail -c 1500 /var/log/board-mcu-eboard.log > /dev/console 2>/dev/null
        echo > /dev/console
        echo "===KLILOG-END===" > /dev/console
      ) &
      exit 0
    fi
    i=$((i + 1))
    sleep 2
  done
  echo "===APIPROBE-DOWN===" > /dev/console
) &
PROBE
debugfs_inject "${TMP}/S99api-probe" "/etc/init.d/S99api-probe" 100755

mkdir -p "${OUT_DIR}"
: > "${OUT_DIR}/results.txt"
NETDEV="user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:7125,hostfwd=tcp:127.0.0.1:${KLIPPY_PORT}-:7130"
if [ -n "${PHOBOS_BIN}" ]; then
    NETDEV="${NETDEV},hostfwd=tcp:127.0.0.1:${PHOBOS_HOST_PORT}-:7126"
fi
log "booting (MEM=${MEM} MiB, hostfwd 127.0.0.1:${HOST_PORT} -> guest :7125) ..."
qemu-system-arm \
    -M virt,highmem=off -cpu cortex-a7 -smp "${SMP}" -m "${MEM}" \
    -kernel "${ZIMAGE}" \
    -drive "file=${ROOTFS},if=virtio,format=raw" \
    -drive "file=${DATA},if=virtio,format=raw" \
    -append "root=/dev/vda rw console=ttyAMA0 panic=1 loglevel=4 init=/sbin/init" \
    -netdev "${NETDEV}" \
    -device virtio-net-device,netdev=n0 \
    -nographic > "${SERIAL}" 2>&1 &
QPID=$!

deadline=$((SECONDS + TIMEOUT))
up=0
while [ "${SECONDS}" -lt "${deadline}" ]; do
    if ! kill -0 "${QPID}" 2>/dev/null; then
        die "qemu exited before Moonraker listened. See ${SERIAL}"
    fi
    if grep -q '===APIPROBE-UP===' "${SERIAL}" 2>/dev/null; then
        up=1
        break
    fi
    if grep -q '===APIPROBE-DOWN===' "${SERIAL}" 2>/dev/null; then
        break
    fi
    sleep 2
done

if [ "${up}" != 1 ]; then
    echo "PROBE DID NOT SEE MOONRAKER. Last 80 serial lines:"
    tail -80 "${SERIAL}" || true
    exit 1
fi

log "guest Moonraker is listening; waiting for Klippy ready ..."
klippy_wait_deadline=$((SECONDS + 120))
ready=0
while [ "${SECONDS}" -lt "${klippy_wait_deadline}" ]; do
    if ! kill -0 "${QPID}" 2>/dev/null; then
        die "qemu exited while waiting for Klippy. See ${SERIAL}"
    fi
    code=$(curl -sS -m 5 -o "${OUT_DIR}/guest-printer-info-wait.body" -w '%{http_code}' \
        "http://127.0.0.1:${HOST_PORT}/printer/info" || echo curl_fail)
    if grep -q '"state": *"ready"' "${OUT_DIR}/guest-printer-info-wait.body" 2>/dev/null; then
        ready=1
        log "printer/info state=ready (${code})"
        break
    fi
    sleep 2
done
if [ "${ready}" != 1 ]; then
    echo "printer did not reach ready. Last serial lines:"
    tail -120 "${SERIAL}" || true
    exit 1
fi

log "curling read-only endpoints ..."
fail=0
for path in \
    /server/info \
    /printer/info \
    /server/notifiers/list \
    /server/analysis/status \
    /server/analysis/estimate \
    /machine/update/status \
    /server/files/roots
do
    name=$(echo "${path}" | tr '/' '-')
    code=$(curl -sS -m 15 -o "${OUT_DIR}/guest${name}.body" -w '%{http_code}' \
        -X GET "http://127.0.0.1:${HOST_PORT}${path}" || echo curl_fail)
    echo "${code} GET ${path}" | tee -a "${OUT_DIR}/results.txt"
    if [[ "${code}" == *curl_fail ]]; then
        fail=1
    fi
done

if [ -n "${PHOBOS_BIN}" ]; then
    log "waiting for in-guest phobos on 127.0.0.1:${PHOBOS_HOST_PORT} ..."
    phobos_deadline=$((SECONDS + 90))
    phobos_up=0
    while [ "${SECONDS}" -lt "${phobos_deadline}" ]; do
        if ! kill -0 "${QPID}" 2>/dev/null; then
            die "qemu exited while waiting for phobos. See ${SERIAL}"
        fi
        code=$(curl -sS -m 5 -o "${OUT_DIR}/guest-phobos-info.body" -w '%{http_code}' \
            "http://127.0.0.1:${PHOBOS_HOST_PORT}/printer/info" || echo curl_fail)
        if grep -q '"state": *"ready"' "${OUT_DIR}/guest-phobos-info.body" 2>/dev/null; then
            phobos_up=1
            log "phobos printer/info state=ready (${code})"
            break
        fi
        sleep 2
    done
    if [ "${phobos_up}" != 1 ]; then
        echo "in-guest phobos did not reach ready. Last serial lines:"
        tail -80 "${SERIAL}" || true
        exit 1
    fi
fi

if [ "${STAY:-0}" = 1 ]; then
    log "staying up. moonraker=127.0.0.1:${HOST_PORT} klippy-tcp=127.0.0.1:${KLIPPY_PORT} phobos=127.0.0.1:${PHOBOS_HOST_PORT} pid=${QPID}"
    wait "${QPID}" || true
    QPID=""
    exit 0
fi

log "stopping qemu pid ${QPID}"
kill "${QPID}" 2>/dev/null || true
wait "${QPID}" 2>/dev/null || true
QPID=""
log "serial log: ${SERIAL}"
log "bodies: ${OUT_DIR}"
exit "${fail}"
