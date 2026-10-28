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
# Knobs (env):
#   FX_SET="key=value ..."  rewrite forge-x mod variables in
#                           /opt/config/mod_data/variables.cfg, e.g.
#                           FX_SET="display='FEATHER' use_swap='OFF'". The probe
#                           launches klippy itself only when display is STOCK;
#                           other modes start it from forge-x's boot.sh.
#   FX_MOONRAKER_PROFILE=trim|lean  remove optional mod config sections
#   FX_MOONRAKER_MALLOC=1  test glibc trimming + disabled tcache (Moonraker only)
#   FX_MOONRAKER_JEMALLOC=PATH  preload source-built ARM library (Moonraker only)
#   KLIPPY_ARENA=N          export MALLOC_ARENA_MAX=N in /opt/klipper/start.sh
#                           (every klippy launch path runs it). The snapshot
#                           prints klippy's MALLOC_* environment as proof.
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
ROOTFS="${BUILD_DIR}/mem-probe-forgex-${LABEL}-rootfs.ext4"
DATA="${BUILD_DIR}/mem-probe-forgex-${LABEL}-data.ext4"
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
debugfs_inject() {  # <src-file-on-host> <dst-path-in-image> <mode-octal> [image]
    local src="$1" dst="$2" mode="$3" image="${4:-$ROOTFS}"
    local want; want=$(wc -c < "${src}")
    local got
    for _ in 1 2 3 4 5; do
        debugfs -w -R "rm ${dst}" "${image}" >/dev/null 2>&1 || true
        debugfs -w -R "write ${src} ${dst}" "${image}" >/dev/null 2>&1
        # The inode's file size sits on `... Project: N   Size: N`. Capture the
        # FIRST `Size: <digits>` in the stat output (Fragment's Size: 0 follows).
        got=$(debugfs -R "stat ${dst}" "${image}" 2>/dev/null \
            | grep -oE 'Size: [0-9]+' | head -n1 | awk '{print $2}')
        [ "${got}" = "${want}" ] && break
    done
    [ "${got}" = "${want}" ] || die "debugfs_inject ${dst}: size ${got} != ${want} after 5 retries"
    debugfs -w -R "sif ${dst} mode 0${mode}" "${image}" >/dev/null 2>&1 || true
}

# --- 1. neuter the firmwareExe UI line in /opt/auto_run.sh -------------------
log "patching /opt/auto_run.sh: skip ffstartup-arm (UI), keep everything else ..."
debugfs -R "dump /opt/auto_run.sh ${TMP}/auto_run.sh" "${ROOTFS}" 2>/dev/null
sed -i 's#^[[:space:]]*/opt/PROGRAM/ffstartup-arm.*#: "ffstartup-arm UI launch skipped by mem-probe-forgex.sh"#' "${TMP}/auto_run.sh"
debugfs_inject "${TMP}/auto_run.sh" "/opt/auto_run.sh" 100755

# --- 1b. forge-x variables + klippy allocator arenas -------------------------
VARS=/opt/config/mod_data/variables.cfg
debugfs -R "dump ${VARS} ${TMP}/variables.cfg" "${ROOTFS}" 2>/dev/null
[ -s "${TMP}/variables.cfg" ] || die "${VARS} missing from ${ROOTFS_SRC}"
for kv in ${FX_SET:-}; do
    key=${kv%%=*}
    grep -q "^${key} = " "${TMP}/variables.cfg" || die "FX_SET: ${key} not in ${VARS}"
    sed -i "s|^${key} = .*|${key} = ${kv#*=}|" "${TMP}/variables.cfg"
    log "variables.cfg: $(grep "^${key} = " "${TMP}/variables.cfg")"
done
[ -n "${FX_SET:-}" ] && debugfs_inject "${TMP}/variables.cfg" "${VARS}" 100644
DISPLAY_MODE=$(sed -n "s/^display = '\(.*\)'$/\1/p" "${TMP}/variables.cfg")
[ -n "${DISPLAY_MODE}" ] || die "no display mode in ${VARS}"
log "display mode: ${DISPLAY_MODE}"

if [ -n "${KLIPPY_ARENA:-}" ]; then
    debugfs -R "dump /opt/klipper/start.sh ${TMP}/klipper-start.sh" "${ROOTFS}" 2>/dev/null
    sed -i "1a export MALLOC_ARENA_MAX=${KLIPPY_ARENA}" "${TMP}/klipper-start.sh"
    debugfs_inject "${TMP}/klipper-start.sh" "/opt/klipper/start.sh" 100755
    log "klippy: MALLOC_ARENA_MAX=${KLIPPY_ARENA}"
fi
# Test only the mod environment: no stock Python/Klippy changes.
# FX_MOONRAKER_PROFILE: default, trim (OctoPrint/example webcam), lean
# (also history config + all update services; history still loads as a core component).
PROFILE=${FX_MOONRAKER_PROFILE:-default}
case "$PROFILE" in default|trim|lean) ;; *) die "unknown Moonraker profile: $PROFILE" ;; esac
if [ "$PROFILE" != default ]; then
    debugfs -R "dump /opt/config/mod/moonraker.conf ${TMP}/moonraker.conf" "$ROOTFS" 2>/dev/null
    python3 - "$TMP/moonraker.conf" "$PROFILE" <<'PYCONF'
import re
import sys
path, profile = sys.argv[1:]
text = open(path).read()
blocks = re.split(r'(?=^\[)', text, flags=re.M)
removed = []
kept = []
for block in blocks:
    section = block.split(']', 1)[0].lstrip('[').strip()
    drop = section == 'octoprint_compat' or section.startswith('webcam ')
    if profile == 'lean':
        drop |= section in ('history', 'feather_updates', 'update_manager') or section.startswith('update_manager ')
    if drop:
        removed.append(section)
    else:
        kept.append(block)
assert 'octoprint_compat' in removed, removed
assert any(b.startswith('[server]') for b in kept)
open(path, 'w').write(''.join(kept))
print('Moonraker removed sections:', removed)
PYCONF
    debugfs_inject "$TMP/moonraker.conf" /opt/config/mod/moonraker.conf 100644
fi
# FX_MOONRAKER_MALLOC=1: glibc trimming experiment, scoped to Moonraker.
if [ "${FX_MOONRAKER_MALLOC:-0}" = 1 ]; then
    debugfs -R "dump /opt/config/mod/.root/S65moonraker ${TMP}/S65moonraker" "$ROOTFS" 2>/dev/null
    sed -i '/export MALLOC_ARENA_MAX=2/a\    export MALLOC_TRIM_THRESHOLD_=0 MALLOC_MMAP_THRESHOLD_=131072 GLIBC_TUNABLES=glibc.malloc.tcache_count=0' "$TMP/S65moonraker"
    debugfs_inject "$TMP/S65moonraker" /opt/config/mod/.root/S65moonraker 100755
fi
# Optional source-built ARM jemalloc; preload only Moonraker in the mod chroot.
if [ -n "${FX_MOONRAKER_JEMALLOC:-}" ]; then
    [ -f "$FX_MOONRAKER_JEMALLOC" ] || die "jemalloc library missing"
    debugfs_inject "$FX_MOONRAKER_JEMALLOC" /.mod/.forge-x/usr/lib/libjemalloc-probe.so 100755 "$DATA"
    debugfs -R "dump /opt/config/mod/.root/S65moonraker ${TMP}/S65moonraker" "$ROOTFS" 2>/dev/null
    sed -i '/export MALLOC_ARENA_MAX=2/a\    export LD_PRELOAD=/usr/lib/libjemalloc-probe.so MALLOC_CONF=narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0' "$TMP/S65moonraker"
    debugfs_inject "$TMP/S65moonraker" /opt/config/mod/.root/S65moonraker 100755
fi
# Only the stock UI (skipped above) launches klippy in STOCK mode.
LAUNCH_KLIPPY=0
[ "${DISPLAY_MODE}" = STOCK ] && LAUNCH_KLIPPY=1
# Feather and Guppy draw on /dev/fb0; the stock display needs none.
GPU_ARGS=()
[ "${DISPLAY_MODE}" = STOCK ] || GPU_ARGS=(-device "virtio-gpu-pci,xres=800,yres=480")

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

  # STOCK mode: launch stock klippy directly (the ffstartup-arm UI is disabled).
  # /opt/klipper/start.sh sets up LD_LIBRARY_PATH + PATH and execs python3.7 klippy.py.
  if [ ${LAUNCH_KLIPPY} = 0 ]; then
    echo "[forgex-probe] display ${DISPLAY_MODE}: klippy started by forge-x boot.sh" > /dev/console
  elif [ -x /opt/klipper/start.sh ]; then
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
  echo "--- Moonraker API ---" > /dev/console
  wget -qO- http://127.0.0.1:7125/server/info > /dev/console
  echo "" > /dev/console
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
    case "\$cmd" in *moonraker.py*)
      echo "MOONRAKER-ENV \$(tr '\0' '\n' < "\$p/environ" | grep -E '^(MALLOC|GLIBC_TUNABLES|LD_PRELOAD)' | tr '\n' ' ')" > /dev/console
      grep jemalloc "\$p/maps" > /dev/console
    ;; esac
    case "\$cmd" in *klippy.py*)
      echo "KLIPPY-ENV PID \${p#/proc/} \$(tr '\0' '\n' < "\$p/environ" | grep '^MALLOC_' | tr '\n' ' ')" > /dev/console
      echo "KLIPPY-THREADS PID \${p#/proc/} \$(ls "\$p/task" | wc -l)" > /dev/console
    ;; esac
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
    "${GPU_ARGS[@]}" \
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
