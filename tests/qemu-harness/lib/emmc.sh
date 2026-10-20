#!/bin/bash
# emmc.sh — production-shape eMMC + the qemu storage args, so every harness
# models real-hw device names (/dev/mmcblk0p1..p7, /dev/sda) instead of virtio
# vda. Wraps lib/build-emmc-image.sh.
#
#   . lib/common.sh ; . lib/emmc.sh
#   emmc_build  <p6_ext4> <p7_ext4>      # sets EMMC_QEMU_ARGS (+ EMMC_ROOT)
#   emmc_build_p6 <p6_ext4>              # p6-only (tiny empty /data p7)
#   usb_args    <usb_ext4>               # sets USB_QEMU_ARGS (/dev/sda via xhci)
#
# Then boot with:  qemu-system-arm ... -append "${EMMC_ROOT} ..." ${EMMC_QEMU_ARGS}

# shellcheck disable=SC2034 # Output variables are read by scripts sourcing this file.
EMMC_BUILDER="${LIBDIR}/build-emmc-image.sh"
EMMC_ROOT="root=/dev/mmcblk0p6"

emmc_build() {
    local p6="$1" p7="$2" out="${3:-${BUILD_DIR}/emmc.img}"
    [ -x "${EMMC_BUILDER}" ] || die "emmc builder missing: ${EMMC_BUILDER}"
    "${EMMC_BUILDER}" "${p6}" "${p7}" "${out}"
    EMMC_IMG="${out}"
    EMMC_QEMU_ARGS="-device sdhci-pci,id=sd0 -drive id=mmc0,file=${out},if=none,format=raw -device emmc,drive=mmc0"
}

# p6-only: synthesise a tiny empty ext4 /data so build-emmc-image is happy.
emmc_build_p6() {
    local p6="$1" out="${2:-${BUILD_DIR}/emmc.img}" p7="${BUILD_DIR}/.emmc-empty-data.ext4"
    mkext4 "${p7}" 64M UDISK
    emmc_build "${p6}" "${p7}" "${out}"
}

usb_args() {
    local usb="$1"
    USB_QEMU_ARGS="-device qemu-xhci,id=xhci0 -drive id=usb0,file=${usb},if=none,format=raw -device usb-storage,bus=xhci0.0,drive=usb0"
}
