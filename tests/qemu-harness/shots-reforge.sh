#!/usr/bin/env bash
# =============================================================================
# shots-reforge.sh — capture REAL ReForge framebuffer-console screenshots from
# qemu (not rasterized approximations): the boot splash (normal + LIVE) and the
# boot console, exactly as the 800x480 fbcon paints them (16-color VGA/CP437).
#
# Boots the virt test kernel with virtio-gpu (/dev/fb0 -> fbcon -> tty0), runs a
# tiny init that paints the banner / drives the boot chain on tty0, and grabs the
# screen via the qemu monitor `screendump`. The current overlay reforge-banner is
# injected into the image so captures reflect the working tree, not a stale build.
# Fully ROOTLESS: mke2fs -d, unprivileged qemu.
#
# Usage:  tests/qemu-harness/shots-reforge.sh
# Needs:  qemu-system-arm, mke2fs (e2fsprogs), socat, python3 (Pillow), build/zImage,
#         build/output/images/rootfs.tar[.xz]
# Out:    docs/screenshots/reforge-bootsplash.png, -bootsplash-live.png, -boot-console.png
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
BANNER="${REPO_ROOT}/br-external/board/reforge/rootfs-overlay/usr/bin/reforge-banner"
OUTDIR="${REPO_ROOT}/docs/screenshots"

log() { echo "[shots-reforge] $*"; }
die() { echo "[shots-reforge] ERROR: $*" >&2; exit 1; }
skip() { echo "[shots-reforge] SKIP: $*"; exit 0; }

ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar}"
[ -f "${ROOTFS_TAR}" ] || ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar.xz"
[ -f "${ZIMAGE}" ]     || skip "no ${ZIMAGE} (make qemu-kernel)"
[ -f "${ROOTFS_TAR}" ] || skip "no rootfs.tar (make rootfs)"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v mke2fs >/dev/null || die "mke2fs not installed"
command -v socat  >/dev/null || skip "socat not installed (needed for screendump)"
python3 -c 'import PIL' 2>/dev/null || skip "python3 Pillow not installed"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
STAGE="${WORK}/root"; mkdir -p "${STAGE}"
log "staging rootfs + injecting the working-tree banner ..."
case "${ROOTFS_TAR}" in
    *.xz) tar --numeric-owner -xJf "${ROOTFS_TAR}" -C "${STAGE}" ;;
    *)    tar --numeric-owner -xf  "${ROOTFS_TAR}" -C "${STAGE}" ;;
esac
install -m 0755 "${BANNER}" "${STAGE}/usr/bin/reforge-banner"

# Three capture inits, each painting on the framebuffer console (tty0).
mkdir -p "${STAGE}/sbin"
paint_head='mount -t proc proc /proc 2>/dev/null; mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null    # ephemeral: no live-marker bleed across boots
TTY=/dev/tty0; [ -c "$TTY" ] || TTY=/dev/console
exec > "$TTY" 2>&1'

cat > "${STAGE}/sbin/shot-splash" <<EOF
#!/bin/sh
${paint_head}
printf '\033[2J\033[H'    # clear the kernel boot text for a clean splash
TERM=linux REFORGE_LIVE=0 /usr/bin/reforge-banner
while true; do sleep 3600; done
EOF
cat > "${STAGE}/sbin/shot-splash-live" <<EOF
#!/bin/sh
${paint_head}
printf '\033[2J\033[H'
: > /run/reforge-live 2>/dev/null || true
TERM=linux REFORGE_LIVE=1 /usr/bin/reforge-banner
while true; do sleep 3600; done
EOF
cat > "${STAGE}/sbin/shot-console" <<EOF
#!/bin/sh
${paint_head}
printf '\033[2J\033[H'
TERM=linux /usr/bin/reforge-banner
echo
# Stub the chroot data layout the real device has (reforge-boot chroots into
# /data/.mod/.reforge with /mod bind-mounted at /data/.mod/.mod/.reforge/mod), so S99ok's
# mod->LKG promotion finds its source and the chain runs as a normal install boot.
mkdir -p /data/.mod/.mod/.reforge/mod /data/.mod/.mod/.reforge/state
mount --bind /mod /data/.mod/.mod/.reforge/mod 2>/dev/null
# Drive the real userspace chain so the console shows cloud-block -> zram -> ...
[ -x /mod/start.sh ] && SCREEN_MODE=HEADLESS /mod/start.sh
echo; echo "Welcome to ReForge"; echo "reforge login: "
while true; do sleep 3600; done
EOF
chmod 0755 "${STAGE}/sbin/shot-splash" "${STAGE}/sbin/shot-splash-live" "${STAGE}/sbin/shot-console"

IMG="${BUILD_DIR}/shots-reforge.ext4"
rm -f "${IMG}"; mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -d "${STAGE}" "${IMG}" 1280M

capture() {  # <init> <settle-seconds> <out.png>
    local init="$1" settle="$2" out="$3"
    local mon="${BUILD_DIR}/shots-reforge-mon.sock" ser="${BUILD_DIR}/shots-reforge-ser.log"
    local ppm="${BUILD_DIR}/shots-reforge.ppm"
    rm -f "${mon}" "${ser}" "${ppm}"
    log "boot ${init} (settle ${settle}s) ..."
    qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -smp 2 -m 256 \
        -kernel "${ZIMAGE}" \
        -append "console=tty0 console=ttyAMA0,115200 root=/dev/vda rw rootwait loglevel=3 init=${init}" \
        -device virtio-gpu-pci,xres=800,yres=480 \
        -display none -monitor "unix:${mon},server,nowait" -serial file:"${ser}" \
        -drive "file=${IMG},if=virtio,format=raw,cache=writeback" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 >/dev/null 2>&1 &
    local qp=$!
    local w=0; while [ ! -S "${mon}" ] && [ "${w}" -lt 25 ]; do sleep 1; w=$((w+1)); done
    [ -S "${mon}" ] || { kill -9 "${qp}" 2>/dev/null; die "monitor socket never appeared"; }
    sleep "${settle}"
    printf 'screendump %s\n' "${ppm}" | socat - "UNIX-CONNECT:${mon}" >/dev/null 2>&1 || true
    sleep 2
    kill -9 "${qp}" 2>/dev/null || true
    [ -s "${ppm}" ] || { warn_missing "${out}"; return 0; }
    python3 -c "from PIL import Image; Image.open('${ppm}').save('${out}')"
    log "  wrote ${out}"
}
warn_missing() { echo "[shots-reforge] WARN: no screendump for $1 (see serial log)"; }

mkdir -p "${OUTDIR}"
capture /sbin/shot-splash       14 "${OUTDIR}/reforge-bootsplash.png"
capture /sbin/shot-splash-live  14 "${OUTDIR}/reforge-bootsplash-live.png"
capture /sbin/shot-console      75 "${OUTDIR}/reforge-boot-console.png"
log "done."
