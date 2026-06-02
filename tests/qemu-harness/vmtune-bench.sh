#!/usr/bin/env bash
# =============================================================================
# vmtune-bench.sh — measure the ReForge zram VM-tuning impact INSIDE qemu.
#
# Boots the ReForge rootfs twice at the device-faithful -m 128 with zram active,
# runs an IDENTICAL deterministic memory-pressure workload (allocate ~150 MB anon,
# then churn random pages so the swapped-out portion faults back in), and diffs
# /proc/vmstat across the workload:
#
#   BASELINE  — kernel defaults (page-cluster=3, swappiness=60, ...)
#   TUNED     — the shipped reforge-vmtune profile (page-cluster=0, swappiness=100, ...)
#
# The headline is `pswpin`: with random swap-in, default readahead (cluster=3)
# pulls 2^3=8 pages per fault — 7 likely cold — while cluster=0 pulls 1. Also
# reports pswpout / pgmajfault / allocstall / direct-reclaim throttle deltas.
#
# Rootless. Needs: qemu-system-arm, mke2fs, build/zImage, a freshly built rootfs
# (the tuning ships via .shell/reforge-vmtune.sh — run `make rootfs` first).
# Usage:  tests/qemu-harness/vmtune-bench.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${REPO_ROOT}/tests/qemu-harness/build"
ZIMAGE="${BUILD_DIR}/zImage"
ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar}"
MEM="${MEM:-128}"
BUFMB="${BUFMB:-150}"
ITERS="${ITERS:-250000}"

log() { echo "[vmtune-bench] $*"; }
die() { echo "[vmtune-bench] ERROR: $*" >&2; exit 1; }

[ -f "${ZIMAGE}" ]     || die "no ${ZIMAGE} (make qemu-kernel)"
[ -f "${ROOTFS_TAR}" ] || die "no rootfs.tar (make rootfs)"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v mke2fs >/dev/null || die "mke2fs not installed"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
STAGE="${WORK}/root"; mkdir -p "${STAGE}"
tar -C "${STAGE}" -xf "${ROOTFS_TAR}"
[ -f "${STAGE}/mod/.shell/reforge-vmtune.sh" ] || die "rootfs lacks reforge-vmtune.sh — run 'make rootfs'"

# Deterministic workload: fault in BUFMB of anon, then churn random pages.
cat > "${STAGE}/workload.py" <<PY
import random
PG = 4096
N = ${BUFMB} * 1024 * 1024
buf = bytearray(N)
for i in range(0, N, PG):   # fault every page in
    buf[i] = 1
random.seed(42)
npg = N // PG
for _ in range(${ITERS}):   # random-access churn -> swap-in traffic
    p = random.randrange(npg) * PG
    buf[p] = (buf[p] + 1) & 0xff
print("workload done")
PY

# Bench init: bring up zram (+ tuning), optionally reset to defaults for BASELINE,
# snapshot vmstat, run the workload, snapshot again, print deltas. Mode comes from
# /proc/cmdline (vmmode=baseline|tuned).
cat > "${STAGE}/sbin/vmbench" <<'EOF'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null
MODE=tuned
grep -q 'vmmode=baseline' /proc/cmdline && MODE=baseline

# zram + the shipped tuning
/mod/init.d/S35zram start >/dev/null 2>&1

if [ "$MODE" = baseline ]; then
    # revert to stock kernel defaults
    echo 3   > /proc/sys/vm/page-cluster
    echo 60  > /proc/sys/vm/swappiness
    echo 100 > /proc/sys/vm/vfs_cache_pressure
    echo 10  > /proc/sys/vm/watermark_scale_factor
    echo 20  > /proc/sys/vm/dirty_ratio
    echo 10  > /proc/sys/vm/dirty_background_ratio
fi

KEYS='pswpin pswpout pgmajfault pgfault allocstall_normal allocstall_movable pgscan_direct_throttle pgsteal_direct pgsteal_kswapd'
snap() { for k in $KEYS; do v=$(awk -v K="$k" '$1==K{print $2}' /proc/vmstat); echo "$k ${v:-0}"; done; }

echo "VMBENCH MODE=$MODE pc=$(cat /proc/sys/vm/page-cluster) sw=$(cat /proc/sys/vm/swappiness) mem=$(awk '/MemTotal/{print $2}' /proc/meminfo)kB"
snap > /tmp/a
python3 /workload.py 2>&1 | sed 's/^/VMBENCH wl: /'
snap > /tmp/b
echo "VMBENCH DELTAS (MODE=$MODE):"
for k in $KEYS; do
    a=$(awk -v K="$k" '$1==K{print $2}' /tmp/a)
    b=$(awk -v K="$k" '$1==K{print $2}' /tmp/b)
    echo "VMBENCH  $k = $((b - a))"
done
echo "VMBENCH zram: $(awk '{print "orig="$1" compr="$2" used="$3}' /sys/block/zram0/mm_stat 2>/dev/null)"
echo "VMBENCH oom_kill = $(awk '/oom_kill/{print $2}' /proc/vmstat)"
echo "VMBENCH END MODE=$MODE"
poweroff -f
EOF
chmod +x "${STAGE}/sbin/vmbench"

IMG="${BUILD_DIR}/vmtune-bench.ext4"
rm -f "${IMG}"; mke2fs -q -F -t ext4 -d "${STAGE}" "${IMG}" 1024M

run_mode() {  # <baseline|tuned>
    local mode="$1"
    local ser="${BUILD_DIR}/vmtune-bench-${mode}.log"
    rm -f "${ser}"
    log "booting ${mode} (-m ${MEM}, buf ${BUFMB}MB, ${ITERS} churn iters) ..."
    # writeback image fresh per mode (copy so swap state doesn't carry over)
    cp -f "${IMG}" "${IMG}.run"
    timeout 600 qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -smp 2 -m "${MEM}" \
        -kernel "${ZIMAGE}" \
        -append "console=ttyAMA0,115200 root=/dev/vda rw rootwait loglevel=3 init=/sbin/vmbench vmmode=${mode}" \
        -drive "file=${IMG}.run,if=virtio,format=raw,cache=writeback" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 -nographic > "${ser}" 2>&1 || true
    rm -f "${IMG}.run"
    grep -E 'VMBENCH' "${ser}" || { log "no VMBENCH output — serial tail:"; tail -15 "${ser}"; }
}

run_mode baseline
run_mode tuned

echo ""
echo "===================== VM TUNING IMPACT (qemu -m ${MEM}) ====================="
printf '%-26s %14s %14s\n' "metric" "baseline" "tuned"
for k in pswpin pswpout pgmajfault pgfault allocstall_normal allocstall_movable pgscan_direct_throttle pgsteal_direct pgsteal_kswapd; do
    b=$(awk -v K="$k" '$0 ~ "VMBENCH  "K" =" {print $NF}' "${BUILD_DIR}/vmtune-bench-baseline.log" | tail -1)
    t=$(awk -v K="$k" '$0 ~ "VMBENCH  "K" =" {print $NF}' "${BUILD_DIR}/vmtune-bench-tuned.log" | tail -1)
    printf '%-26s %14s %14s\n' "$k" "${b:-?}" "${t:-?}"
done
echo "============================================================================"
