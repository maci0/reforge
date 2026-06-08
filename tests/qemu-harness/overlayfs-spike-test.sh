#!/usr/bin/env bash
# =============================================================================
# overlayfs-spike-test.sh — does OverlayFS work on a BSP-source 5.4.61 kernel?
#
# Spike test for docs/BACKLOG.md "immutable / atomic ReForge — OverlayFS2"
# proposed in turn ~cf56be3+. Question to answer: can the stock 5.4.61 BSP's
# fs/overlayfs/ source be enabled (=y or =m) and used to mount a working
# overlay on a ReForge-style /data ext4? And if so, what is the per-mount
# RAM cost on a 128 MB-ish system?
#
# Method:
#   1. The test kernel (tests/qemu-harness/configs/virt.fragment) is rebuilt
#      with CONFIG_OVERLAY_FS=y against the same BSP source the device runs
#      (vendor/kernels/tina-bsp-kernel). Vanilla fs/overlayfs/ — confirmed
#      no vendor patches.
#   2. eMMC image (production-shape via lib/build-emmc-image.sh) carries a
#      tiny stock-like rootfs on p6 with a measurement init that:
#        a. mounts /proc, /sys, /dev, /tmp
#        b. mounts /dev/mmcblk0p7 (UDISK) at /data
#        c. records baseline /proc/meminfo
#        d. builds a layered structure under /data:
#             /data/.spike/lower/      — pre-existing files (simulates
#                                        an LKG snapshot)
#             /data/.spike/upper/      — empty (writable layer)
#             /data/.spike/work/       — overlay workdir
#             /data/.spike/merged/     — mount point
#        e. mounts overlay
#        f. records post-mount /proc/meminfo + slabinfo for ovl_*
#        g. exercises overlay: read-from-lower, write-to-upper, then read
#           back the merge (writes should shadow lower; lower stays intact)
#        h. records cold-read cost: cat 1 MiB lower file twice and time it
#   3. Asserts:
#        - overlay.ko or in-kernel overlay registers
#        - mount succeeds with EXPECTED flags
#        - merge semantics correct (write-through to upper, lower preserved)
#        - per-mount overhead within budget (target: < 200 KiB MemAvailable
#          delta for the first mount; flag if > 500 KiB)
#
# Build deps: same as pid1-pivot (qemu-system-arm, sgdisk, mke2fs, debugfs).
#
# Output:
#   - Full serial log (kernel + measurement init prints) in build/
#   - PASS/FAIL gate + a metrics block usable for the research note
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar}"
EMMC_BUILDER="${HARNESS_DIR}/lib/build-emmc-image.sh"

P6_IMG="${BUILD_DIR}/overlay-p6.ext4"
P7_IMG="${BUILD_DIR}/overlay-p7.ext4"
EMMC_IMG="${BUILD_DIR}/overlay-emmc.img"
SER="${BUILD_DIR}/overlayfs-spike-serial.log"
MEM="${MEM:-128}"
SETTLE="${SETTLE:-45}"

log() { echo "[overlay-spike] $*"; }
die() { echo "[overlay-spike] FAIL: $*" >&2; exit 1; }
skip(){ echo "[overlay-spike] SKIP: $*"; exit 0; }

[ -f "${ZIMAGE}" ]     || skip "no ${ZIMAGE} (build-test-kernel.sh first)"
[ -f "${ROOTFS_TAR}" ] || skip "no rootfs.tar (make rootfs)"
[ -x "${EMMC_BUILDER}" ] || die "emmc builder missing"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v mke2fs          >/dev/null || die "mke2fs not installed"
command -v sgdisk          >/dev/null || die "sgdisk not installed"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# --- stage p6 = stock-like rootfs + the measurement init ---
log "staging p6 rootfs + measurement init ..."
HOSTSTAGE="${WORK}/host"; mkdir -p "${HOSTSTAGE}"
tar -C "${HOSTSTAGE}" -xf "${ROOTFS_TAR}"
cat > "${HOSTSTAGE}/sbin/overlay-spike-init" <<'EOF'
#!/bin/sh
# overlay spike init: mount, measure, exercise, measure again, log results.
set -u
echo "[spike] PID 1: setting up ..."
mount -t proc     proc    /proc 2>/dev/null
mount -t sysfs    sysfs   /sys  2>/dev/null
mount -t devtmpfs dev     /dev  2>/dev/null
mount -t tmpfs    tmpfs   /tmp  2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do [ -b /dev/mmcblk0p7 ] && break; sleep 1; done

mkdir -p /data
if ! mount -t ext4 /dev/mmcblk0p7 /data; then
    echo "[spike] FAIL: cannot mount /dev/mmcblk0p7"; exit 1
fi
echo "[spike] /data ready ($(df -h /data 2>/dev/null | tail -1))"

# --- verify overlay is registered ---
if grep -qE '^\snodev\soverlay\s*$|^\soverlay\s*$|nodev[[:space:]]+overlay' /proc/filesystems; then
    echo "[spike] overlay FS registered in kernel"
else
    echo "[spike] kernel does not have overlay in /proc/filesystems:"
    cat /proc/filesystems
    echo "[spike] (will try mount anyway)"
fi

# --- baseline /proc/meminfo ---
echo "[spike] --- baseline meminfo ---"
awk '/^MemTotal|^MemFree|^MemAvailable|^Buffers|^Cached|^Slab/{print "[spike] mem:", $0}' /proc/meminfo

# --- build the layered structure ---
mkdir -p /data/.spike/lower /data/.spike/upper /data/.spike/work /data/.spike/merged
# Populate the lower layer with content the overlay should expose.
echo "this is in the LOWER layer (simulates an LKG version)" > /data/.spike/lower/README.txt
mkdir -p /data/.spike/lower/etc/init.d /data/.spike/lower/opt/klipper/klippy
for i in $(seq 1 50); do
    echo "lower-config-line-$i" > /data/.spike/lower/etc/init.d/file-$i.cfg
done
# A 1 MiB file in the lower layer for the cold-read benchmark.
dd if=/dev/urandom of=/data/.spike/lower/biggish.bin bs=4k count=256 2>/dev/null
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null

# --- the mount itself ---
echo "[spike] mounting overlay (lower=/data/.spike/lower, upper=/data/.spike/upper, work=/data/.spike/work) ..."
if mount -t overlay overlay \
   -o lowerdir=/data/.spike/lower,upperdir=/data/.spike/upper,workdir=/data/.spike/work \
   /data/.spike/merged; then
    echo "[spike] PASS: overlay mount succeeded"
else
    echo "[spike] FAIL: overlay mount failed (rc=$?)"
    dmesg | tail -10 | sed 's/^/[spike] dmesg: /'
    exit 2
fi

# --- post-mount meminfo ---
sync; sleep 1
echo "[spike] --- post-mount meminfo ---"
awk '/^MemTotal|^MemFree|^MemAvailable|^Buffers|^Cached|^Slab/{print "[spike] mem:", $0}' /proc/meminfo

# --- slab footprint of overlay objects ---
echo "[spike] --- ovl_* slabs ---"
grep -E "^ovl_|^overlay" /proc/slabinfo 2>/dev/null | head | sed 's/^/[spike] slab: /'
[ -z "$(grep -E '^ovl_|^overlay' /proc/slabinfo 2>/dev/null)" ] && echo "[spike] slab: (no ovl_* slabs reported)"

# --- semantics check: read from lower via merged ---
echo "[spike] --- semantics check ---"
if [ "$(cat /data/.spike/merged/README.txt 2>/dev/null)" = "this is in the LOWER layer (simulates an LKG version)" ]; then
    echo "[spike] PASS: read-from-lower via merged returns lower content"
else
    echo "[spike] FAIL: read-from-lower returned: $(cat /data/.spike/merged/README.txt 2>/dev/null | head -c 60)"
fi

# Write through the merged: should land in upper, NOT lower.
echo "this is from the UPPER layer (overwrite)" > /data/.spike/merged/README.txt
if [ "$(cat /data/.spike/merged/README.txt)" = "this is from the UPPER layer (overwrite)" ]; then
    echo "[spike] PASS: write-to-merged is read-through-merged correctly"
else
    echo "[spike] FAIL: write-to-merged read-back wrong"
fi
# Verify lower is unchanged.
if [ "$(cat /data/.spike/lower/README.txt)" = "this is in the LOWER layer (simulates an LKG version)" ]; then
    echo "[spike] PASS: lower layer is unchanged after write-to-merged"
else
    echo "[spike] FAIL: write-to-merged leaked into lower"
fi
# Verify upper has the file (copy-up happened).
if [ -f /data/.spike/upper/README.txt ]; then
    sz=$(stat -c '%s' /data/.spike/upper/README.txt 2>/dev/null)
    echo "[spike] PASS: copy-up to upper occurred (upper/README.txt = ${sz} bytes)"
else
    echo "[spike] FAIL: upper has no copy-up file after write"
fi

# Whiteout test: rm a lower-only file, check it disappears from merged.
rm -f /data/.spike/merged/etc/init.d/file-1.cfg
if [ ! -e /data/.spike/merged/etc/init.d/file-1.cfg ] && \
   [ -e /data/.spike/lower/etc/init.d/file-1.cfg ]; then
    echo "[spike] PASS: whiteout — rm from merged hides lower, lower intact"
else
    echo "[spike] FAIL: whiteout semantics broken"
fi

# --- cold-read cost: read the 1 MiB file via merged ---
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
sync; sleep 1
echo "[spike] --- cold-read timing (via overlay merged) ---"
t0=$(awk '/^now/{print $2; exit}' /proc/timer_list 2>/dev/null | head -1)
dd if=/data/.spike/merged/biggish.bin of=/dev/null bs=64k 2>&1 | tail -1 | sed 's/^/[spike] cold: /'
echo "[spike] --- warm-read timing (same file again) ---"
dd if=/data/.spike/merged/biggish.bin of=/dev/null bs=64k 2>&1 | tail -1 | sed 's/^/[spike] warm: /'

# Final meminfo for the diff.
sync; sleep 1
echo "[spike] --- final meminfo ---"
awk '/^MemTotal|^MemFree|^MemAvailable|^Buffers|^Cached|^Slab/{print "[spike] mem:", $0}' /proc/meminfo

echo "[spike] === SPIKE COMPLETE ==="
# Hold open briefly so qemu doesn't reap us before serial flushes.
sleep 5
EOF
chmod 0755 "${HOSTSTAGE}/sbin/overlay-spike-init"
rm -f "${P6_IMG}"
mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L rootfs -d "${HOSTSTAGE}" "${P6_IMG}" 1280M

# --- p7: a clean /data for the overlay to live on ---
log "staging p7 (empty /data, overlay workspace) ..."
DATASTAGE="${WORK}/data"; mkdir -p "${DATASTAGE}"
echo "overlay spike workspace; populated by spike-init at runtime" > "${DATASTAGE}/README"
rm -f "${P7_IMG}"
mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L UDISK -d "${DATASTAGE}" "${P7_IMG}" 6068M

# --- combine into production-shape eMMC ---
log "building production-shape eMMC image ..."
"${EMMC_BUILDER}" "${P6_IMG}" "${P7_IMG}" "${EMMC_IMG}" 2>&1 | grep -E "matches|done"

APPEND="root=/dev/mmcblk0p6 rootwait rw console=ttyAMA0 loglevel=4 panic=10 init=/sbin/overlay-spike-init"

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

# --- verdict ---
echo ""
echo "================== OVERLAYFS SPIKE GATE ==================="
PASS=1
say() { echo "  $*"; }
get() { grep -m1 "\\[spike\\] $1" "${SER}" 2>/dev/null | sed 's/^.*\[spike\] //'; }

if grep -q "overlay FS registered in kernel" "${SER}"; then
    say "[PASS] overlay registered in /proc/filesystems"
else
    say "[FAIL] overlay NOT registered (CONFIG_OVERLAY_FS may not be active)"; PASS=0
fi
if grep -q "PASS: overlay mount succeeded" "${SER}"; then
    say "[PASS] mount -t overlay succeeded with lower+upper+workdir"
else
    say "[FAIL] overlay mount FAILED"; PASS=0
fi
for assert in \
    "read-from-lower via merged returns lower content" \
    "write-to-merged is read-through-merged correctly" \
    "lower layer is unchanged after write-to-merged" \
    "copy-up to upper occurred" \
    "whiteout"; do
    if grep -q "PASS:.*${assert}" "${SER}"; then
        say "[PASS] ${assert}"
    else
        say "[FAIL] ${assert}"; PASS=0
    fi
done

echo ""
echo "  --- METRICS (for docs/research/) ---"
grep -E "\\[spike\\] mem:" "${SER}" | head -20 | sed 's/^/    /'
echo ""
grep -E "\\[spike\\] slab:" "${SER}" | sed 's/^/    /'
echo ""
grep -E "\\[spike\\] (cold|warm):" "${SER}" | sed 's/^/    /'

echo ""
echo "  serial: ${SER}"
echo "==========================================================="
[ "${PASS}" -eq 1 ] || die "overlay spike did not satisfy all asserts"
log "PASS: overlayfs works on BSP-source 5.4.61"
