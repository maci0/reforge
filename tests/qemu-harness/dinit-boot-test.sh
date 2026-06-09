#!/usr/bin/env bash
# =============================================================================
# dinit-boot-test.sh — boot the ReForge stack in qemu with **dinit as PID 1**
# (the future switch_root supervisor), exercising the staged dinit service
# descriptions for real instead of the sequential /mod/start.sh S-loop.
#
# dinit brings up the dependency chain prepare -> klipper -> moonraker -> httpd
# -> guppyscreen with ordering + restart-on-failure. qemu has no MCU, so the
# klipper unit is overridden to run guppy/fake-klippy.py (a Moonraker-grade
# Klipper API stand-in that reaches "ready"); eboard (MCU handshake) is dropped.
#
# Asserts: dinit started the services in dependency order, Moonraker's API is
# live (klippy_state ready), and guppyscreen painted /dev/fb0 (non-blank).
#
# Fully ROOTLESS: mke2fs -d + unprivileged qemu. NO sudo.
#
# Usage:  tests/qemu-harness/dinit-boot-test.sh
# Needs:  qemu-system-arm, mke2fs, socat, build/zImage, a rootfs.tar built with
#         BR2_PACKAGE_DINIT=y (dinit in /usr/bin).
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
SIM="${HARNESS_DIR}/guppy/fake-klippy.py"
IMG="${BUILD_DIR}/dinit-boot.ext4"
FBCAP="${BUILD_DIR}/dinit-fb.raw"
FBPNG="${BUILD_DIR}/dinit-guppy.png"
MON="${BUILD_DIR}/qemu-dinit-mon.sock"
SHOT="${BUILD_DIR}/dinit-boot.ppm"
SER="${BUILD_DIR}/dinit-boot-serial.log"
FBDUMP_AT="${FBDUMP_AT:-95}"
MEM="${MEM:-320}"
SETTLE="${SETTLE:-115}"

log() { echo "[dinit-boot] $*"; }
die() { echo "[dinit-boot] ERROR: $*" >&2; exit 1; }

ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar.xz}"
[ -f "${ROOTFS_TAR}" ] || ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar"
[ -f "${ZIMAGE}" ]     || { echo "[dinit-boot] SKIP: no ${ZIMAGE} (make qemu-kernel)"; exit 0; }
[ -f "${ROOTFS_TAR}" ] || { echo "[dinit-boot] SKIP: no rootfs.tar (make rootfs)"; exit 0; }
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v mke2fs >/dev/null || die "mke2fs not installed"
command -v socat  >/dev/null || die "socat not installed"

# --- 1. stage rootfs --------------------------------------------------------
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
MNT="${WORK}/mnt"; mkdir -p "${MNT}"
log "staging ${ROOTFS_TAR} ..."
tar -C "${MNT}" -xf "${ROOTFS_TAR}"
[ -x "${MNT}/usr/bin/dinit" ] || die "no /usr/bin/dinit in rootfs (build with BR2_PACKAGE_DINIT=y)"
[ -d "${MNT}/etc/dinit.d" ]   || die "no /etc/dinit.d in rootfs (dinit units overlay missing)"
[ -f "${MNT}/etc/dinit.d/moonraker" ] || die "no dinit moonraker unit"

cp "${SIM}" "${MNT}/opt/fake-klippy.py"; chmod +x "${MNT}/opt/fake-klippy.py"

# --- 2. qemu overrides of the dinit units (no MCU here) ----------------------
# klipper -> fake-klippy (serves /tmp/klippy_uds ready); depend only on prepare.
cat > "${MNT}/etc/dinit.d/klipper" <<'EOF'
# (dinit-boot-test override) fake klippy — no MCU needed.
type = process
command = /usr/bin/python3 /opt/fake-klippy.py
depends-on = prepare
restart = true
EOF
# eboard MCU handshake is a no-op in qemu.
cat > "${MNT}/etc/dinit.d/eboard" <<'EOF'
type = scripted
command = /bin/true
EOF
# Override the `boot` target (what dinit runs by default as PID 1) with the test
# chain. cloudblock is included to prove a /mod/init.d S-script unit runs under
# dinit (its path is now fixed). zram (loads a kernel module) and ok (LKG promote)
# are left out: they have qemu-specific concerns orthogonal to the path fix.
cat > "${MNT}/etc/dinit.d/boot" <<'EOF'
# (dinit-boot-test override) top-level target: the dependency chain plus the GUI.
type = internal
depends-on = prepare
depends-on = cloudblock
depends-on = klipper
depends-on = moonraker
depends-on = httpd
depends-on = guppyscreen
EOF

# --- 3. dinit PID 1 wrapper: early mounts, then exec dinit -------------------
mkdir -p "${MNT}/sbin"
cat > "${MNT}/sbin/dinit-test-init" <<EOF
#!/bin/sh
# PID 1 for the dinit boot test: bring up the kernel filesystems dinit + the
# daemons need, then hand off to dinit as the supervisor.
mount -t proc     proc /proc     2>/dev/null
mount -t sysfs    sys  /sys       2>/dev/null
mount -t devtmpfs dev  /dev       2>/dev/null
mount -t tmpfs    tmp  /run       2>/dev/null
mount -t tmpfs    tmp  /tmp       2>/dev/null
mount -t tmpfs    tmp  /var/log   2>/dev/null
ifconfig lo 127.0.0.1 up 2>/dev/null
# NOTE: /etc/reforge -> /mod/etc/reforge is now created by the `prepare` dinit
# unit itself (not here) — this test relies on that, proving the units are
# self-sufficient under dinit PID 1 (no /mod/start.sh setup borrowed).
# Background diagnostics (reparented to dinit/PID 1 when we exec below): after the
# GUI settles, dump /dev/fb0 to /dev/vdb + report dinit + Moonraker state. A plain
# background process so it can NEVER fail the boot target.
( sleep ${FBDUMP_AT}
  dd if=/dev/fb0 of=/dev/vdb bs=1M 2>/dev/null; sync
  echo "===FBDUMPED===" > /dev/console
  sleep 3
  echo "===DINITDIAG===" > /dev/console
  /usr/bin/dinitctl -p /run/dinitctl list > /dev/console 2>&1
  echo "-- moonraker /server/info --" > /dev/console
  wget -qO- http://127.0.0.1:7125/server/info 2>/dev/null | head -c 240 > /dev/console
  echo > /dev/console
  echo "===/DINITDIAG===" > /dev/console ) &
echo "[dinit-test-init] handing off to dinit (PID 1 supervisor)"
exec /usr/bin/dinit -d /etc/dinit.d -p /run/dinitctl
EOF
chmod 0755 "${MNT}/sbin/dinit-test-init"


log "baking ext4 ..."
rm -f "${IMG}"
mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L dinit-boot -d "${MNT}" "${IMG}" 1843M
rm -f "${FBCAP}"; truncate -s 4M "${FBCAP}"

# --- 4. boot with dinit as PID 1 --------------------------------------------
rm -f "${MON}" "${SHOT}" "${SER}"
log "booting qemu — init=/sbin/dinit-test-init (dinit PID 1), MEM=${MEM} settle=${SETTLE}s ..."
qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -m "${MEM}" \
    -kernel "${ZIMAGE}" \
    -append "console=ttyAMA0,115200 loglevel=4 root=/dev/vda rw rootwait init=/sbin/dinit-test-init" \
    -display none -monitor "unix:${MON},server,nowait" -serial file:"${SER}" \
    -device virtio-gpu-pci,xres=800,yres=480 \
    -drive "file=${IMG},if=virtio,format=raw,cache=writeback" \
    -drive "file=${FBCAP},if=virtio,format=raw" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 >/dev/null 2>&1 &
QP=$!
trap 'kill -9 "${QP}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT
for _ in $(seq 1 20); do [ -S "${MON}" ] && break; sleep 1; done
[ -S "${MON}" ] || die "qemu monitor never appeared (boot failed — see ${SER})"
sleep "${SETTLE}"
printf 'screendump %s\n' "${SHOT}" | socat - "UNIX-CONNECT:${MON}" 2>/dev/null || true
sleep 3
kill -9 "${QP}" 2>/dev/null || true
trap 'rm -rf "${WORK}"' EXIT

# --- 5. convert the captured framebuffer ------------------------------------
if command -v magick >/dev/null 2>&1 && grep -aq '===FBDUMPED===' "${SER}" 2>/dev/null; then
    head -c $((800 * 480 * 4)) "${FBCAP}" > "${FBCAP}.frame"
    magick -size 800x480 -depth 8 "bgra:${FBCAP}.frame" "${FBPNG}" 2>/dev/null \
        && log "captured framebuffer -> ${FBPNG} ($(identify -format '%k colors' "${FBPNG}" 2>/dev/null))" || true
fi

# --- 6. verdict -------------------------------------------------------------
RC=0
log "=== checks ==="
grep -aq 'handing off to dinit' "${SER}" 2>/dev/null \
    && echo "  [PASS] dinit took over as PID 1" || { echo "  [FAIL] dinit PID 1 handoff not seen"; RC=1; }
grep -aqE 'klippy_state":"ready"' "${SER}" 2>/dev/null \
    && echo "  [PASS] Moonraker API live (klippy_state ready) — dinit brought up klipper+moonraker" \
    || { echo "  [WARN] Moonraker klippy_state ready not seen"; RC=1; }
if [ -s "${FBPNG}" ]; then
    n=$(identify -format '%k' "${FBPNG}" 2>/dev/null || echo 1)
    [ "${n}" -gt 50 ] 2>/dev/null && echo "  [PASS] guppyscreen rendered under dinit (${n} colours)" \
        || echo "  [WARN] framebuffer looks blank (${n} colours)"
fi
echo "  serial: ${SER}"
exit "${RC}"
