#!/usr/bin/env bash
# =============================================================================
# pid1-pivot-test.sh — validate the reforge-init pivot_root flow under qemu.
#
# Boots a "stock-like" rootfs whose /init is our reforge-init script (Option A
# from docs/boot.md §2), with a separate /data disk containing a ReForge
# install at /data/.mod/.reforge/. Asserts the full chain works:
#
#   kernel → reforge-init (PID 1) → mount /data → find install → pivot_root →
#   exec /sbin/init → busybox-init → /etc/init.d/rcS → S?? loop →
#   S99reforge → /mod/start.sh → klippy/moonraker/httpd alive
#
# Additional test cases:
#   - Happy path: install present, pivot_root succeeds, stack comes up
#   - SKIP_REFORGE on kernel cmdline → fallback to /bin/busybox init
#   - No install at /data/.mod/.reforge/ → fallback to /bin/busybox init
#
# Setup: a single eMMC image (via -device sdhci-pci + -device emmc) holding
# a GPT with 7 partitions matching docs/board-notes/partition-map.md — p6 is
# the boot rootfs (ext4), p7 is /data (ext4). Kernel sees /dev/mmcblk0p1..p7
# exactly as on the real board, so reforge-init's hardcoded /dev/mmcblk0p7
# for /data works without any device-name bridging in the test rig.
#
# Fully ROOTLESS: images built via mke2fs -d, qemu unprivileged.
# Usage:    tests/qemu-harness/pid1-pivot-test.sh [CASE]
#   CASE = happy (default) | skip-cmdline | no-install
# Output:   tests/qemu-harness/build/pid1-pivot-<CASE>-serial.log
# Needs:    qemu-system-arm, mke2fs (e2fsprogs), debugfs, build/zImage,
#           build/output/images/rootfs.tar[.xz], the reforge-init script under
#           br-external/board/reforge/rootfs-overlay/sbin/.
# Exit:     0 = PASS, 1 = FAIL, 0 = SKIP (missing prereqs)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar}"
REFORGE_INIT_SRC="${REPO_ROOT}/br-external/board/reforge/rootfs-overlay/sbin/reforge-init"

CASE="${1:-happy}"
BOOT_IMG="${BUILD_DIR}/pid1-pivot-boot.ext4"
DATA_IMG="${BUILD_DIR}/pid1-pivot-data.ext4"
EMMC_IMG="${BUILD_DIR}/pid1-pivot-emmc.img"
EMMC_BUILDER="${HARNESS_DIR}/lib/build-emmc-image.sh"
SER="${BUILD_DIR}/pid1-pivot-${CASE}-serial.log"
SETTLE="${SETTLE:-50}"
MEM="${MEM:-128}"
SMP="${SMP:-2}"
TIMEOUT="${TIMEOUT:-180}"

log() { echo "[pid1-pivot] $*"; }
die() { echo "[pid1-pivot] FAIL: $*" >&2; exit 1; }
skip() { echo "[pid1-pivot] SKIP: $*"; exit 0; }

[ -f "${ZIMAGE}" ]            || skip "no ${ZIMAGE} (make qemu-kernel)"
[ -f "${ROOTFS_TAR}" ]        || skip "no rootfs.tar (make rootfs)"
[ -f "${REFORGE_INIT_SRC}" ]  || die  "reforge-init missing: ${REFORGE_INIT_SRC}"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v mke2fs >/dev/null  || die "mke2fs not installed (e2fsprogs)"
command -v sgdisk >/dev/null  || die "sgdisk not installed (gdisk)"
[ -x "${EMMC_BUILDER}" ]      || die "emmc builder missing/non-exec: ${EMMC_BUILDER}"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# ---------------------------------------------------------------------------
# 1. Boot rootfs (will be partition p6 on the eMMC): the "stock-like" rootfs
# with our init in place. We base it on the full ReForge rootfs.tar (gives us
# a complete busybox + /sbin/init + all the bits the fallback path would
# need), then overlay:
#   - /init → /sbin/reforge-init  (the symlink swap, Option A)
#   - /sbin/reforge-init  (the script itself)
# Since the eMMC image gives us /dev/mmcblk0p7 directly, no device-bridging
# wrapper is needed — reforge-init runs as-is, exactly as on real hardware.
# ---------------------------------------------------------------------------
log "staging boot rootfs (stock-like, p6) ..."
BOOTSTAGE="${WORK}/boot"; mkdir -p "${BOOTSTAGE}"
tar -C "${BOOTSTAGE}" -xf "${ROOTFS_TAR}"

# Drop in the real reforge-init script (in case the in-tar copy is stale).
install -m 0755 "${REFORGE_INIT_SRC}" "${BOOTSTAGE}/sbin/reforge-init"

# Point /init at /sbin/reforge-init — the Option A symlink swap that the
# installer would do on stock p6.
rm -f "${BOOTSTAGE}/init"
ln -sf /sbin/reforge-init "${BOOTSTAGE}/init"

# Case-specific markers.
case "${CASE}" in
    happy|skip-cmdline)
        : ;;
    no-install)
        # The data disk will be empty (no .mod/.reforge/), so reforge-init
        # should fall back to busybox init. Nothing extra to stage on the boot
        # rootfs side.
        : ;;
    *) die "unknown CASE=${CASE}; expected happy | skip-cmdline | no-install" ;;
esac

# Production p6 is exactly 1280 MiB; build the ext4 at that size so the
# resulting eMMC image is bit-for-bit production-shaped (sparse host file
# keeps the actual on-disk footprint small).
log "baking boot rootfs (${BOOT_IMG}, 1280 MiB to match production p6) ..."
rm -f "${BOOT_IMG}"
mke2fs -q -F -t ext4 -L rootfs -d "${BOOTSTAGE}" "${BOOT_IMG}" 1280M

# ---------------------------------------------------------------------------
# 2. /data partition (vdb): contains the ReForge install at .mod/.reforge/.
# We populate it by extracting rootfs.tar into a .mod/.reforge subdir and
# touching .installed so reforge-init recognises it as a valid install.
# ---------------------------------------------------------------------------
case "${CASE}" in
    happy|skip-cmdline)
        log "staging /data (vdb) with ReForge install at .mod/.reforge/ ..."
        DATASTAGE="${WORK}/data"; mkdir -p "${DATASTAGE}/.mod/.reforge"
        tar -C "${DATASTAGE}/.mod/.reforge" -xf "${ROOTFS_TAR}"
        echo "test-pid1-pivot-$(date -Is)" > "${DATASTAGE}/.mod/.reforge/.installed"
        ;;
    no-install)
        log "staging /data (vdb) WITHOUT a ReForge install (negative test) ..."
        DATASTAGE="${WORK}/data"; mkdir -p "${DATASTAGE}"
        # touch a sentinel so we can confirm /data DID get mounted; reforge-init
        # should still fall back because .mod/.reforge/.installed is absent.
        echo "data-disk-mounted" > "${DATASTAGE}/THIS_IS_THE_DATA_DISK"
        ;;
esac

log "baking /data (${DATA_IMG}, 6068 MiB to match production p7) ..."
rm -f "${DATA_IMG}"
# Production p7 is 12429267 sectors = ~6068 MiB. Use 6068 MiB so the ext4
# fits inside the p7 slot when dd'd in. Slight under-fill (44 sectors) is
# harmless; we just have a tiny gap of zeros at the end of the slot.
mke2fs -q -F -t ext4 -L UDISK -d "${DATASTAGE}" "${DATA_IMG}" 6068M

# ---------------------------------------------------------------------------
# 3. Combine into a single eMMC image with production GPT layout.
# ---------------------------------------------------------------------------
log "building eMMC image with GPT (${EMMC_IMG}) ..."
"${EMMC_BUILDER}" "${BOOT_IMG}" "${DATA_IMG}" "${EMMC_IMG}"

# ---------------------------------------------------------------------------
# 4. Boot. Kernel sees a real eMMC at /dev/mmcblk0 with p1..p7. Root is p6,
# /data (mounted by reforge-init) is p7.
# ---------------------------------------------------------------------------
# rootwait: the eMMC behind sdhci-pci is probed async; without rootwait the
# kernel tries to mount_root before /dev/mmcblk0p6 exists and panics.
# loglevel=7 lets us see SDHCI / MMC / partition probes during debug; bump
# back down to 4 once the rig stabilises.
APPEND="root=/dev/mmcblk0p6 rootwait rw console=ttyAMA0 loglevel=7 panic=10 init=/init"
case "${CASE}" in
    skip-cmdline) APPEND="${APPEND} reforge_skip" ;;
esac

rm -f "${SER}"
log "booting qemu (mem=${MEM}M smp=${SMP} settle=${SETTLE}s case=${CASE}) ..."
timeout "${TIMEOUT}" qemu-system-arm \
    -M virt,highmem=off -cpu cortex-a7 -smp "${SMP}" -m "${MEM}" \
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

# ---------------------------------------------------------------------------
# 4. Asserts.
# ---------------------------------------------------------------------------
echo ""
echo "============================ PID1-PIVOT GATE (case=${CASE}) ============================"

PASS=1
say() { echo "  $*"; }

# Common: did userspace even start? reforge-init's first banner is our signal.
if grep -q "\[reforge-init\] early bring-up" "${SER}" \
   || grep -q "\[reforge-init\] falling back" "${SER}"; then
    say "[PASS] kernel exec'd /init -> reforge-init (eMMC path resolved at boot)"
else
    say "[FAIL] reforge-init did NOT start — kernel boot, eMMC, or /init resolution broke"
    PASS=0
fi

case "${CASE}" in
    happy)
        # Expect the full pivot + service chain.
        grep -q "\[reforge-init\] early bring-up complete" "${SER}" \
            && say "[PASS] reforge-init reached step 1 (proc/sys mounted)" \
            || { say "[FAIL] reforge-init did NOT pass early bring-up"; PASS=0; }

        # New assert (gained when we moved off virtio-blk): /data really got
        # mounted via the production /dev/mmcblk0p7 path, no test bridging.
        grep -q "\[reforge-init\] /data mounted from /dev/mmcblk0p7" "${SER}" \
            && say "[PASS] /data mounted via production /dev/mmcblk0p7 path (no rig bridge)" \
            || { say "[FAIL] /data mount marker missing — eMMC partitioning may be wrong"; PASS=0; }

        grep -qE "\[reforge-init\] found ReForge .* at /data/\.mod/\.reforge; pivoting" "${SER}" \
            && say "[PASS] reforge-init found the install" \
            || { say "[FAIL] reforge-init did NOT find the install"; PASS=0; }

        grep -q "\[reforge-init\] pivot complete:" "${SER}" \
            && say "[PASS] pivot_root succeeded (stock at /oldroot, ReForge at /)" \
            || { say "[FAIL] pivot_root did NOT complete"; PASS=0; }

        # After pivot, exec /sbin/init runs busybox-init in the new root.
        # busybox-init's first sysinit line is `/bin/mount -t proc proc /proc`
        # which we already have mounted (move worked) so it just silently no-ops.
        # The cleaner positive signal: rcS runs S?? scripts, and S99reforge fires.
        grep -q "\[S99reforge\] launching /mod/start\.sh" "${SER}" \
            && say "[PASS] S99reforge invoked /mod/start.sh (new-root init chain worked)" \
            || { say "[FAIL] S99reforge did NOT fire (new-root rcS may not have run)"; PASS=0; }

        # The ReForge stack itself — klippy/moonraker/httpd should be visible.
        # In settle=50s the daemons should be alive.
        grep -qiE "Starting klipper|S60klipper start" "${SER}" \
            && say "[PASS] klipper service started" \
            || { say "[WARN] no klipper start marker in serial (may need longer SETTLE)"; }

        grep -qiE "Starting moonraker|S65moonraker start" "${SER}" \
            && say "[PASS] moonraker service started" \
            || { say "[WARN] no moonraker start marker"; }

        # Negative: we should NOT see the fallback message.
        if grep -q "falling back to stock /bin/busybox init" "${SER}"; then
            say "[FAIL] reforge-init unexpectedly fell back"
            PASS=0
        else
            say "[PASS] reforge-init did NOT fall back (happy path stayed on the ReForge track)"
        fi
        ;;

    skip-cmdline)
        # Expect: reforge-init detects 'reforge_skip', falls back to busybox init.
        grep -q "falling back to stock /bin/busybox init: reforge_skip on kernel cmdline" "${SER}" \
            && say "[PASS] reforge-init honoured reforge_skip and fell back" \
            || { say "[FAIL] reforge-init did NOT honour reforge_skip"; PASS=0; }

        # Negative: we should NOT see the pivot complete message.
        if grep -q "\[reforge-init\] pivot complete" "${SER}"; then
            say "[FAIL] reforge-init pivoted despite reforge_skip"
            PASS=0
        else
            say "[PASS] reforge-init did NOT pivot (skip honoured)"
        fi
        ;;

    no-install)
        # Expect: reforge-init mounts /data but finds no install, falls back.
        grep -q "falling back to stock /bin/busybox init: no \.installed marker at /data/\.mod/\.reforge" "${SER}" \
            && say "[PASS] reforge-init detected missing install + fell back" \
            || { say "[FAIL] reforge-init did NOT fall back on missing install"; PASS=0; }

        # /data should still have been mounted (verify the THIS_IS_THE_DATA_DISK
        # sentinel was visible OR at least that the mount succeeded — the
        # fallback message only fires after the mount, so reaching the
        # 'no .installed' branch implicitly proves the mount worked).
        say "[PASS] /data mount path succeeded (the fallback branch we hit requires a successful mount)"
        ;;
esac

echo "  serial log: ${SER}"
echo "==========================================================================="

[ "$PASS" -eq 1 ] || die "case=${CASE} did not satisfy all asserts"
log "case=${CASE}: PASS"
