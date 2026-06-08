#!/bin/bash
# =============================================================================
# stockui-realklippy-test.sh — stock FlashForge UI (firmwareExe) driven by
# ReForge's REAL upstream klippy, in qemu. The "stock UI on the ReForge stack"
# spike (docs/BACKLOG: stock-UI-on-ReForge).
#
# firmwareExe is a standard Klipper api_server client (/tmp/uds, 0x03-framed
# JSON — see docs/reverse-engineering/stock-ui/firmwareexe-local-print-api.md),
# so upstream klippy can serve it. This proves it end-to-end with the ACTUAL
# klippy binary (not the fake-klippy mock used by stockui-render.sh):
#
#   * /dev/mmcblk0p6 = stock golden rootfs — firmwareExe + its Qt4 env.
#   * /data (mmcblk0p7) holds the ReForge rootfs at .mod/.reforge — our klippy.
#   * auto_run.sh bind-mounts /data/.mod/.reforge at /reforge, sets up the chroot mounts (bind /tmp),
#     and inside the chroot runs klipper_mcu sims + real klippy on `-a /tmp/uds`.
#     /tmp is bind-shared, so the socket klippy creates in the chroot is the same
#     /tmp/uds firmwareExe connects to on the stock side. Exactly the production
#     STOCK_UI model (firmwareExe on stock side, our klippy in the /reforge chroot).
#   * mcu-sim.py still provides /dev/ttyS1+ttyS5 for firmwareExe's own serial gate.
#
# Config: build/output/.../sim-printer.cfg (kinematics:none — klippy reaches
# "ready"). Swap in the stock FF printer.cfg once the sim MCU grows real pins.
#
# Usage:  tests/qemu-harness/stockui-realklippy-test.sh      # NO sudo
# Output: build/stockui-realklippy.ppm + .../stockui-realklippy-serial.log
# Needs:  qemu-system-arm, debugfs/mke2fs (e2fsprogs), socat, gzip, sfdisk,
#         build/zImage (make qemu-kernel), tools/recovery/golden.img.gz,
#         build/output/images/rootfs.tar (make rootfs), klipper_mcu (built here).
# =============================================================================
set -euo pipefail

TAG=stockui-rk
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SELF_DIR}/lib/common.sh"   # REPO_ROOT, QH_DIR, BUILD_DIR, log/die/skip, need_cmd
. "${SELF_DIR}/lib/inject.sh"   # robust_inject
. "${SELF_DIR}/lib/golden.sh"   # golden_p6_ext4
. "${SELF_DIR}/lib/rootfs.sh"   # rootfs_tar / stage_rootfs
. "${SELF_DIR}/lib/emmc.sh"     # emmc_build, EMMC_QEMU_ARGS, EMMC_ROOT

HARNESS_DIR="${QH_DIR}"
SIM_DIR="${QH_DIR}/stockui"
ZIMAGE="${BUILD_DIR}/zImage"
IMG="${BUILD_DIR}/stockui-realklippy-root.ext4"       # eMMC p6 = stock rootfs (firmwareExe)
P7_IMG="${BUILD_DIR}/stockui-realklippy-data.ext4"    # eMMC p7 = /data (holds .mod/.reforge)
EMMC_IMG="${BUILD_DIR}/stockui-realklippy-emmc.img"   # production-shape GPT eMMC -> /dev/mmcblk0
SIM_CFG="${QH_DIR}/configs/sim-printer.cfg"
MON="${BUILD_DIR}/qemu-stockui-rk-mon.sock"
SHOT="${BUILD_DIR}/stockui-realklippy.ppm"
SER="${BUILD_DIR}/stockui-realklippy-serial.log"
MEM="${MEM:-320}"
SETTLE="${SETTLE:-110}"
PY="/opt/Python-3.7.11/bin/python3.7"

[ -f "${ZIMAGE}" ] || die "virt kernel missing: ${ZIMAGE} (run: make qemu-kernel)"
need_cmd qemu-system-arm debugfs mke2fs socat sfdisk
ROOTFS_TAR="$(rootfs_tar)" || skip "no rootfs.tar (make rootfs)"

# --- klipper_mcu (Linux-process MCU sim) -------------------------------------
KLIPPER_MCU="${BUILD_DIR}/klipper_mcu"
[ -x "${KLIPPER_MCU}" ] || "${HARNESS_DIR}/build-klipper-mcu.sh" >/dev/null 2>&1 || true
[ -x "${KLIPPER_MCU}" ] || skip "could not build klipper_mcu"

# --- 1. stock golden p6 -> working firmwareExe rootfs (lib/golden.sh) ---------
log "preparing firmwareExe rootfs (stock p6) ${IMG}"
golden_p6_ext4 "${IMG}" || skip "no golden.img.gz (stock rootfs for firmwareExe)"

# --- 2. eMMC p7 = /data, with the ReForge rootfs at its REAL install location -
# /data/.mod/.reforge — exactly where the installer puts it and reforge-boot
# bind-mounts it from. + klipper_mcu (Linux host MCU) + the sim printer.cfg.
log "staging /data (p7) with ReForge rootfs at /data/.mod/.reforge ..."
STAGE="$(mktemp -d "${BUILD_DIR}/.rk-stage-XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT
RFS="${STAGE}/.mod/.reforge"
mkdir -p "${RFS}"
tar -C "${RFS}" -xf "${ROOTFS_TAR}"
[ -f "${RFS}/opt/klipper/klippy/klippy.py" ] || die "rootfs has no /opt/klipper/klippy (old/wrong build)"
install -m 0755 "${KLIPPER_MCU}" "${RFS}/opt/klipper/klipper_mcu"
install -D -m 0644 "${SIM_CFG}" "${RFS}/etc/reforge/sim-printer.cfg"
mkext4 "${P7_IMG}" 1200M UDISK "${STAGE}"   # ^orphan_file so the 5.4 guest mounts it

# --- 3. inject mcu-sim (firmwareExe serial gate) + marker; patch auto_run.sh --
# robust_inject from lib/inject.sh — 3-arg: <img> <src> <dst>
log "injecting mcu-sim + marker"
robust_inject "${IMG}" "${SIM_DIR}/mcu-sim.py" /opt/mcu-sim.py
: > "${BUILD_DIR}/.rk-marker"; robust_inject "${IMG}" "${BUILD_DIR}/.rk-marker" /etc/reforge-stockreal

# scrub captured device state (power-loss modal + real serial + slicer nag)
debugfs -w -R "rm /opt/config/PowerOff" "${IMG}" >/dev/null 2>&1 || true
A5M="${BUILD_DIR}/.A5M.json"
if debugfs -R "cat /opt/config/Adventurer5M.json" "${IMG}" 2>/dev/null > "${A5M}" && [ -s "${A5M}" ]; then
    sed -i 's/"SN[A-Z0-9]\{6,\}"/"REFORGE-DEMO"/g; s/"CheckAppFrist"[[:space:]]*:[[:space:]]*true/"CheckAppFrist" : false/g' "${A5M}"
    robust_inject "${IMG}" "${A5M}" /opt/config/Adventurer5M.json
fi

log "patching /opt/auto_run.sh — bind /data/.mod/.reforge -> /reforge, chroot, real klippy on /tmp/uds"
AR="${BUILD_DIR}/.auto_run.sh"
debugfs -R "cat /opt/auto_run.sh" "${IMG}" 2>/dev/null > "${AR}"
if ! grep -q reforge-stockreal "${AR}"; then
    awk '/\/opt\/PROGRAM\/ffstartup-arm -f/ && !done {
        print "if [ -f /etc/reforge-stockreal ]; then";
        print "  grep -q devpts /proc/mounts || mount -t devpts devpts /dev/pts 2>/dev/null";
        print "  P=/opt/Python-3.7.11/bin/python3.7";
        print "  # firmwareExe boot gate: ttyS1/ttyS5 ptys";
        print "  \"$P\" /opt/mcu-sim.py /dev/ttyS1 &";
        print "  \"$P\" /opt/mcu-sim.py /dev/ttyS5 &";
        print "  # /data = eMMC p7 (mmcblk0p7); ReForge is installed at /data/.mod/.reforge,";
        print "  # bind-mounted to /reforge exactly like reforge-boot does on real hw.";
        print "  grep -q \" /data \" /proc/mounts || { mkdir -p /data; mount -t ext4 /dev/mmcblk0p7 /data 2>/dev/null; }";
        print "  mkdir -p /reforge && mount --bind /data/.mod/.reforge /reforge 2>/dev/null";
        print "  for d in proc sys dev run tmp; do mkdir -p /reforge/$d; done";
        print "  mount -t proc proc /reforge/proc 2>/dev/null";
        print "  mount --rbind /sys /reforge/sys 2>/dev/null";
        print "  mount --rbind /dev /reforge/dev 2>/dev/null";
        print "  mount --bind /run /reforge/run 2>/dev/null";
        print "  mount --bind /tmp /reforge/tmp 2>/dev/null";
        print "  # real klippy + sim MCUs inside the chroot, API socket on /tmp/uds";
        print "  chroot /reforge /bin/sh -c \x27echo [chroot] starting host MCU + klippy >/dev/console; /opt/klipper/klipper_mcu /tmp/klipper_host_mcu >/dev/console 2>&1 & /opt/klipper/klipper_mcu /tmp/klipper_eboard_mcu >/dev/console 2>&1 & i=0; while { [ ! -e /tmp/klipper_host_mcu ] || [ ! -e /tmp/klipper_eboard_mcu ]; } && [ $i -lt 20 ]; do sleep 0.5; i=$((i+1)); done; echo [chroot] py-check: $(/usr/bin/python3 -c \x22import sys;print(sys.version.split()[0])\x22 2>&1) >/dev/console; echo [chroot] launching klippy via exec >/dev/console; exec /usr/bin/python3 /opt/klipper/klippy/klippy.py /etc/reforge/sim-printer.cfg -a /tmp/uds -l /dev/console >/dev/console 2>&1\x27 &";
        print "  touch /tmp/printer";
        print "  i=0; while [ ! -e /dev/ttyS1 ] || [ ! -e /dev/ttyS5 ]; do i=$((i+1)); [ \"$i\" -ge 60 ] && break; sleep 0.5; done";
        print "  i=0; while [ ! -S /tmp/uds ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i+1)); done";
        print "  sleep 2";
        print "fi";
        done=1
    } {print}' "${AR}" > "${AR}.new"
    robust_inject "${IMG}" "${AR}.new" /opt/auto_run.sh
    inject_chmod "${IMG}" /opt/auto_run.sh 00755
fi
: "${PY:?}"

# --- 4. assemble the production-shape eMMC (p6 = stock rootfs, p7 = /data) ----
# Real HW device names: the GPT eMMC appears as /dev/mmcblk0p1..p7 in the guest
# (sdhci-pci + emmc), exactly like the onboard eMMC — not virtio vda/vdb.
log "assembling production eMMC (p6=stock rootfs, p7=/data w/ .mod/.reforge) ..."
emmc_build "${IMG}" "${P7_IMG}" "${EMMC_IMG}"   # -> EMMC_QEMU_ARGS + EMMC_ROOT (/dev/mmcblk0p6)

# --- 5. boot from eMMC (/dev/mmcblk0p6), screendump --------------------------
pkill -9 -u "$(id -u)" qemu-system-arm 2>/dev/null || true; sleep 1
rm -f "${MON}" "${SHOT}" "${SER}"
log "booting qemu (MEM=${MEM} MiB, settle=${SETTLE}s) ..."
# shellcheck disable=SC2086  # EMMC_QEMU_ARGS is a word-split arg list by design
qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -m "${MEM}" \
    -kernel "${ZIMAGE}" \
    -append "console=ttyAMA0,115200 loglevel=4 ${EMMC_ROOT} rw rootwait" \
    -display none -monitor "unix:${MON},server,nowait" -serial file:"${SER}" \
    -device virtio-gpu-pci,xres=800,yres=480 -device virtio-keyboard-pci \
    ${EMMC_QEMU_ARGS} \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 >/dev/null 2>&1 &
QP=$!
trap 'kill -9 "${QP}" 2>/dev/null || true; rm -rf "${STAGE}"' EXIT
for _ in $(seq 1 20); do [ -S "${MON}" ] && break; sleep 1; done
[ -S "${MON}" ] || die "qemu monitor socket never appeared"
sleep "${SETTLE}"

# dismiss firmwareExe's one-time restart modal (E0120). The modal pops when
# firmwareExe sees klippy do its initial firmware_restart, i.e. AFTER settle, so
# press the focused Ok a few times across the likely key bindings.
for _ in 1 2 3; do
    for k in ret kp_enter spc; do
        printf 'sendkey %s\n' "$k" | socat - "unix-connect:${MON}" >/dev/null 2>&1 || true
        sleep 0.4
    done
done
sleep 3

log "screendump -> ${SHOT}"
printf 'screendump %s\n' "${SHOT}" | socat - "unix-connect:${MON}" >/dev/null 2>&1 || true
sleep 2
[ -s "${SHOT}" ] || die "no screendump produced (see ${SER})"

# --- 5. verdict: klippy ready on /tmp/uds + firmwareExe rendered --------------
log "=== checks ==="
RC=0
# Klipper-ready evidence: it loads + configures both MCUs, then emits periodic
# "Stats N.N:" heartbeats only once it has reached the ready/running main loop.
if grep -qE "Configured MCU 'mcu'" "${SER}" 2>/dev/null \
   && grep -qE '^Stats [0-9]+\.[0-9]+:' "${SER}" 2>/dev/null; then
    echo "  [PASS] real klippy reached ready (serial log)"
else
    echo "  [WARN] no klippy-ready evidence in serial (check serial console)"; RC=1
fi
NONBLANK=$(python3 - "$SHOT" <<'PY' 2>/dev/null || echo 0
import sys
d=open(sys.argv[1],'rb').read()
i=d.find(b'\n',d.find(b'\n',d.find(b'\n')+1)+1)+1
print(len(set(d[i:i+200000]))>4 and 1 or 0)
PY
)
[ "${NONBLANK}" = "1" ] && echo "  [PASS] firmwareExe rendered a non-blank framebuffer" \
    || { echo "  [FAIL] framebuffer blank — firmwareExe did not render"; RC=1; }
echo "  shot:   ${SHOT}  (convert: magick ${SHOT} out.png)"
echo "  serial: ${SER}"
exit "${RC}"
