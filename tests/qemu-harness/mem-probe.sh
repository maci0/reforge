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
# Builds the ext4 rootless via mke2fs -d (no loop mount, no sudo). Reuses build/zImage.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
# Defaults match real AD5M Pro silicon (Allwinner T113-S3, dual Cortex-A7,
# 128 MB DRAM). docs/optimizations.md quotes measurements at `-m 128 -smp 2`,
# so the SMP default is 2 to match (override via env if you want a single-core
# A/B). `MEM` and `SETTLE` are env-overridable for variant runs.
MEM="${MEM:-128}"
SMP="${SMP:-2}"
SETTLE="${SETTLE:-25}"
TIMEOUT="${TIMEOUT:-180}"

ROOTFS_TAR="${1:-${REPO_ROOT}/build/output/images/rootfs.tar.xz}"
LABEL="${2:-$(basename "${ROOTFS_TAR}")}"

log() { echo "[mem-probe] $*"; }
die() { echo "[mem-probe] ERROR: $*" >&2; exit 1; }

[ -f "${ZIMAGE}" ]     || die "virt kernel missing: ${ZIMAGE} (run: make qemu-kernel)"
[ -f "${ROOTFS_TAR}" ] || die "rootfs not found: ${ROOTFS_TAR} (run: make rootfs)"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v mke2fs >/dev/null || die "mke2fs not installed (e2fsprogs)"

WORK="$(mktemp -d)"
IMG="${BUILD_DIR}/mem-probe-rootfs.ext4"
SERIAL="${BUILD_DIR}/mem-probe-${LABEL//[^a-zA-Z0-9._-]/_}.log"
# Rootless build: assemble the tree in a staging dir, then bake it into an ext4
# with `mke2fs -d` (no loop mount, no sudo). MNT is just a staging directory.
MNT="${WORK}/mnt"
cleanup() {
    rm -rf "${WORK}"
}
trap cleanup EXIT

# --- build an ext4 from the rootfs tar, inject the probe init ----------------
log "Staging rootfs from ${ROOTFS_TAR} ..."
rm -f "${IMG}"
mkdir -p "${MNT}"
tar -C "${MNT}" -xf "${ROOTFS_TAR}"

# Optional runtime tweaks applied in-place (A/B against the same baseline rootfs).
# The real klippy/moonraker init scripts live at /mod/init.d/ (NOT /etc/init.d/);
# the old harness sed targeted the wrong path and silently no-op'd — fixed 2026-06-04.
# Available knobs:
#   TWEAKS=oo            klippy+moonraker run with python -OO (drop docstrings/asserts)
#   TWEAKS=klippy-oo     only klippy with python -OO
#   TWEAKS=arena1        MALLOC_ARENA_MAX=1 (tighter than the default 2) — ONLY meaningful
#                        if the init script uses glibc malloc (production currently uses
#                        jemalloc by default, so this tweak is largely vestigial)
#   TWEAKS=noarena       remove the MALLOC_ARENA_MAX export entirely
#   TWEAKS=jemalloc-conf override the existing MALLOC_CONF to JEMALLOC_CONF env value
#                        (production already preloads jemalloc; this only swaps tuning)
#   TWEAKS=no-jemalloc   strip the LD_PRELOAD=libjemalloc + MALLOC_CONF lines entirely
#                        (baseline-vs-glibc comparison)
#   TWEAKS=moonraker-min strip optional moonraker sections ([history], [announcements],
#                        [update_manager], [octoprint_compat]) from the staged conf
K="${MNT}/mod/init.d/S60klipper"
M="${MNT}/mod/init.d/S65moonraker"
assert_sed() {  # <description> <file> <expected-substring-after>
    grep -q "$3" "$2" 2>/dev/null && return 0
    echo "[mem-probe] ERROR: tweak '$1' did not take effect on $2" >&2
    return 1
}
case ",${TWEAKS:-}," in *,oo,*)
    log "tweak: python -OO (klippy + moonraker)"
    sed -i 's#DAEMON_ARGS="/opt#DAEMON_ARGS="-OO /opt#' "$K" "$M" || die "oo sed failed"
    assert_sed oo "$K" 'DAEMON_ARGS="-OO /opt' || die "oo: klippy sed missed"
    assert_sed oo "$M" 'DAEMON_ARGS="-OO /opt' || die "oo: moonraker sed missed"
;; esac
case ",${TWEAKS:-}," in *,klippy-oo,*)
    log "tweak: python -OO (klippy only)"
    sed -i 's#DAEMON_ARGS="/opt#DAEMON_ARGS="-OO /opt#' "$K" || die "klippy-oo sed failed"
    assert_sed klippy-oo "$K" 'DAEMON_ARGS="-OO /opt' || die "klippy-oo: sed missed"
;; esac
case ",${TWEAKS:-}," in *,arena1,*)
    log "tweak: MALLOC_ARENA_MAX=1"
    sed -i 's/MALLOC_ARENA_MAX=2/MALLOC_ARENA_MAX=1/' "$K" "$M" 2>/dev/null || true
;; esac
case ",${TWEAKS:-}," in *,noarena,*)
    log "tweak: remove MALLOC_ARENA_MAX cap"
    sed -i '/export MALLOC_ARENA_MAX=/d' "$K" "$M" 2>/dev/null || true
;; esac
case ",${TWEAKS:-}," in *,no-jemalloc,*)
    log "tweak: strip jemalloc preload + MALLOC_CONF (baseline-vs-glibc)"
    # init script lines are tab-indented — anchor on whitespace, not column 0
    sed -i -E '/^[[:space:]]*export LD_PRELOAD=.*libjemalloc/d;/^[[:space:]]*export MALLOC_CONF=/d' \
        "$K" "$M" || die "no-jemalloc sed failed"
    grep -q 'libjemalloc' "$K" && die "no-jemalloc: klippy still has libjemalloc"
    grep -q 'libjemalloc' "$M" && die "no-jemalloc: moonraker still has libjemalloc"
;; esac
case ",${TWEAKS:-}," in *,jemalloc-conf,*)
    log "tweak: override MALLOC_CONF -> '${JEMALLOC_CONF:-}'"
    [ -n "${JEMALLOC_CONF:-}" ] || die "jemalloc-conf needs JEMALLOC_CONF set"
    # init script lines are tab-indented — the regex must accept leading whitespace.
    # Substitution preserves the original indentation.
    sed -i -E "s#^([[:space:]]*)export MALLOC_CONF=.*#\\1export MALLOC_CONF=${JEMALLOC_CONF}#" \
        "$K" "$M" || die "jemalloc-conf sed failed"
    grep -q "export MALLOC_CONF=${JEMALLOC_CONF}" "$K" \
        || die "jemalloc-conf: klippy missed (line: $(grep MALLOC_CONF "$K"))"
    grep -q "export MALLOC_CONF=${JEMALLOC_CONF}" "$M" \
        || die "jemalloc-conf: moonraker missed (line: $(grep MALLOC_CONF "$M"))"
;; esac
case ",${TWEAKS:-}," in *,moonraker-min,*)
    log "tweak: drop optional moonraker sections from staged moonraker.conf"
    # moonraker.conf lives under /mod/etc/reforge/ (not /etc/reforge/) in this rootfs.
    MR_CFG="${MNT}/mod/etc/reforge/moonraker.conf"
    [ -f "${MR_CFG}" ] || MR_CFG="${MNT}/etc/reforge/moonraker.conf"
    [ -f "${MR_CFG}" ] || die "moonraker-min: moonraker.conf not in rootfs (tried /mod/etc/reforge/ and /etc/reforge/)"
    python3 - "${MR_CFG}" <<'PYMIN' || die "moonraker-min: conf trim failed"
import sys, re
p = sys.argv[1]
txt = open(p).read()
DROP = ('history', 'announcements', 'update_manager', 'octoprint_compat', 'job_state', 'analysis')
out, skip = [], False
for line in txt.splitlines(True):
    m = re.match(r'\s*\[([^\]]+)\]', line)
    if m:
        skip = any(m.group(1).split(' ', 1)[0] == d for d in DROP)
    if not skip:
        out.append(line)
open(p, 'w').write(''.join(out))
print('moonraker-min: stripped sections')
PYMIN
;; esac
case ",${TWEAKS:-}," in *,updmgr,*)
    log "tweak: enable Moonraker [update_manager] + web updaters (measure its cost)"
    cat >> "${MNT}/etc/reforge/moonraker.conf" <<'UMG'

[update_manager]
enable_auto_refresh: False
refresh_interval: 168

[update_manager mainsail]
type: web
repo: mainsail-crew/mainsail
path: /var/www/mainsail

[update_manager moonraker]
type: git_repo
path: /opt/moonraker
origin: https://github.com/Arksine/moonraker.git
primary_branch: master
UMG
;; esac

# NOSWAP=1: disable zram + eMMC-overflow swap entirely (autoresearch experiments
# that want to measure raw RAM pressure without swap-relief noise).  We blank the
# zram init script and skip writing the eMMC swapfile script below; the probe also
# runs `swapoff -a` defensively before the measurement.
if [ "${NOSWAP:-0}" = 1 ]; then
    log "NOSWAP=1: zram + eMMC swap disabled for this run"
    for f in "${MNT}/etc/init.d/S35zram" "${MNT}/mod/init.d/S35zram"; do
        [ -f "$f" ] && : > "$f" && chmod 0755 "$f" || true
    done
fi

# Probe init: runs last (S98), after klipper/moonraker/httpd/guppyscreen.
cat > "${MNT}/etc/init.d/S98memprobe" <<PROBE
#!/bin/sh
[ "\$1" = start ] || exit 0
# Task 3 moved the ReForge init chain to /mod (run via /mod/start.sh on-device).
# This standalone boot must invoke it to bring up zram/klippy/moonraker/httpd.
[ -x /mod/start.sh ] && /mod/start.sh > /dev/console 2>&1
(
  sleep ${SETTLE}
  # NOSWAP defensive: even if some package brought swap up, kill it now so the
  # measurement reflects pure RAM pressure.
  [ "${NOSWAP:-0}" = "1" ] && swapoff -a 2>/dev/null
  echo "===MEMPROBE-BEGIN==="
  echo "NOSWAP=${NOSWAP:-0}"
  echo "--- meminfo (kB) ---"
  grep -E '^(MemTotal|MemFree|MemAvailable|Cached|Buffers|SwapTotal|SwapFree)' /proc/meminfo
  echo "--- zram ---"
  if [ -f /sys/block/zram0/mm_stat ]; then
    echo "zram0 disksize: \$(cat /sys/block/zram0/disksize 2>/dev/null)"
    echo "zram0 mm_stat : \$(cat /sys/block/zram0/mm_stat)"
  else
    echo "zram0: not present"
  fi
  echo "--- swaps (real device: zram primary + eMMC overflow) ---"
  cat /proc/swaps 2>/dev/null
  echo "--- per-process Pss/Rss (kB) ---"
  for p in /proc/[0-9]*; do
    [ -r "\$p/smaps_rollup" ] || continue
    cmd=\$(tr '\0' ' ' < "\$p/cmdline" 2>/dev/null)
    case "\$cmd" in
      *klippy*|*moonraker*|*guppyscreen*|*httpd*)
        pss=\$(awk '/^Pss:/{print \$2}' "\$p/smaps_rollup" 2>/dev/null)
        rss=\$(awk '/^Rss:/{print \$2}' "\$p/smaps_rollup" 2>/dev/null)
        jem=no; grep -q libjemalloc "\$p/maps" 2>/dev/null && jem=yes
        echo "PID \${p#/proc/} Pss=\${pss} Rss=\${rss} JEM=\${jem} CMD=\${cmd}"
      ;;
    esac
  done
  echo "===MEMPROBE-END==="
  poweroff -f
) > /dev/console 2>&1 &
PROBE
chmod +x "${MNT}/etc/init.d/S98memprobe"

# eMMC overflow swapfile (S36, after S35zram brings up zram as primary). Mirrors
# the real printer: zram = primary (prio 100), an eMMC swapfile = low-prio overflow.
# /dev/vdb is the emulated eMMC disk (a 2nd virtio-blk, built below).
cat > "${MNT}/etc/init.d/S36emmcswap" <<'EMMCSWAP'
#!/bin/sh
[ "$1" = start ] || exit 0
mkdir -p /data
mount /dev/vdb /data 2>/dev/null || exit 0
fallocate -l 64M /data/swap 2>/dev/null || dd if=/dev/zero of=/data/swap bs=1M count=64 2>/dev/null
chmod 600 /data/swap
mkswap /data/swap >/dev/null 2>&1
swapon /data/swap 2>/dev/null   # default (low) priority = overflow under zram(prio 100)
EMMCSWAP
chmod +x "${MNT}/etc/init.d/S36emmcswap"
if [ "${NOSWAP:-0}" = 1 ]; then
    : > "${MNT}/etc/init.d/S36emmcswap"   # blank out: no eMMC overflow swap
    chmod 0755 "${MNT}/etc/init.d/S36emmcswap"
fi

# Bake the staging tree into an ext4 image (rootless, no loop mount).
mke2fs -q -F -t ext4 -d "${MNT}" "${IMG}" 768M
log "ext4 ready: ${IMG}"

# eMMC disk (the printer's /data, where the overflow swapfile lives)
EMMC="${BUILD_DIR}/mem-probe-emmc.ext4"
rm -f "${EMMC}"
truncate -s 512M "${EMMC}"
mkfs.ext4 -q -F "${EMMC}"
log "eMMC (overflow swap) ready: ${EMMC}"

# --- boot under the virt kernel at -m MEM ------------------------------------
log "Booting (MEM=${MEM} MiB, settle=${SETTLE}s) ..."
timeout "${TIMEOUT}" qemu-system-arm \
    -M virt,highmem=off -cpu cortex-a7 -smp "${SMP}" -m "${MEM}" \
    -kernel "${ZIMAGE}" \
    -drive "file=${IMG},if=virtio,format=raw" \
    -drive "file=${EMMC},if=virtio,format=raw" \
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
