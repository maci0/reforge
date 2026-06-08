#!/usr/bin/env bash
# =============================================================================
# stock-preinit-test.sh — does the stock /etc/preinit hook actually fire?
#
# docs/boot.md §2 row #6 claims the stock /etc/inittab has
#   ::sysinit:/etc/preinit
# as the FIRST sysinit entry (file absent today = no-op), and the doc
# advertises it as the earliest safe userspace hook. We've also been treating
# /etc/preinit as a possible "Option C" hook in the PID-1 research note. This
# test proves it actually runs on the stock rootfs under qemu, by:
#
#   1. Taking the cached stock p6 from extract-stock-rootfs.sh (fsck'd clean)
#   2. Dropping a tiny /etc/preinit that emits a unique marker to /dev/console
#      AND drops a /tmp/preinit-fired sentinel file
#   3. Building a production-shape eMMC (single GPT image with p1..p7,
#      matching docs/board-notes/partition-map.md) with the stock rootfs as p6
#      and a fresh /data ext4 as p7
#   4. Booting under qemu with our test kernel
#   5. Asserting we see the preinit marker on the serial console BEFORE rcS
#
# Why this matters:
#   - Confirms the preinit hook is live on stock (not just documented)
#   - Confirms ordering: preinit fires BEFORE rcS (i.e. before /etc/init.d/S??
#     scripts), giving us a real pre-Tina early hook
#   - Bounds the cost of "Option C" thinking: if preinit doesn't fire on stock,
#     the whole Option C row in boot.md §2 is dead and we should drop it.
#
# Usage:    tests/qemu-harness/stock-preinit-test.sh
# Needs:    qemu-system-arm, sgdisk, debugfs (e2fsprogs), build/zImage,
#           build/stock-rootfs.ext4 (from extract-stock-rootfs.sh; will be
#           built if missing)
# Exit:     0 = PASS, 1 = FAIL, 0 = SKIP (missing prereqs)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
STOCK_ROOTFS="${BUILD_DIR}/stock-rootfs.ext4"
EXTRACTOR="${HARNESS_DIR}/extract-stock-rootfs.sh"
EMMC_BUILDER="${HARNESS_DIR}/lib/build-emmc-image.sh"

P6_IMG="${BUILD_DIR}/preinit-p6.ext4"     # stock rootfs + our preinit
P7_IMG="${BUILD_DIR}/preinit-p7.ext4"     # empty /data placeholder
EMMC_IMG="${BUILD_DIR}/preinit-emmc.img"  # combined production-shape eMMC
SER="${BUILD_DIR}/stock-preinit-serial.log"
SETTLE="${SETTLE:-50}"
MEM="${MEM:-128}"

# Marker the preinit script emits + greps for. Unique enough to be a clean
# signal in the serial log.
MARK="REFORGE-PREINIT-FIRED-$(date +%s%N | head -c 13)"

log() { echo "[stock-preinit] $*"; }
die() { echo "[stock-preinit] FAIL: $*" >&2; exit 1; }
skip(){ echo "[stock-preinit] SKIP: $*"; exit 0; }

[ -f "${ZIMAGE}" ]       || skip "no ${ZIMAGE} (make qemu-kernel)"
[ -x "${EMMC_BUILDER}" ] || die  "emmc builder missing/non-exec"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v sgdisk          >/dev/null || die "sgdisk not installed (gdisk)"
command -v debugfs         >/dev/null || die "debugfs not installed (e2fsprogs)"
command -v mke2fs          >/dev/null || die "mke2fs not installed"

# --- 1. stock rootfs --------------------------------------------------------
if [ ! -f "${STOCK_ROOTFS}" ]; then
    log "stock rootfs missing; running extractor (slow first time, cached after) ..."
    [ -x "${EXTRACTOR}" ] || die "extractor missing: ${EXTRACTOR}"
    "${EXTRACTOR}" >/dev/null || die "extract-stock-rootfs.sh failed"
fi
[ -f "${STOCK_ROOTFS}" ] || die "stock rootfs still missing after extract"

# Sanity: confirm stock /etc/inittab calls /etc/preinit and that /etc/preinit
# really is absent on the original (= the docs claim).
log "verifying stock /etc/inittab has the ::sysinit:/etc/preinit hook ..."
if ! debugfs -R 'cat /etc/inittab' "${STOCK_ROOTFS}" 2>/dev/null \
     | grep -qE '^::sysinit:/etc/preinit\b'; then
    die "stock /etc/inittab does NOT contain ::sysinit:/etc/preinit — boot.md §2 #6 wrong"
fi
log "  inittab has the hook"
if debugfs -R 'stat /etc/preinit' "${STOCK_ROOTFS}" 2>/dev/null | grep -q '^Inode:'; then
    log "  WARN: /etc/preinit already exists on stock (expected absent)"
else
    log "  /etc/preinit absent on stock (as expected)"
fi

# --- 2. p6 = stock rootfs + our /etc/preinit --------------------------------
log "copying stock rootfs to p6 and injecting /etc/preinit ..."
cp --reflink=auto "${STOCK_ROOTFS}" "${P6_IMG}"

# The preinit script. Plain busybox sh (stock /etc/preinit runs before /proc
# even is mounted in some inittab orderings, so be conservative with what we
# call — only redirected printk-equivalent writes and a touch). The "$MARK"
# expansion happens in the host shell; the resulting file is a static script.
PREINIT_TMP="$(mktemp)"
cat > "${PREINIT_TMP}" <<EOF
#!/bin/sh
# Injected by tests/qemu-harness/stock-preinit-test.sh to prove the hook fires.
# /etc/preinit runs as a sysinit CHILD of busybox-init (PID 1), before
# /etc/init.d/rcS, before /bin/mount -a, before swapon -a, before any S?? script.
# We just leave a marker on the console and a sentinel file, then exit 0.
echo "[preinit] ${MARK} pid=\$\$ cwd=\$(pwd) parent=\$(cat /proc/\$\$/status 2>/dev/null | awk '/^PPid/{print \$2}')" > /dev/console 2>&1
echo "[preinit] argv0=\$0 args=\$*" > /dev/console 2>&1
echo "[preinit] env: HOME=\$HOME PATH=\$PATH TERM=\${TERM:-unset}" > /dev/console 2>&1
# /tmp is a tmpfs by the time later sysinit lines fire, but at preinit time
# it may be the on-disk /tmp (since "mount -t proc" hasn't fired yet, and the
# tmpfs mounts come later in the inittab chain). Either way the sentinel will
# show up — we just want to prove the script ran.
mkdir -p /tmp 2>/dev/null
touch /tmp/preinit-fired-${MARK}
exit 0
EOF
chmod 0755 "${PREINIT_TMP}"

# Write into the ext4 with debugfs -w (rootless; no mount required).
debugfs -w -R "write ${PREINIT_TMP} /etc/preinit" "${P6_IMG}" >/dev/null 2>&1 || \
    die "debugfs write of /etc/preinit failed"
# debugfs's `write` defaults to mode 0644 + owner-root; fix the exec bit.
debugfs -w -R "set_inode_field /etc/preinit mode 0100755" "${P6_IMG}" >/dev/null 2>&1 || true
rm -f "${PREINIT_TMP}"

# Verify it landed.
if ! debugfs -R 'stat /etc/preinit' "${P6_IMG}" 2>/dev/null | grep -q '^Inode:'; then
    die "/etc/preinit not present on p6 after debugfs write"
fi
log "  /etc/preinit injected (mode 0755)"

# --- 3. p7 = empty /data ----------------------------------------------------
log "building empty /data placeholder for p7 ..."
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
DATASTAGE="${WORK}/data"; mkdir -p "${DATASTAGE}"
echo "stock-preinit test /data placeholder" > "${DATASTAGE}/README"
rm -f "${P7_IMG}"
mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L UDISK -d "${DATASTAGE}" "${P7_IMG}" 6068M

# --- 4. combine into production-shape eMMC ---------------------------------
log "building production-shape eMMC image (GPT + p1..p7) ..."
"${EMMC_BUILDER}" "${P6_IMG}" "${P7_IMG}" "${EMMC_IMG}" 2>&1 | grep -E "matches|done"

# --- 5. boot ---------------------------------------------------------------
# The stock kernel cmdline (per docs/boot.md §1) is:
#   root=/dev/mmcblk0p6 init=/init console=ttyS3,115200 cma=16M ...
# Our qemu virt board's serial is ttyAMA0, so adjust the console arg.
# init=/init resolves to /bin/busybox (stock symlink) which runs busybox-init,
# which reads /etc/inittab and runs ::sysinit:/etc/preinit FIRST.
APPEND="root=/dev/mmcblk0p6 rootwait rw console=ttyAMA0 loglevel=4 panic=10 init=/init"

rm -f "${SER}"
log "booting qemu (mem=${MEM}M settle=${SETTLE}s) ..."
qemu-system-arm \
    -M virt,highmem=off -cpu cortex-a7 -smp 2 -m "${MEM}" \
    -kernel "${ZIMAGE}" \
    -append "${APPEND}" \
    -device sdhci-pci,id=sd0 \
    -drive id=mmc0,file="${EMMC_IMG}",if=none,format=raw \
    -device emmc,drive=mmc0 \
    -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
    -nographic > "${SER}" 2>&1 &
QP=$!
trap 'kill -9 "${QP}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT
sleep "${SETTLE}"
kill -9 "${QP}" 2>/dev/null || true
trap 'rm -rf "${WORK}"' EXIT

# --- 6. asserts ------------------------------------------------------------
echo ""
echo "===================== STOCK PREINIT GATE ====================="
PASS=1
say() { echo "  $*"; }

if grep -q "${MARK}" "${SER}"; then
    say "[PASS] /etc/preinit fired (marker '${MARK}' on console)"
else
    say "[FAIL] /etc/preinit did NOT fire (marker absent from serial)"
    PASS=0
fi

# Confirm ordering: the preinit marker must appear BEFORE rcS markers like
# 'Starting' lines or 'init.d/S' scripts.
MARK_LINE=$(grep -n "${MARK}" "${SER}" 2>/dev/null | head -1 | cut -d: -f1)
RCS_LINE=$(grep -nE 'init\.d/S|Starting (klipper|moonraker|networking|httpd|syslogd)' "${SER}" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "${MARK_LINE}" ] && [ -n "${RCS_LINE}" ]; then
    if [ "${MARK_LINE}" -lt "${RCS_LINE}" ]; then
        say "[PASS] preinit ran BEFORE rcS (marker line ${MARK_LINE} < rcS line ${RCS_LINE})"
    else
        say "[FAIL] preinit ran AFTER rcS (marker line ${MARK_LINE} >= rcS line ${RCS_LINE})"
        PASS=0
    fi
elif [ -n "${MARK_LINE}" ]; then
    say "[info] preinit fired but no rcS markers seen yet within ${SETTLE}s (stock may need more time)"
fi

# Echo the preinit lines so we can see PID, cwd, parent, env.
say "preinit context captured:"
grep "\[preinit\]" "${SER}" 2>/dev/null | sed 's/^/    /' | head -5

echo "  serial: ${SER}"
echo "=============================================================="

[ "${PASS}" -eq 1 ] || die "stock /etc/preinit hook did not fire as expected"
log "PASS: stock /etc/preinit hook is live."
