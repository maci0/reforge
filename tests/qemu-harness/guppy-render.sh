#!/usr/bin/env bash
# =============================================================================
# guppy-render.sh — bring the full ReForge stack to a "ready" printer in qemu
# with NO MCU, by swapping real klippy for a Moonraker-grade fake.
#
# GuppyScreen talks to Moonraker (websocket), which talks to klippy (unix socket
# /tmp/klippy_uds). With no MCU, real klippy never reaches "ready". This swaps it
# for guppy/fake-klippy.py — a Klipper API stand-in that completes Moonraker's
# handshake (info/list_endpoints/objects/list+subscribe/register_remote_method)
# as READY. RESULT (verified via the GUPPYDIAG dump): Moonraker reports
# `klippy_connected:true, klippy_state:"ready", missing_klippy_requirements:[]`
# and GuppyScreen connects + subscribes to the full object set.
#
# KNOWN LIMITATION — the screendump is still BLANK. GuppyScreen (LVGL fbdev) is
# fully live but its draws don't reach the qemu virtio-gpu scanout (an
# LVGL-vs-virtio-gpu framebuffer-flush quirk — Qt/firmwareExe flushes and renders
# on the same fb, LVGL here does not). This is a rendering/capture issue ONLY,
# independent of the printer-ready simulation, which works. So this harness is
# primarily a full-stack "ready" rig for Moonraker/OTA/API testing; the on-screen
# GuppyScreen capture needs the fb-flush issue solved separately.
#
# Fully ROOTLESS (no sudo): the ext4 is baked from a staging dir with `mke2fs -d`
# and qemu runs unprivileged (its monitor socket is user-owned, so socat
# screendump needs no sudo).
#
# Usage:   tests/qemu-harness/guppy-render.sh        # NO sudo
#          SETTLE=75 tests/qemu-harness/guppy-render.sh
# Output:  tests/qemu-harness/build/guppy-home.ppm   (convert with magick)
#          tests/qemu-harness/build/guppy-home-serial.log
# Needs:   qemu-system-arm, socat, mke2fs (e2fsprogs), build/zImage,
#          build/output/images/rootfs.tar[.xz]
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
SIM="${HARNESS_DIR}/guppy/fake-klippy.py"
IMG="${BUILD_DIR}/guppy-root.ext4"
MON="${BUILD_DIR}/qemu-guppy-mon.sock"
SHOT="${BUILD_DIR}/guppy-home.ppm"
SER="${BUILD_DIR}/guppy-home-serial.log"

MEM="${MEM:-256}"
SETTLE="${SETTLE:-75}"

log() { echo "[guppy-render] $*"; }
die() { echo "[guppy-render] ERROR: $*" >&2; exit 1; }

ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar.xz}"
[ -f "${ROOTFS_TAR}" ] || ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar"
[ -f "${ZIMAGE}" ]     || { echo "[guppy-render] SKIP: no ${ZIMAGE} (make qemu-kernel)"; exit 0; }
[ -f "${ROOTFS_TAR}" ] || { echo "[guppy-render] SKIP: no rootfs.tar (make rootfs)"; exit 0; }
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v mke2fs >/dev/null || die "mke2fs not installed (e2fsprogs)"
command -v socat  >/dev/null || die "socat not installed"

# --- 1. stage the rootfs, swap klippy for the fake, force SCREEN_MODE=GUPPY ----
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
MNT="${WORK}/mnt"; mkdir -p "${MNT}"
log "staging ${ROOTFS_TAR} ..."
tar -C "${MNT}" -xf "${ROOTFS_TAR}"

[ -f "${MNT}/mod/start.sh" ] || die "no /mod/start.sh in rootfs — Task-3 layout expected"
mkdir -p "${MNT}/opt"
cp "${SIM}" "${MNT}/opt/fake-klippy.py"
chmod +x "${MNT}/opt/fake-klippy.py"

# Replace S60klipper with one that launches the fake API server on /tmp/klippy_uds.
cat > "${MNT}/mod/init.d/S60klipper" <<'EOF'
#!/bin/sh
# (qemu guppy-render override) serve a canned READY klippy at /tmp/klippy_uds so
# Moonraker reaches "ready" with no MCU. The real klippy launch is bypassed.
[ "$1" = start ] || exit 0
/usr/bin/python3 /opt/fake-klippy.py &
EOF
chmod +x "${MNT}/mod/init.d/S60klipper"

# Boot hook: run the ReForge stack with SCREEN_MODE=GUPPY (Task-3 moved init to
# /mod; a direct boot must invoke /mod/start.sh — same as mem-probe).
cat > "${MNT}/etc/init.d/S98guppy" <<'EOF'
#!/bin/sh
[ "$1" = start ] || exit 0
[ -x /mod/start.sh ] && SCREEN_MODE=GUPPY /mod/start.sh > /dev/console 2>&1
# Diagnostics: after the stack settles, dump whether Moonraker accepted the fake
# klippy ("Klippy ready") + guppy's own state, to the serial console.
( sleep 55
  echo "===GUPPYDIAG==="
  echo "--- /tmp/klippy_uds ---"; ls -la /tmp/klippy_uds 2>&1
  echo "--- moonraker /server/info (klippy_state) ---"
  wget -qO- http://127.0.0.1:7125/server/info 2>/dev/null | head -c 600; echo
  echo "--- moonraker /printer/info ---"
  wget -qO- http://127.0.0.1:7125/printer/info 2>/dev/null | head -c 400; echo
  echo "--- moonraker.log ---"
  L=$(find /var /tmp /run /opt /root -name 'moonraker.log' 2>/dev/null | head -1)
  echo "log: ${L:-none}"; [ -n "$L" ] && grep -iE 'klippy|ready|identif|error|invalid|object' "$L" 2>/dev/null | tail -20
  echo "--- guppyconfig.json ---"; cat /opt/guppyscreen/guppyconfig.json 2>/dev/null | head -20
  echo "--- guppyscreen log ---"
  GL=$(find / -name 'guppyscreen.log' -o -name 'guppy*.log' 2>/dev/null | head -1)
  echo "log: ${GL:-none}"; [ -n "$GL" ] && tail -25 "$GL" 2>/dev/null
  echo "--- /dev/fb0 + fbset ---"; ls -la /dev/fb0 2>&1; fbset 2>/dev/null | head -6
  echo "--- guppy proc ---"; ps 2>/dev/null | grep -iE 'guppy|moonrak|fake-klippy' | grep -v grep
  echo "===/GUPPYDIAG===" ) > /dev/console 2>&1 &
EOF
chmod +x "${MNT}/etc/init.d/S98guppy"

log "baking ext4 (mke2fs -d, rootless) ..."
rm -f "${IMG}"
mke2fs -q -F -t ext4 -L "guppy-root" -d "${MNT}" "${IMG}" 1843M

# --- 2. boot unprivileged with a virtio-gpu fb (so /dev/fb0 exists) -----------
rm -f "${MON}" "${SHOT}" "${SER}"
log "booting qemu (MEM=${MEM} MiB, settle=${SETTLE}s, no sudo) ..."
qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -m "${MEM}" \
    -kernel "${ZIMAGE}" \
    -append "console=ttyAMA0,115200 loglevel=4 root=/dev/vda rw rootwait" \
    -display none -monitor "unix:${MON},server,nowait" -serial file:"${SER}" \
    -device virtio-gpu-pci,xres=800,yres=480 \
    -drive "file=${IMG},if=virtio,format=raw,cache=writeback" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 >/dev/null 2>&1 &
QP=$!
trap 'kill -9 "${QP}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT
for _ in $(seq 1 20); do [ -S "${MON}" ] && break; sleep 1; done
[ -S "${MON}" ] || die "qemu monitor socket never appeared (boot failed — see ${SER})"
sleep "${SETTLE}"

printf 'screendump %s\n' "${SHOT}" | socat - "UNIX-CONNECT:${MON}" 2>/dev/null || true
sleep 3
kill -9 "${QP}" 2>/dev/null || true
trap 'rm -rf "${WORK}"' EXIT

# --- 3. verdict ---------------------------------------------------------------
if grep -q 'Klippy ready' "${SER}" 2>/dev/null; then
    log "moonraker reached 'Klippy ready' (fake klippy accepted)"
else
    log "WARN: 'Klippy ready' not seen in serial — guppy may be offline (see ${SER})"
fi
[ -s "${SHOT}" ] || die "no screendump produced (see ${SER})"
log "PASS: rendered ${SHOT}"
log "  to view: magick ${SHOT} guppy-home.png"
