#!/usr/bin/env bash
# =============================================================================
# mem-probe-forgex.sh — boot the forge-x rootfs under qemu virt at -m 128,
# bring up forge-x (moonraker in chroot) + stock klippy, skip the UI
# (firmwareExe), snapshot per-process Pss, power off.
#
# Apples-to-apples with mem-probe.sh (ReForge stack): same qemu-virt
# -m 128 -smp 2 cortex-a7, same SETTLE, same snapshot code.
#
# Forge-x's boot sequence:
#   inittab -> rcS -> /etc/init.d/S?? in order ->  /opt/auto_run.sh &
#     S00init (symlink -> /opt/config/mod/.shell/S00init)  forge-x takeover:
#                                                          mounts /data,
#                                                          chroots into the mod,
#                                                          launches Moonraker
#     auto_run.sh -> ffstartup-arm UI -> /opt/klipper/start.sh   (the UI launches klippy)
#
# To bring up klippy + moonraker WITHOUT the UI:
#   1. Pre-create /dev/mmcblk0p7 -> /dev/vdb symlink so S00init's
#      mount_data_partition finds /data (the virt board has no mmcblk0).
#   2. Neuter ffstartup-arm in /opt/auto_run.sh (skip the UI).
#   3. Inject S99forgex-probe to:
#        a. wait briefly for S00init to finish its chroot setup
#        b. launch /opt/klipper/start.sh directly (since ffstartup is gone)
#        c. sleep SETTLE; snapshot; poweroff
#
# Usage:    tests/qemu-harness/mem-probe-forgex.sh [LABEL]
# Output:   tests/qemu-harness/build/mem-probe-forgex-<LABEL>.log
# Needs:    qemu-system-arm, e2fsprogs, tests/qemu-harness/build/zImage,
#           tests/qemu-harness/build/forgex-rootfs.ext4 + forgex-data.ext4
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
ROOTFS_SRC="${BUILD_DIR}/forgex-rootfs.ext4"
DATA_SRC="${BUILD_DIR}/forgex-data.ext4"

LABEL="${1:-forgex}"
ROOTFS="${BUILD_DIR}/mem-probe-forgex-rootfs.ext4"
DATA="${BUILD_DIR}/mem-probe-forgex-data.ext4"
SERIAL="${BUILD_DIR}/mem-probe-forgex-${LABEL}.log"
SETTLE="${SETTLE:-60}"
KLIPPY_LEAD="${KLIPPY_LEAD:-15}"   # seconds to wait before launching klippy (let S00init settle)
MEM="${MEM:-128}"
SMP="${SMP:-2}"
TIMEOUT="${TIMEOUT:-360}"

log() { echo "[mem-probe-forgex] $*"; }
die() { echo "[mem-probe-forgex] ERROR: $*" >&2; exit 1; }

[ -f "${ZIMAGE}" ]     || die "virt kernel missing: ${ZIMAGE} (run: make qemu-kernel)"
[ -f "${ROOTFS_SRC}" ] || die "forge-x rootfs slice missing: ${ROOTFS_SRC}"
[ -f "${DATA_SRC}" ]   || die "forge-x /data slice missing: ${DATA_SRC}"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v debugfs >/dev/null         || die "debugfs not installed (e2fsprogs)"

log "preparing working copies of forge-x rootfs + /data ..."
cp -f "${ROOTFS_SRC}" "${ROOTFS}"
cp -f "${DATA_SRC}"   "${DATA}"
e2fsck -fy "${ROOTFS}" >/dev/null 2>&1 || true
e2fsck -fy "${DATA}"   >/dev/null 2>&1 || true
tune2fs -e continue "${ROOTFS}" >/dev/null 2>&1 || true
tune2fs -e continue "${DATA}"   >/dev/null 2>&1 || true

TMP=$(mktemp -d); trap 'rm -rf "${TMP}"' EXIT

# Robust debugfs writer: write + verify size, retry on truncation.
# Note: `debugfs stat` prints TWO lines starting with 'Size:' — the file size
# (`Size: <n>`) and a `Fragment:  Address: 0  Number: 0  Size: 0` line.
# We want the FIRST one only; the regex anchors on `^Size: <digits>$`.
debugfs_inject() {  # <src-file-on-host> <dst-path-in-image> <mode-octal>
    local src="$1" dst="$2" mode="$3"
    local want; want=$(wc -c < "${src}")
    local got
    for _ in 1 2 3 4 5; do
        debugfs -w -R "rm ${dst}" "${ROOTFS}" >/dev/null 2>&1 || true
        debugfs -w -R "write ${src} ${dst}" "${ROOTFS}" >/dev/null 2>&1
        # The inode's file size sits on `... Project: N   Size: N`. Capture the
        # FIRST `Size: <digits>` in the stat output (Fragment's Size: 0 follows).
        got=$(debugfs -R "stat ${dst}" "${ROOTFS}" 2>/dev/null \
            | grep -oE 'Size: [0-9]+' | head -n1 | awk '{print $2}')
        [ "${got}" = "${want}" ] && break
    done
    [ "${got}" = "${want}" ] || die "debugfs_inject ${dst}: size ${got} != ${want} after 5 retries"
    debugfs -w -R "sif ${dst} mode 0${mode}" "${ROOTFS}" >/dev/null 2>&1 || true
}

# --- 1. neuter the firmwareExe UI line in /opt/auto_run.sh -------------------
log "patching /opt/auto_run.sh: skip ffstartup-arm (UI), keep everything else ..."
debugfs -R "dump /opt/auto_run.sh ${TMP}/auto_run.sh" "${ROOTFS}" 2>/dev/null
sed -i 's#^[[:space:]]*/opt/PROGRAM/ffstartup-arm.*#: "ffstartup-arm UI launch skipped by mem-probe-forgex.sh"#' "${TMP}/auto_run.sh"
debugfs_inject "${TMP}/auto_run.sh" "/opt/auto_run.sh" 100755

# --- 2. inject S00-data-symlink: pre-create /dev/mmcblk0p7 -> /dev/vdb -------
# Must run BEFORE S00init (forge-x's takeover, which calls mount_data_partition).
# Init script numbering: S00init exists already, so we use S00aprep to sort earlier.
log "injecting S00aprep (mmcblk0p7 symlink so forge-x mount_data_partition works) ..."
cat > "${TMP}/S00aprep" <<'PREP'
#!/bin/sh
[ "$1" = start ] || exit 0
# Virt board has no mmcblk0; /data partition is on /dev/vdb. forge-x's S00init
# calls mount_data_partition which mounts /dev/mmcblk0p7. Make that path resolve
# to /dev/vdb so the rest of forge-x's boot proceeds normally.
[ -b /dev/mmcblk0p7 ] || ln -sf /dev/vdb /dev/mmcblk0p7
PREP
debugfs_inject "${TMP}/S00aprep" "/etc/init.d/S00aprep" 100755

# --- 3. inject S99forgex-probe: launch klippy, settle, snapshot, poweroff ----
log "injecting S99forgex-probe (klippy launch + snapshot + poweroff) ..."
cat > "${TMP}/S99forgex-probe" <<PROBE
#!/bin/sh
[ "\$1" = start ] || exit 0
(
  # Give S00init time to finish the forge-x chroot bring-up (moonraker etc.).
  sleep ${KLIPPY_LEAD}

  # Launch stock klippy directly (since ffstartup-arm UI is disabled).
  # /opt/klipper/start.sh sets up LD_LIBRARY_PATH + PATH and execs python3.7 klippy.py.
  if [ -x /opt/klipper/start.sh ]; then
    echo "[forgex-probe] launching /opt/klipper/start.sh ..."
    /opt/klipper/start.sh > /var/log/klippy-launch.log 2>&1 &
  else
    echo "[forgex-probe] WARN: /opt/klipper/start.sh missing" > /dev/console
  fi

  # Wait for the full SETTLE period.
  sleep ${SETTLE}

  echo "===MEMPROBE-BEGIN===" > /dev/console
  echo "PROBE=forgex SETTLE=${SETTLE} KLIPPY_LEAD=${KLIPPY_LEAD}" > /dev/console
  echo "--- meminfo (kB) ---" > /dev/console
  grep -E '^(MemTotal|MemFree|MemAvailable|Cached|Buffers|SwapTotal|SwapFree)' /proc/meminfo > /dev/console
  echo "--- zram ---" > /dev/console
  if [ -f /sys/block/zram0/mm_stat ]; then
    echo "zram0 disksize: \$(cat /sys/block/zram0/disksize)" > /dev/console
    echo "zram0 mm_stat : \$(cat /sys/block/zram0/mm_stat)" > /dev/console
  else
    echo "zram0: not present" > /dev/console
  fi
  echo "--- swaps ---" > /dev/console
  cat /proc/swaps > /dev/console 2>/dev/null
  echo "--- ALL processes Pss/Rss (kB) (no threshold; kthreads have Pss=0) ---" > /dev/console
  for p in /proc/[0-9]*; do
    [ -r "\$p/smaps_rollup" ] || continue
    pss=\$(awk '/^Pss:/{print \$2}' "\$p/smaps_rollup" 2>/dev/null)
    rss=\$(awk '/^Rss:/{print \$2}' "\$p/smaps_rollup" 2>/dev/null)
    cmd=\$(tr '\0' ' ' < "\$p/cmdline" 2>/dev/null | head -c 200)
    [ -z "\$cmd" ] && cmd="(kthread \$(cat \$p/comm 2>/dev/null))"
    echo "PID \${p#/proc/} Pss=\${pss:-0} Rss=\${rss:-0} CMD=\${cmd}" > /dev/console
  done
  echo "===MEMPROBE-END===" > /dev/console
  poweroff -f
) &
PROBE
debugfs_inject "${TMP}/S99forgex-probe" "/etc/init.d/S99forgex-probe" 100755

# --- 4. boot the probe ------------------------------------------------------
log "booting (MEM=${MEM} MiB, SMP=${SMP}, klippy_lead=${KLIPPY_LEAD}s, settle=${SETTLE}s) ..."
log "  vda = forge-x rootfs (p6)"
log "  vdb = forge-x /data    (p7; forge-x S00init mounts this at /data)"

timeout "${TIMEOUT}" qemu-system-arm \
    -M virt,highmem=off -cpu cortex-a7 -smp "${SMP}" -m "${MEM}" \
    -kernel "${ZIMAGE}" \
    -drive "file=${ROOTFS},if=virtio,format=raw" \
    -drive "file=${DATA},if=virtio,format=raw" \
    -append "root=/dev/vda rw console=ttyAMA0 panic=1 loglevel=4 init=/sbin/init" \
    -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
    -nographic > "${SERIAL}" 2>&1 || true

# --- 5. parse + summarize ---------------------------------------------------
echo ""
echo "========================= FORGE-X MEM SUMMARY: ${LABEL} (-m ${MEM}) ========================="
if grep -q '===MEMPROBE-BEGIN===' "${SERIAL}"; then
    sed -n '/===MEMPROBE-BEGIN===/,/===MEMPROBE-END===/p' "${SERIAL}" | grep -v '===MEMPROBE'
    echo ""
    echo "--- HOST STACK Pss (klippy + moonraker + the equivalents) ---"
    grep -E "^PID.*Pss=.*CMD=.*(klippy|moonraker|httpd|nginx)" "${SERIAL}" || echo "  (none found)"
    avail=$(grep -m1 MemAvailable "${SERIAL}" | awk '{print $2}')
    echo "SUMMARY  MemAvailable=${avail} kB"
else
    echo "PROBE DID NOT REPORT — boot may have failed. Last 80 lines of serial:"
    tail -80 "${SERIAL}"
fi
echo "serial log: ${SERIAL}"
echo "================================================================================"
