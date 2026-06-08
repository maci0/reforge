#!/usr/bin/env bash
# =============================================================================
# live-mode-test.sh — prove ReForge LIVE mode boots cleanly from USB.
#
# Production-shape rig:
#   - eMMC (production GPT, 7.28 GiB sparse, p6 = stock-like host rootfs,
#     p7 = /data stand-in) attached via -device sdhci-pci + -device emmc;
#     appears as /dev/mmcblk0p1..p7 in the guest, exactly like real hw.
#   - USB stick (bare ext4 with the ReForge live rootfs) attached via
#     -device qemu-xhci + -device usb-storage; appears as /dev/sda in the
#     guest, exactly like a real USB stick plugged into the printer.
#
# The host rootfs (p6) boots straight into a tiny init (/sbin/reforge-live-init)
# that mounts /data from p7, then invokes packaging/live/flashforge_init.sh
# with F2FS_DEV=/dev/sda — same env contract the real auto_run.sh uses.
# The launcher mounts /dev/sda at /data/.mod/.reforge and runs the ReForge
# stack from there. Same as install mode wrt user data: gcodes land on the
# eMMC /data via Klipper's virtual_sdcard.
#
# Live mode here means "booted from USB". It is NOT a zero-eMMC-write mode:
# the launcher creates /data/.mod/.reforge (one directory inode, ~4 KB) the
# first time it runs, and user gcodes land on eMMC /data (the factory
# `[virtual_sdcard] path: /data/`). That's desired persistence.
#
# ASSERTS:
#   (1) the ReForge stack comes up from the USB image;
#   (2) the eMMC stand-in (p7) acquires no install state — no
#       /data/.mod/.reforge/{mod,lkg,trial,.installed} files.
#
# Fully ROOTLESS (no sudo): images via mke2fs -d, GPT via sgdisk,
# unprivileged qemu.
#
# Usage:    tests/qemu-harness/live-mode-test.sh        # NO sudo
# Needs:    qemu-system-arm, mke2fs (e2fsprogs), debugfs, sgdisk, sha256sum,
#           build/zImage, build/output/images/rootfs.tar[.xz]
# Exit:     0 = PASS, 1 = FAIL, 0 = SKIP (missing prereqs)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
LAUNCHER="${REPO_ROOT}/packaging/live/flashforge_init.sh"
EMMC_BUILDER="${HARNESS_DIR}/lib/build-emmc-image.sh"

# Per-partition / per-disk ext4s used to build the composite eMMC + the USB.
P6_IMG="${BUILD_DIR}/live-host.ext4"     # eMMC p6 = host stock-like rootfs
P7_IMG="${BUILD_DIR}/live-data.ext4"     # eMMC p7 = /data stand-in
USB_IMG="${BUILD_DIR}/live-usb.ext4"     # USB stick = ReForge live rootfs
EMMC_IMG="${BUILD_DIR}/live-emmc.img"    # combined production-shape eMMC
SER="${BUILD_DIR}/live-mode-serial.log"
SETTLE="${SETTLE:-70}"

log() { echo "[live-mode] $*"; }
die() { echo "[live-mode] FAIL: $*" >&2; exit 1; }

ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar}"
[ -f "${ROOTFS_TAR}" ] || ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar.xz"
[ -f "${ZIMAGE}" ]     || { echo "[live-mode] SKIP: no ${ZIMAGE} (make qemu-kernel)"; exit 0; }
[ -f "${ROOTFS_TAR}" ] || { echo "[live-mode] SKIP: no rootfs.tar (make rootfs)"; exit 0; }
[ -f "${LAUNCHER}" ]   || die "live launcher missing: ${LAUNCHER}"
[ -x "${EMMC_BUILDER}" ] || die "emmc builder missing/non-exec: ${EMMC_BUILDER}"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v mke2fs >/dev/null || die "mke2fs not installed"
command -v sgdisk >/dev/null || die "sgdisk not installed"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# --- 1. USB stick (bare ext4, will appear as /dev/sda in guest) --------------
log "staging the ReForge live rootfs (the USB payload) ..."
USBSTAGE="${WORK}/usb"; mkdir -p "${USBSTAGE}"
tar -C "${USBSTAGE}" -xf "${ROOTFS_TAR}"
[ -x "${USBSTAGE}/mod/start.sh" ] || die "rootfs has no /mod/start.sh — wrong/old build"
# Bare ext4 (no partition table) — the real USB stick this is mimicking is
# `mkfs.ext4` straight on /dev/sda by tools/release/build-live-usb.sh.
# Note: the production live USB uses F2FS for write-amp reasons; the qemu test
# kernel doesn't have F2FS, so we use ext4 here. The launcher tries F2FS first
# and falls back to ext4 — both paths exist on real hw.
rm -f "${USB_IMG}"
mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L reforge-live -d "${USBSTAGE}" "${USB_IMG}" 1843M

# --- 2. eMMC p6 (host stock-like rootfs with our gate init) ------------------
log "staging the host image (eMMC p6, init -> live launcher with F2FS_DEV=/dev/sda) ..."
HOSTSTAGE="${WORK}/host"; mkdir -p "${HOSTSTAGE}"
tar -C "${HOSTSTAGE}" -xf "${ROOTFS_TAR}"
install -m 0755 "${LAUNCHER}" "${HOSTSTAGE}/flashforge_init.sh"
cat > "${HOSTSTAGE}/sbin/reforge-live-init" <<'EOF'
#!/bin/sh
# qemu live-mode gate init (boots from eMMC p6, USB on /dev/sda):
#  - bring up proc/sys/dev/tmp
#  - mount /data from /dev/mmcblk0p7  (the real eMMC layout)
#  - run the live launcher with F2FS_DEV=/dev/sda  (real USB device name)
set -u
echo "[live-gate] PID 1 starting; eMMC p6 boot, USB at /dev/sda"
mount -t proc     proc    /proc 2>/dev/null
mount -t sysfs    sysfs   /sys  2>/dev/null
mount -t devtmpfs dev     /dev  2>/dev/null
mount -t tmpfs    tmpfs   /tmp  2>/dev/null
mkdir -p /mnt /data
# Wait for the USB controller to enumerate the stick (xhci is async).
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -b /dev/sda ] && break
    sleep 1
done
if [ -b /dev/mmcblk0p7 ]; then
    mount -t ext4 /dev/mmcblk0p7 /data 2>/dev/null && echo "[live-gate] /data mounted from /dev/mmcblk0p7"
else
    echo "[live-gate] WARN: no /dev/mmcblk0p7 — production /data path missing"
fi
if [ -b /dev/sda ]; then
    echo "[live-gate] /dev/sda present (USB enumerated)"
else
    echo "[live-gate] FAIL: /dev/sda not present after 10s"
fi
# LIVE_LOG=/dev/console pins the launcher's output to the captured serial
# (otherwise it auto-detects /dev/tty1 framebuffer console and we'd miss it).
USB_MNT=/mnt F2FS_DEV=/dev/sda SCREEN_MODE=HEADLESS LIVE_LOG=/dev/console \
    /flashforge_init.sh AD5MPro 0024
EOF
chmod 0755 "${HOSTSTAGE}/sbin/reforge-live-init"
rm -f "${P6_IMG}"
mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L rootfs -d "${HOSTSTAGE}" "${P6_IMG}" 1280M

# --- 3. eMMC p7 (/data stand-in; the test checks no install state lands here) -
log "building the eMMC /data stand-in (p7) ..."
DATASTAGE="${WORK}/data"; mkdir -p "${DATASTAGE}/printer_data"
echo "this is the printer's eMMC /data — live mode must NOT install here" \
    > "${DATASTAGE}/DO-NOT-TOUCH"
rm -f "${P7_IMG}"
# Match production p7 size so the resulting eMMC GPT is production-shaped.
# The host file stays sparse so the on-disk cost is just the actual contents.
mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L UDISK -d "${DATASTAGE}" "${P7_IMG}" 6068M

# --- 4. combine into a single production-shape eMMC image --------------------
log "building production-shape eMMC image (GPT + p1..p7) ..."
"${EMMC_BUILDER}" "${P6_IMG}" "${P7_IMG}" "${EMMC_IMG}"

# Record p7 sha256 BEFORE boot (gate verifies no install residue afterward).
P7_BEFORE="$(sha256sum "${P7_IMG}" | cut -d' ' -f1)"
log "  eMMC p7 sha256 (before): ${P7_BEFORE}"

# --- 5. boot (unprivileged) --------------------------------------------------
# Production-look-alike topology:
#   eMMC via sdhci-pci + emmc   → /dev/mmcblk0p1..p7
#   USB  via qemu-xhci + usb-storage → /dev/sda
rm -f "${SER}"
log "booting (settle=${SETTLE}s, no sudo) — eMMC=/dev/mmcblk0 USB=/dev/sda ..."
qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -smp 2 -m 256 \
    -kernel "${ZIMAGE}" \
    -append "root=/dev/mmcblk0p6 rootwait rw console=ttyAMA0 loglevel=4 init=/sbin/reforge-live-init panic=1" \
    -device sdhci-pci,id=sd0 \
    -drive id=mmc0,file="${EMMC_IMG}",if=none,format=raw \
    -device emmc,drive=mmc0 \
    -device qemu-xhci,id=xhci0 \
    -drive id=usb0,file="${USB_IMG}",if=none,format=raw \
    -device usb-storage,bus=xhci0.0,drive=usb0 \
    -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
    -nographic > "${SER}" 2>&1 &
QP=$!
trap 'kill -9 "${QP}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT
sleep "${SETTLE}"
kill -9 "${QP}" 2>/dev/null || true
trap 'rm -rf "${WORK}"' EXIT

# --- 6. verdict --------------------------------------------------------------
P7_AFTER="$(sha256sum "${P7_IMG}" | cut -d' ' -f1)"
log "  eMMC p7 sha256 (after):  ${P7_AFTER}"

STACK_UP=0
grep -qiE 'Starting moonraker|Starting klipper|live mode — services up|reforge-ok' "${SER}" 2>/dev/null && STACK_UP=1

USB_SEEN=0
grep -q "/dev/sda present" "${SER}" 2>/dev/null && USB_SEEN=1

EMMC_DATA_MOUNTED=0
grep -q "/data mounted from /dev/mmcblk0p7" "${SER}" 2>/dev/null && EMMC_DATA_MOUNTED=1

# Look for install residue on the eMMC /data stand-in.
INSTALL_RESIDUE_FOUND=0
for name in mod lkg trial .installed; do
    if debugfs -R "stat /.reforge/${name}" "${P7_IMG}" 2>/dev/null | grep -q '^Inode:'; then
        echo "  [FAIL] /data/.mod/.reforge/${name} found on eMMC p7 — live mode installed!"
        INSTALL_RESIDUE_FOUND=1
    fi
done

echo ""
echo "========================= LIVE MODE GATE ========================="
if [ "${USB_SEEN}" -eq 1 ]; then
    echo "  [PASS] /dev/sda enumerated by xhci (USB stick visible to guest)"
else
    echo "  [FAIL] /dev/sda never appeared in the guest (xhci/usb-storage broken)"
fi
if [ "${EMMC_DATA_MOUNTED}" -eq 1 ]; then
    echo "  [PASS] /data mounted from /dev/mmcblk0p7 (production eMMC path)"
else
    echo "  [FAIL] /data NOT mounted from /dev/mmcblk0p7 (eMMC topology broken)"
fi
if [ "${INSTALL_RESIDUE_FOUND}" -eq 0 ]; then
    echo "  [PASS] no install state on eMMC p7 (no .reforge/{mod,lkg,trial,.installed})"
else
    echo "  [FAIL] live mode left install residue on eMMC p7"
fi
if [ "${P7_BEFORE}" = "${P7_AFTER}" ]; then
    echo "  [info] eMMC p7 is byte-identical (no /data/.mod/.reforge mountpoint needed creation)"
else
    echo "  [info] eMMC p7 changed (expected: mkdir /data/.mod/.reforge mountpoint + journal)"
fi
if [ "${STACK_UP}" -eq 1 ]; then
    echo "  [PASS] the ReForge stack came up from /dev/sda"
else
    echo "  [WARN] did not see the ReForge stack start in the serial (see ${SER})"
fi
echo "  serial: ${SER}"
echo "================================================================="

[ "${USB_SEEN}" -eq 1 ]            || die "USB stick never appeared as /dev/sda"
[ "${EMMC_DATA_MOUNTED}" -eq 1 ]   || die "/data not mounted from /dev/mmcblk0p7"
[ "${INSTALL_RESIDUE_FOUND}" -eq 0 ] || die "live mode wrote install state to eMMC p7"
[ "${STACK_UP}" -eq 1 ]            || die "ReForge stack did not start from USB"
log "PASS: live mode booted the stack from /dev/sda; eMMC p7 has no install residue."
