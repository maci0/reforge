#!/usr/bin/env bash
# =============================================================================
# mem-probe.sh — measure ReForge runtime memory under qemu at the real RAM size.
#
# Boots a ReForge rootfs (the full stack: klippy + moonraker + httpd + optional
# guppyscreen) under the virt test kernel with -m 128 (the AD5M Pro's RAM), lets
# Python settle, then dumps per-process Pss/Rss + /proc/meminfo + zram stats over
# the serial console and powers off. Parse the result for A/B memory experiments
# (baseline vs -OO vs arena=1 vs Thumb2/-Os rebuild).
#
# Usage:
#   sudo tests/qemu-harness/mem-probe.sh [ROOTFS_TAR] [LABEL]
#     ROOTFS_TAR : rootfs.tar[.xz]  (default: build/output/images/rootfs.tar.xz)
#     LABEL      : tag printed in the summary (default: basename of the tar)
#   MEM=128 SETTLE=25  override RAM (MiB) / settle seconds.
#
# Needs sudo (loop mount to build + inject into the ext4). Reuses build/zImage.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
MEM="${MEM:-128}"
SETTLE="${SETTLE:-25}"
TIMEOUT="${TIMEOUT:-180}"

ROOTFS_TAR="${1:-${REPO_ROOT}/build/output/images/rootfs.tar.xz}"
LABEL="${2:-$(basename "${ROOTFS_TAR}")}"

log() { echo "[mem-probe] $*"; }
die() { echo "[mem-probe] ERROR: $*" >&2; exit 1; }

[ -f "${ZIMAGE}" ]     || die "virt kernel missing: ${ZIMAGE} (run: make qemu-kernel)"
[ -f "${ROOTFS_TAR}" ] || die "rootfs not found: ${ROOTFS_TAR} (run: make rootfs)"
[ "$(id -u)" -eq 0 ]   || die "needs sudo (loop mount)"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"

WORK="$(mktemp -d)"
IMG="${BUILD_DIR}/mem-probe-rootfs.ext4"
SERIAL="${BUILD_DIR}/mem-probe-${LABEL//[^a-zA-Z0-9._-]/_}.log"
MNT="${WORK}/mnt"
cleanup() {
    mountpoint -q "${MNT}" 2>/dev/null && umount "${MNT}" 2>/dev/null || true
    rm -rf "${WORK}"
}
trap cleanup EXIT

# --- build an ext4 from the rootfs tar, inject the probe init ----------------
log "Building ext4 from ${ROOTFS_TAR} ..."
rm -f "${IMG}"
# 768 MiB is ample for the full stack; sparse so it costs little.
truncate -s 768M "${IMG}"
mkfs.ext4 -q -F "${IMG}"
mkdir -p "${MNT}"
mount -o loop "${IMG}" "${MNT}"
tar -C "${MNT}" -xf "${ROOTFS_TAR}"

# Optional runtime tweaks applied in-place (A/B against the same baseline rootfs).
#   TWEAKS=oo       -> run klippy+moonraker with python -OO (drop docstrings/asserts)
#   TWEAKS=arena1   -> MALLOC_ARENA_MAX=1 (tighter than the default 2)
#   TWEAKS=oo,arena1
K="${MNT}/etc/init.d/S60klipper"; M="${MNT}/etc/init.d/S65moonraker"
case ",${TWEAKS:-}," in *,oo,*)
    log "tweak: python -OO"
    sed -i 's#DAEMON_ARGS="/opt#DAEMON_ARGS="-OO /opt#' "$K" "$M" 2>/dev/null || true
;; esac
case ",${TWEAKS:-}," in *,arena1,*)
    log "tweak: MALLOC_ARENA_MAX=1"
    sed -i 's/MALLOC_ARENA_MAX=2/MALLOC_ARENA_MAX=1/' "$K" "$M" 2>/dev/null || true
;; esac

# Probe init: runs last (S98), after klipper/moonraker/httpd/guppyscreen.
cat > "${MNT}/etc/init.d/S98memprobe" <<PROBE
#!/bin/sh
[ "\$1" = start ] || exit 0
(
  sleep ${SETTLE}
  echo "===MEMPROBE-BEGIN==="
  echo "--- meminfo (kB) ---"
  grep -E '^(MemTotal|MemFree|MemAvailable|Cached|Buffers|SwapTotal|SwapFree)' /proc/meminfo
  echo "--- zram ---"
  if [ -f /sys/block/zram0/mm_stat ]; then
    echo "zram0 disksize: \$(cat /sys/block/zram0/disksize 2>/dev/null)"
    echo "zram0 mm_stat : \$(cat /sys/block/zram0/mm_stat)"
  else
    echo "zram0: not present"
  fi
  echo "--- per-process Pss/Rss (kB) ---"
  for p in /proc/[0-9]*; do
    [ -r "\$p/smaps_rollup" ] || continue
    cmd=\$(tr '\0' ' ' < "\$p/cmdline" 2>/dev/null)
    case "\$cmd" in
      *klippy*|*moonraker*|*guppyscreen*|*httpd*)
        pss=\$(awk '/^Pss:/{print \$2}' "\$p/smaps_rollup" 2>/dev/null)
        rss=\$(awk '/^Rss:/{print \$2}' "\$p/smaps_rollup" 2>/dev/null)
        echo "PID \${p#/proc/} Pss=\${pss} Rss=\${rss} CMD=\${cmd}"
      ;;
    esac
  done
  echo "===MEMPROBE-END==="
  poweroff -f
) > /dev/console 2>&1 &
PROBE
chmod +x "${MNT}/etc/init.d/S98memprobe"
sync
umount "${MNT}"
log "ext4 ready: ${IMG}"

# --- boot under the virt kernel at -m MEM ------------------------------------
log "Booting (MEM=${MEM} MiB, settle=${SETTLE}s) ..."
timeout "${TIMEOUT}" qemu-system-arm \
    -M virt,highmem=off -cpu cortex-a7 -m "${MEM}" \
    -kernel "${ZIMAGE}" \
    -drive "file=${IMG},if=virtio,format=raw" \
    -append "root=/dev/vda rw console=ttyAMA0 panic=1 loglevel=4" \
    -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
    -nographic > "${SERIAL}" 2>&1 || true

# --- parse + summarize -------------------------------------------------------
echo ""
echo "========================= MEM SUMMARY: ${LABEL} (-m ${MEM}) ========================="
if grep -q '===MEMPROBE-BEGIN===' "${SERIAL}"; then
    sed -n '/===MEMPROBE-BEGIN===/,/===MEMPROBE-END===/p' "${SERIAL}" | grep -v '===MEMPROBE'
    echo ""
    avail=$(sed -n '/===MEMPROBE-BEGIN===/,/===MEMPROBE-END===/p' "${SERIAL}" | awk '/MemAvailable/{print $2}')
    pss_sum=$(sed -n '/===MEMPROBE-BEGIN===/,/===MEMPROBE-END===/p' "${SERIAL}" | awk '/^PID /{for(i=1;i<=NF;i++) if($i ~ /^Pss=/){split($i,a,"=");s+=a[2]}} END{print s+0}')
    echo "SUMMARY  MemAvailable=${avail} kB   sum(tracked Pss)=${pss_sum} kB"
else
    echo "PROBE DID NOT REPORT — boot may have failed. Tail of serial:"
    tail -25 "${SERIAL}"
fi
echo "serial log: ${SERIAL}"
echo "================================================================================"
