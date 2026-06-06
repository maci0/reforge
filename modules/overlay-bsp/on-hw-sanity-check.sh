#!/usr/bin/env bash
# =============================================================================
# on-hw-sanity-check.sh — confirm overlay.ko built against the stock 5.4.61
# BSP actually loads + mounts on the real printer.
#
# Three-command minimum check, zero risk:
#   1. scp overlay.ko -> /tmp on the printer
#   2. insmod, mount under /tmp (tmpfs, evaporates on reboot), exercise, rmmod
#   3. capture results
#
# Why this exists: the qemu spike
# (docs/research/2026-06-05-overlayfs-on-bsp-spike.md) confirmed overlay works
# functionally + measured per-mount RAM cost on a multi_v7 / virt build of the
# SAME BSP source. It did NOT prove the binary survives vermagic-matching on a
# sun8iw20-config'd build of the same source running on real silicon. This
# script closes that loop.
#
# Cleanup: everything happens in /tmp (tmpfs), no eMMC writes, rmmod at exit.
# A reboot wipes any residue regardless.
#
# Usage: PRINTER=root@192.168.0.158 ./modules/overlay-bsp/on-hw-sanity-check.sh
# Output: PASS/FAIL gate + memory delta + module size on disk
# =============================================================================
set -euo pipefail

PRINTER="${PRINTER:-root@192.168.0.158}"
HERE="$(cd "$(dirname "$0")" && pwd)"
KO_LOCAL="${HERE}/build/overlay.ko"

[ -f "${KO_LOCAL}" ] || { echo "FAIL: ${KO_LOCAL} missing — run modules/overlay-bsp/build.sh first"; exit 2; }

log() { echo "[on-hw] $*"; }

# Reachability + kernel-version sanity.
log "checking ${PRINTER} ..."
HW_VER="$(ssh -o ConnectTimeout=5 "${PRINTER}" 'uname -srvm 2>&1' 2>/dev/null || true)"
[ -n "${HW_VER}" ] || { echo "FAIL: ${PRINTER} unreachable"; exit 2; }
log "  hw: ${HW_VER}"

# Confirm the running kernel uname -r matches the vermagic in our .ko.
HW_RELEASE="$(ssh "${PRINTER}" 'uname -r' 2>/dev/null | tr -d '\r')"
KO_VM="$(strings "${KO_LOCAL}" | grep -m1 '^vermagic=' | sed 's/^vermagic=//; s/ *$//')"
KO_RELEASE="${KO_VM%% *}"  # first space-separated token is the kernel release string
if [ "${HW_RELEASE}" != "${KO_RELEASE}" ]; then
    echo "FAIL: hw release '${HW_RELEASE}' != ko release '${KO_RELEASE}'"
    echo "       ko vermagic='${KO_VM}'"
    echo "       (rebuild against stock-kernel-config-5.4.61.txt.gz)"
    exit 1
fi
log "  release matches: '${HW_RELEASE}'"

# Confirm overlay is NOT already loaded / built-in.
if ssh "${PRINTER}" 'grep -wq overlay /proc/filesystems' 2>/dev/null; then
    log "  WARN: overlay already registered in /proc/filesystems on the printer"
    log "        (already loaded by some other mod? insmod will fail with -EEXIST)"
fi

# Ship the .ko over.
log "scp $(stat -c '%s' "${KO_LOCAL}") byte overlay.ko -> ${PRINTER}:/tmp/"
scp -q "${KO_LOCAL}" "${PRINTER}:/tmp/overlay.ko"

# The actual on-hw test. Single ssh invocation, all output captured.
log "running the on-hw test sequence ..."
ssh "${PRINTER}" bash -s <<'REMOTE'
set -u
echo "=== /proc/meminfo BEFORE insmod ==="
awk '/^MemTotal|^MemFree|^MemAvailable|^Slab/{print $0}' /proc/meminfo

echo ""
echo "=== insmod /tmp/overlay.ko ==="
if insmod /tmp/overlay.ko 2>&1; then
    echo "  insmod: ok"
else
    echo "  insmod: FAILED ($?)"
    dmesg | tail -5 | sed 's/^/    dmesg: /'
    exit 10
fi

echo ""
echo "=== /proc/filesystems (overlay registered?) ==="
grep -E '\\boverlay\\b' /proc/filesystems || { echo "  overlay NOT registered"; exit 11; }

echo ""
echo "=== /proc/modules (overlay loaded, size, refcount) ==="
grep '^overlay ' /proc/modules || { echo "  overlay NOT in /proc/modules"; exit 12; }

echo ""
echo "=== build a tmpfs-only lower/upper/work and mount ==="
mkdir -p /tmp/ovl/lower /tmp/ovl/upper /tmp/ovl/work /tmp/ovl/merged
echo "hello-from-lower" > /tmp/ovl/lower/test.txt
if mount -t overlay overlay \
    -o lowerdir=/tmp/ovl/lower,upperdir=/tmp/ovl/upper,workdir=/tmp/ovl/work \
    /tmp/ovl/merged 2>&1; then
    echo "  mount: ok"
else
    echo "  mount: FAILED ($?)"
    dmesg | tail -5 | sed 's/^/    dmesg: /'
    rmmod overlay 2>/dev/null || true
    exit 13
fi

mount | grep overlay | sed 's/^/  /'

echo ""
echo "=== semantics ==="
[ "$(cat /tmp/ovl/merged/test.txt)" = "hello-from-lower" ] && \
    echo "  PASS: read-from-lower via merged" || \
    echo "  FAIL: read-from-lower returned: $(cat /tmp/ovl/merged/test.txt)"

echo "from-upper-overwrite" > /tmp/ovl/merged/test.txt
[ "$(cat /tmp/ovl/merged/test.txt)" = "from-upper-overwrite" ] && \
    echo "  PASS: write-to-merged read-back" || echo "  FAIL: write-to-merged read-back"
[ "$(cat /tmp/ovl/lower/test.txt)" = "hello-from-lower" ] && \
    echo "  PASS: lower unchanged" || echo "  FAIL: lower modified"
[ -f /tmp/ovl/upper/test.txt ] && \
    echo "  PASS: copy-up to upper (upper/test.txt = $(stat -c '%s' /tmp/ovl/upper/test.txt) bytes)" || \
    echo "  FAIL: no copy-up file in upper"

echo ""
echo "=== /proc/meminfo AFTER mount ==="
awk '/^MemTotal|^MemFree|^MemAvailable|^Slab/{print $0}' /proc/meminfo
echo "ovl_inode slab:"
grep -E '^ovl_|^overlay ' /proc/slabinfo 2>/dev/null | sed 's/^/  /' || echo "  (no ovl_* slabs in /proc/slabinfo)"

echo ""
echo "=== cleanup ==="
umount /tmp/ovl/merged && echo "  umount: ok" || echo "  umount: FAILED"
rmmod overlay && echo "  rmmod: ok" || echo "  rmmod: FAILED"
rm -rf /tmp/ovl /tmp/overlay.ko

echo ""
echo "=== /proc/meminfo AFTER cleanup ==="
awk '/^MemTotal|^MemFree|^MemAvailable|^Slab/{print $0}' /proc/meminfo

echo ""
echo "=== DONE ==="
REMOTE
RC=$?
exit "${RC}"
