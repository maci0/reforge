#!/usr/bin/env bash
# =============================================================================
# helix-render.sh — render HelixScreen (C++/LVGL9, direct framebuffer) in qemu,
# against a Moonraker-grade fake klippy (no MCU). Mirrors guppy-render.sh:
# HelixScreen is architecturally the same class as GuppyScreen (LVGL on /dev/fb0,
# libhv + spdlog), so it uses the same virtio-gpu fb path that needed the
# /dev/disp fix for guppy.
#
# Lab/eval only — HelixScreen is built by the lab/klipperscreen-eval (now
# helixscreen) path, NOT shipped in the default image. This rig boots the stack
# HEADLESS (moonraker + fake klippy), then launches /opt/helixscreen/bin/helix-screen
# directly (stderr -> console) and captures /dev/fb0.
#
# Usage:   tests/qemu-harness/helix-render.sh        # NO sudo
# Output:  build/helix-home.png (real framebuffer) + build/helix-home-serial.log
# Needs:   qemu-system-arm, socat, mke2fs, build/zImage, a rootfs.tar built with
#          BR2_PACKAGE_HELIXSCREEN=y.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
SIM="${HARNESS_DIR}/guppy/fake-klippy.py"
IMG="${BUILD_DIR}/helix-root.ext4"
FBCAP="${BUILD_DIR}/helix-fb.raw"     # 2nd disk: guest dumps /dev/fb0 here
FBPNG="${BUILD_DIR}/helix-home.png"   # host-converted real framebuffer
MON="${BUILD_DIR}/qemu-helix-mon.sock"
SHOT="${BUILD_DIR}/helix-home.ppm"
SER="${BUILD_DIR}/helix-home-serial.log"
FBDUMP_AT="${FBDUMP_AT:-110}"

MEM="${MEM:-256}"
SETTLE="${SETTLE:-125}"

log() { echo "[helix-render] $*"; }
die() { echo "[helix-render] ERROR: $*" >&2; exit 1; }

ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar.xz}"
[ -f "${ROOTFS_TAR}" ] || ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar"
[ -f "${ZIMAGE}" ]     || { echo "[helix-render] SKIP: no ${ZIMAGE} (make qemu-kernel)"; exit 0; }
[ -f "${ROOTFS_TAR}" ] || { echo "[helix-render] SKIP: no rootfs.tar (make rootfs)"; exit 0; }
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v mke2fs >/dev/null || die "mke2fs not installed (e2fsprogs)"
command -v socat  >/dev/null || die "socat not installed"

# --- 1. stage rootfs, swap klippy for the fake -------------------------------
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
MNT="${WORK}/mnt"; mkdir -p "${MNT}"
log "staging ${ROOTFS_TAR} ..."
tar -C "${MNT}" -xf "${ROOTFS_TAR}"
[ -x "${MNT}/opt/helixscreen/bin/helix-screen" ] || die "no /opt/helixscreen/bin/helix-screen in rootfs (build with BR2_PACKAGE_HELIXSCREEN=y)"
[ -f "${MNT}/mod/start.sh" ] || die "no /mod/start.sh in rootfs"
cp "${SIM}" "${MNT}/opt/fake-klippy.py"; chmod +x "${MNT}/opt/fake-klippy.py"

cat > "${MNT}/mod/init.d/S60klipper" <<'EOF'
#!/bin/sh
[ "$1" = start ] || exit 0
/usr/bin/python3 /opt/fake-klippy.py &
EOF
chmod +x "${MNT}/mod/init.d/S60klipper"

# Boot hook: stack HEADLESS (moonraker + fake klippy, no guppy), then launch
# helix-screen directly with stderr -> console for its fbdev diagnostics.
cat > "${MNT}/etc/init.d/S98helix" <<'EOF'
#!/bin/sh
[ "$1" = start ] || exit 0
[ -x /mod/start.sh ] && SCREEN_MODE=HEADLESS /mod/start.sh > /dev/console 2>&1
sleep 6
mkdir -p /data/helixscreen/cache /data/helixscreen/config /data/helixscreen/log
( cd /opt/helixscreen && HELIX_CACHE_DIR=/data/helixscreen/cache \
    HELIX_CONFIG_DIR=/data/helixscreen/config \
    exec /opt/helixscreen/bin/helix-screen > /dev/console 2>&1 ) &
( sleep "__FBDUMP_AT__"
  dd if=/dev/fb0 of=/dev/vdb bs=1M 2>/dev/null; sync
  echo "===FBDUMPED===" > /dev/console ) &
( sleep 60
  echo "===HELIXDIAG==="
  wget -qO- http://127.0.0.1:7125/server/info 2>/dev/null | head -c 200; echo
  echo "===RAMPROBE helixscreen==="
  grep -E 'MemTotal|MemFree|MemAvailable|Buffers|^Cached|SwapTotal|SwapFree' /proc/meminfo
  echo "-- per-proc VmRSS (KB) --"
  for d in /proc/[0-9]*; do
    n=$(cat $d/comm 2>/dev/null); r=$(awk '/^VmRSS/{print $2}' $d/status 2>/dev/null)
    [ -n "$r" ] && echo "$r $n"
  done | sort -rn | head -14
  echo "===/RAMPROBE==="
  echo "--- helix proc ---"; ps 2>/dev/null | grep -iE 'helix|moonrak|fake-klippy' | grep -v grep
  echo "===/HELIXDIAG===" ) > /dev/console 2>&1 &
EOF
sed -i "s/__FBDUMP_AT__/${FBDUMP_AT}/" "${MNT}/etc/init.d/S98helix"
chmod +x "${MNT}/etc/init.d/S98helix"

log "baking ext4 ..."
rm -f "${IMG}"
mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L helix-root -d "${MNT}" "${IMG}" 1843M
rm -f "${FBCAP}"; truncate -s 4M "${FBCAP}"

# --- 2. boot with virtio-gpu fb ----------------------------------------------
rm -f "${MON}" "${SHOT}" "${SER}"
log "booting qemu (MEM=${MEM} MiB, settle=${SETTLE}s) ..."
qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -m "${MEM}" \
    -kernel "${ZIMAGE}" \
    -append "console=ttyAMA0,115200 loglevel=4 root=/dev/vda rw rootwait" \
    -display none -monitor "unix:${MON},server,nowait" -serial file:"${SER}" \
    -device virtio-gpu-pci,xres=800,yres=480 \
    -drive "file=${IMG},if=virtio,format=raw,cache=writeback" \
    -drive "file=${FBCAP},if=virtio,format=raw" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 >/dev/null 2>&1 &
QP=$!
trap 'kill -9 "${QP}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT
for _ in $(seq 1 20); do [ -S "${MON}" ] && break; sleep 1; done
[ -S "${MON}" ] || die "qemu monitor socket never appeared (see ${SER})"
sleep "${SETTLE}"
printf 'screendump %s\n' "${SHOT}" | socat - "UNIX-CONNECT:${MON}" 2>/dev/null || true
sleep 3
kill -9 "${QP}" 2>/dev/null || true
trap 'rm -rf "${WORK}"' EXIT

# --- 3. convert the captured framebuffer to PNG ------------------------------
if command -v magick >/dev/null 2>&1 && grep -q '===FBDUMPED===' "${SER}" 2>/dev/null; then
    head -c $((800 * 480 * 4)) "${FBCAP}" > "${FBCAP}.frame"
    magick -size 800x480 -depth 8 "bgra:${FBCAP}.frame" "${FBPNG}" 2>/dev/null \
        && log "captured real framebuffer -> ${FBPNG} ($(identify -format '%k colors' "${FBPNG}" 2>/dev/null))" \
        || log "WARN: fb raw->PNG convert failed"
else
    log "WARN: no ===FBDUMPED=== marker — see ${SER}"
fi
log "done. frame: ${FBPNG} ; serial: ${SER}"
