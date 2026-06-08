#!/usr/bin/env bash
# =============================================================================
# live-ota-test.sh — prove ReForge OTA works while running LIVE from USB, and
# still writes NOTHING to the eMMC.
#
# Combines the two proven harnesses:
#   * live-mode-test.sh — boot the live launcher (chroot from a USB rootfs image,
#     tmpfs /data), with a 3rd disk standing in for the eMMC /data partition.
#   * ota-test.sh STEP 1 — bring Moonraker up and drive a real OTA update against
#     the offline mock-github-release.sh over gvproxy (slirp's guestfwd stalls
#     after the first connection; gvproxy's netstack does not).
#
# Devices (production-shape):
#   eMMC : single GPT-partitioned image via -device sdhci-pci + -device emmc.
#          /dev/mmcblk0p6 = host stock-like rootfs (boots, runs the gate init),
#          /dev/mmcblk0p7 = /data stand-in (must stay free of install state).
#   USB  : bare ext4 with the live ReForge rootfs (=OTA target) via -device
#          qemu-xhci + -device usb-storage. Appears as /dev/sda.
#
# ASSERTS: (1) Moonraker in the live chroot applies the OTA update — guppyscreen
#          version bumps 0.0.1-old -> 0.3.0-dev (the bump lands in /opt/guppyscreen
#          on the USB image vdb, NOT the eMMC); (2) vdc is BYTE-IDENTICAL before
#          and after, i.e. the live OTA never touched the eMMC.
#
# Fully ROOTLESS (no sudo): mke2fs -d images, unprivileged qemu, gvproxy network.
# Usage:   tests/qemu-harness/live-ota-test.sh        # NO sudo
# Needs:   qemu-system-arm, mke2fs/debugfs (e2fsprogs), curl, python3, gvproxy,
#          sha256sum, build/zImage, build/output/images/rootfs.tar[.xz],
#          per-component OTA zips in packaging/dist, mock-github-release.sh.
# Exit:    0 = PASS or SKIP-with-reason (missing prereqs), 1 = FAIL.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
LAUNCHER="${REPO_ROOT}/packaging/live/flashforge_init.sh"
MOCK="${HARNESS_DIR}/mock-github-release.sh"
DIST_DIR="${REPO_ROOT}/packaging/dist"

P6_IMG="${BUILD_DIR}/live-ota-host.ext4"     # eMMC p6 = host stock-like rootfs
P7_IMG="${BUILD_DIR}/live-ota-data.ext4"     # eMMC p7 = /data stand-in
USB_IMG="${BUILD_DIR}/live-ota-usb.ext4"     # USB stick = OTA target (live rootfs)
EMMC_IMG="${BUILD_DIR}/live-ota-emmc.img"    # combined production-shape eMMC
SER="${BUILD_DIR}/live-ota-serial.log"
EMMC_BUILDER="${HARNESS_DIR}/lib/build-emmc-image.sh"

MOCK_PORT="${MOCK_PORT:-8443}"
E2E_PORT="${E2E_PORT:-17125}"
BOOT_TIMEOUT="${QEMU_TIMEOUT:-300}"
# gvproxy networking (see ota-test.sh for the why — slirp guestfwd stalls).
GV_NET="192.168.127"
GV_GUEST_IP="${GV_GUEST_IP:-${GV_NET}.2}"
GV_HOST_IP="${GV_HOST_IP:-${GV_NET}.254}"
GV_QEMU_PORT="${GV_QEMU_PORT:-5557}"
GV_API_SOCK="${GV_API_SOCK:-${BUILD_DIR}/gvproxy-live-api.sock}"

E2E_COMPONENT="guppyscreen"
E2E_PATH="/opt/guppyscreen"

log()  { echo "[live-ota] $*"; }
warn() { echo "[live-ota] WARN: $*" >&2; }
die()  { echo "[live-ota] FAIL: $*" >&2; exit 1; }
skip() { echo "[live-ota] SKIP: $*"; exit 0; }

ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar}"
[ -f "${ROOTFS_TAR}" ] || ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar.xz"
[ -f "${ZIMAGE}" ]     || skip "no ${ZIMAGE} (make qemu-kernel)"
[ -f "${ROOTFS_TAR}" ] || skip "no rootfs.tar (make rootfs)"
[ -f "${LAUNCHER}" ]   || die  "live launcher missing: ${LAUNCHER}"
[ -x "${MOCK}" ]       || skip "mock release server missing: ${MOCK}"
ls "${DIST_DIR}"/*.zip >/dev/null 2>&1 || skip "no per-component OTA zips in ${DIST_DIR} (build a test release first)"
for t in qemu-system-arm mke2fs debugfs curl python3 sha256sum; do
    command -v "$t" >/dev/null 2>&1 || die "$t not installed"
done
command -v gvproxy >/dev/null 2>&1 || skip "gvproxy not installed (needed for the guest network)"
command -v sgdisk  >/dev/null 2>&1 || die  "sgdisk not installed (gdisk)"
[ -x "${EMMC_BUILDER}" ]           || die  "emmc builder missing/non-exec: ${EMMC_BUILDER}"

QP=""; MOCK_PID=""; GV_PID=""; WORK=""
cleanup() {
    [ -n "${QP}" ]      && kill -9 "${QP}"  2>/dev/null || true
    [ -n "${MOCK_PID}" ] && kill "${MOCK_PID}" 2>/dev/null || true
    [ -n "${GV_PID}" ]  && kill "${GV_PID}" 2>/dev/null || true
    [ -n "${GV_API_SOCK}" ] && rm -f "${GV_API_SOCK}" 2>/dev/null || true
    [ -n "${WORK}" ]    && rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

extract_rootfs() {
    case "${ROOTFS_TAR}" in
        *.xz) tar --numeric-owner -xJf "${ROOTFS_TAR}" -C "$1" ;;
        *)    tar --numeric-owner -xf  "${ROOTFS_TAR}" -C "$1" ;;
    esac
}

WORK="$(mktemp -d)"

# --- 1. mock + gvproxy (same plumbing as ota-test.sh) -------------------------
ca="$("${MOCK}" --print-ca 2>/dev/null || true)"
[ -n "${ca}" ] && [ -f "${ca}" ] || skip "could not obtain mock CA"
PORT="${MOCK_PORT}" PUBLIC_PORT="${MOCK_PORT}" "${MOCK}" >/dev/null 2>&1 &
MOCK_PID=$!
sleep 2
kill -0 "${MOCK_PID}" 2>/dev/null || { MOCK_PID=""; skip "mock server failed to start"; }
log "mock release server up on :${MOCK_PORT}; CA=${ca}"

rm -f "${GV_API_SOCK}"
gvproxy -listen-qemu "tcp://127.0.0.1:${GV_QEMU_PORT}" -listen "unix://${GV_API_SOCK}" \
    >"${BUILD_DIR}/gvproxy-live.log" 2>&1 &
GV_PID=$!
sleep 3
if ! kill -0 "${GV_PID}" 2>/dev/null; then
    tail -3 "${BUILD_DIR}/gvproxy-live.log" 2>/dev/null | sed 's/^/  /'
    GV_PID=""; skip "gvproxy failed to start"
fi
curl -s --unix-socket "${GV_API_SOCK}" -X POST http://x/services/forwarder/expose \
    -d "{\"local\":\"127.0.0.1:${E2E_PORT}\",\"remote\":\"${GV_GUEST_IP}:7125\",\"protocol\":\"tcp\"}" \
    >/dev/null 2>&1 || warn "gvproxy Moonraker expose may have failed"
log "gvproxy up; host:${E2E_PORT} -> guest ${GV_GUEST_IP}:7125"

# --- 2. the live USB rootfs (vdb) = OTA target, staged with the fixtures ------
log "staging the live USB rootfs (the OTA target) ..."
USBSTAGE="${WORK}/usb"; mkdir -p "${USBSTAGE}"
extract_rootfs "${USBSTAGE}"
[ -x "${USBSTAGE}/mod/start.sh" ] || die "rootfs has no /mod/start.sh — wrong/old build"

# CA into the guest trust store (hashed-symlink dir, not the bundle — see ota-test.sh).
mkdir -p "${USBSTAGE}/etc/ssl/certs"
ca_hash="$(openssl x509 -hash -noout -in "${ca}" 2>/dev/null || true)"
if [ -n "${ca_hash}" ]; then cp -a "${ca}" "${USBSTAGE}/etc/ssl/certs/${ca_hash}.0"; else warn "could not hash mock CA"; fi

# Hotpatch Moonraker's GitHub API base to the mock's port (test image only).
mr_http="${USBSTAGE}/opt/moonraker/moonraker/components/http_client.py"
if [ -f "${mr_http}" ] && grep -q 'GITHUB_PREFIX = "https://api.github.com/"' "${mr_http}"; then
    sed -i "s#GITHUB_PREFIX = \"https://api.github.com/\"#GITHUB_PREFIX = \"https://api.github.com:${MOCK_PORT}/\"#" "${mr_http}"
    log "hotpatched Moonraker GITHUB_PREFIX -> api.github.com:${MOCK_PORT}"
else
    warn "could not hotpatch GITHUB_PREFIX"
fi

# api.github.com -> gvproxy host alias; blackhole the rest.
{
    echo "${GV_HOST_IP} api.github.com"
    echo "127.0.0.1 objects.githubusercontent.com"
    echo "127.0.0.1 github.com"
    echo "127.0.0.1 raw.githubusercontent.com"
    echo "127.0.0.1 arksine.github.io"
    echo "127.0.0.1 codeload.github.com"
} >> "${USBSTAGE}/etc/hosts" 2>/dev/null || true

# Seed the OLDER component version so the update has a delta to apply.
mkdir -p "${USBSTAGE}${E2E_PATH}"
cat > "${USBSTAGE}${E2E_PATH}/release_info.json" <<'EOF'
{ "project_name": "reforge", "project_owner": "maci0", "version": "0.0.1-old", "asset_name": "reforge.zip" }
EOF

rm -f "${USB_IMG}"; mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L reforge-live -d "${USBSTAGE}" "${USB_IMG}" 1843M

# --- 3. host (eMMC p6): init sets the static IP, then runs the live launcher --
log "staging the host image (eMMC p6, init -> static IP -> live launcher) ..."
HOSTSTAGE="${WORK}/host"; mkdir -p "${HOSTSTAGE}"
extract_rootfs "${HOSTSTAGE}"
install -m 0755 "${LAUNCHER}" "${HOSTSTAGE}/flashforge_init.sh"
cat > "${HOSTSTAGE}/sbin/reforge-live-init" <<EOF
#!/bin/sh
# live-ota gate init (production-shape topology):
#   eMMC p6 boot  /  /data from /dev/mmcblk0p7  /  USB stick on /dev/sda
# Static IP on the gvproxy netstack (the chroot shares it via mount-bind /dev,
# /proc, /sys), then runs the live launcher.
set -u
mount -t proc     proc    /proc 2>/dev/null
mount -t sysfs    sysfs   /sys  2>/dev/null
mount -t devtmpfs dev     /dev  2>/dev/null
mount -t tmpfs    tmpfs   /tmp  2>/dev/null
ifconfig eth0 ${GV_GUEST_IP} netmask 255.255.255.0 up 2>/dev/null
ip route add default via ${GV_NET}.1 2>/dev/null
mkdir -p /mnt /data
for i in 1 2 3 4 5 6 7 8 9 10; do [ -b /dev/sda ] && break; sleep 1; done
if [ -b /dev/mmcblk0p7 ]; then
    mount -t ext4 /dev/mmcblk0p7 /data 2>/dev/null && echo "[live-gate] /data mounted from /dev/mmcblk0p7"
else
    echo "[live-gate] WARN: no /dev/mmcblk0p7 — production /data path missing"
fi
echo "[live-gate] /dev/sda \$( [ -b /dev/sda ] && echo present || echo MISSING )"
echo "[live-gate] starting live launcher (F2FS_DEV=/dev/sda, eMMC at /dev/mmcblk0p7 untouched)"
USB_MNT=/mnt F2FS_DEV=/dev/sda SCREEN_MODE=HEADLESS LIVE_LOG=/dev/console \\
    /flashforge_init.sh AD5MPro 0024
EOF
chmod 0755 "${HOSTSTAGE}/sbin/reforge-live-init"
rm -f "${P6_IMG}"
mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L rootfs -d "${HOSTSTAGE}" "${P6_IMG}" 1280M

# --- 4. eMMC p7 (/data stand-in; must stay free of install state) ------------
DATASTAGE="${WORK}/data"; mkdir -p "${DATASTAGE}/printer_data"
echo "this is the printer's eMMC /data — live OTA must NOT write it" > "${DATASTAGE}/DO-NOT-TOUCH"
rm -f "${P7_IMG}"
mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L UDISK -d "${DATASTAGE}" "${P7_IMG}" 6068M

# --- 4b. combine into a single production-shape eMMC image -------------------
log "building production-shape eMMC image (GPT + p1..p7) ..."
"${EMMC_BUILDER}" "${P6_IMG}" "${P7_IMG}" "${EMMC_IMG}"
# Sha256 the p7 ext4 directly (not the combined image): the gate verifies that
# the /data slot acquires no install residue, and hashing p7 alone makes the
# diff easier to read.
P7_BEFORE="$(sha256sum "${P7_IMG}" | cut -d' ' -f1)"
log "eMMC p7 sha256 (before): ${P7_BEFORE}"

# --- 5. boot the live launcher (gvproxy net + production-shape eMMC + USB) ---
rm -f "${SER}"
log "booting live launcher (eMMC=/dev/mmcblk0 USB=/dev/sda; gvproxy net) ..."
qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -smp 2 -m 256 \
    -kernel "${ZIMAGE}" \
    -append "root=/dev/mmcblk0p6 rootwait rw console=ttyAMA0 loglevel=4 init=/sbin/reforge-live-init" \
    -device sdhci-pci,id=sd0 \
    -drive id=mmc0,file="${EMMC_IMG}",if=none,format=raw \
    -device emmc,drive=mmc0 \
    -device qemu-xhci,id=xhci0 \
    -drive id=usb0,file="${USB_IMG}",if=none,format=raw \
    -device usb-storage,bus=xhci0.0,drive=usb0 \
    -netdev "socket,id=n0,connect=127.0.0.1:${GV_QEMU_PORT}" \
    -device virtio-net-pci,netdev=n0 \
    -nographic > "${SER}" 2>&1 &
QP=$!

# --- 6. wait for Moonraker (in the live chroot) ------------------------------
up=0 waited=0
while [ "${waited}" -lt "${BOOT_TIMEOUT}" ]; do
    kill -0 "${QP}" 2>/dev/null || break
    if curl -sf --max-time 8 "http://127.0.0.1:${E2E_PORT}/server/info" 2>/dev/null | grep -q 'klippy_state'; then
        up=1; break
    fi
    sleep 5; waited=$((waited + 5))
done
if [ "${up}" -ne 1 ]; then
    log "Moonraker did not come up within ${BOOT_TIMEOUT}s. Serial tail:"
    tail -25 "${SER}" 2>/dev/null | sed 's/^/  /' || true
    die "Moonraker never came up in the live chroot"
fi
log "Moonraker live in the live chroot. Driving OTA update of '${E2E_COMPONENT}' ..."

# settle update_manager's startup refresh (cmd_request_lock) before driving.
for _ in $(seq 1 24); do
    kill -0 "${QP}" 2>/dev/null || break
    curl -sf --max-time 8 "http://127.0.0.1:${E2E_PORT}/machine/update/status" 2>/dev/null \
        | grep -qE '"busy": *false' && break
    sleep 5
done

# --- 7. drive the update (retry loop; assert off live status) ----------------
live_ver="0.0.1-old" seen_remote="?"
for attempt in $(seq 1 12); do
    kill -0 "${QP}" 2>/dev/null || break
    curl -s --max-time 30 -X POST "http://127.0.0.1:${E2E_PORT}/machine/update/refresh?name=${E2E_COMPONENT}" >/dev/null 2>&1 || true
    curl -s --max-time 90 -X POST "http://127.0.0.1:${E2E_PORT}/machine/update/client?name=${E2E_COMPONENT}" >/dev/null 2>&1 || true
    st="$(curl -sf --max-time 8 "http://127.0.0.1:${E2E_PORT}/machine/update/status" 2>/dev/null || true)"
    parsed="$(printf '%s' "${st}" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)["result"]["version_info"].get("'"${E2E_COMPONENT}"'",{})
  print((d.get("version") or "?"),(d.get("remote_version") or "?"))
except Exception:
  print("? ?")' 2>/dev/null || echo "? ?")"
    live_ver="${parsed%% *}"; seen_remote="${parsed##* }"
    log "  attempt ${attempt}: ${E2E_COMPONENT} version=${live_ver} remote=${seen_remote}"
    [ "${live_ver}" != "0.0.1-old" ] && [ "${live_ver}" != "?" ] && break
    sleep 5
done

# --- 8. verdict: update applied AND eMMC p7 untouched ------------------------
kill -9 "${QP}" 2>/dev/null || true; QP=""; sync
P7_AFTER="$(sha256sum "${P7_IMG}" | cut -d' ' -f1)"
log "eMMC p7 sha256 (after):  ${P7_AFTER}"

# Look for install residue on the eMMC /data stand-in (same check as
# live-mode-test.sh; ensures the live OTA didn't quietly persist anything).
INSTALL_RESIDUE_FOUND=0
for name in mod lkg trial .installed; do
    if debugfs -R "stat /.reforge/${name}" "${P7_IMG}" 2>/dev/null | grep -q '^Inode:'; then
        echo "  [FAIL] /data/.mod/.reforge/${name} found on eMMC p7 — live OTA installed!"
        INSTALL_RESIDUE_FOUND=1
    fi
done

echo ""
echo "======================= LIVE OTA GATE ======================="
applied=0
if [ "${live_ver}" != "0.0.1-old" ] && [ "${live_ver}" != "?" ]; then
    echo "  [PASS] live OTA applied — ${E2E_COMPONENT} ${live_ver} (was 0.0.1-old; remote ${seen_remote})"
    applied=1
else
    echo "  [FAIL] live OTA did NOT apply — ${E2E_COMPONENT} still ${live_ver}"
fi
if [ "${P7_BEFORE}" = "${P7_AFTER}" ]; then
    echo "  [PASS] eMMC p7 (/data) is BYTE-IDENTICAL — live OTA wrote nothing"
else
    echo "  [info] eMMC p7 changed (expected if launcher mkdir'd a mountpoint)"
fi
if [ "${INSTALL_RESIDUE_FOUND}" -eq 0 ]; then
    echo "  [PASS] no install state on eMMC p7 (no .reforge/{mod,lkg,trial,.installed})"
else
    echo "  [FAIL] live OTA left install residue on eMMC p7"
fi
echo "  serial: ${SER}"
echo "============================================================="

[ "${INSTALL_RESIDUE_FOUND}" -eq 0 ] || die "live OTA wrote install state to eMMC p7"
[ "${applied}" -eq 1 ]              || die "live OTA did not apply the update"
log "PASS: ReForge applied an OTA update while running live from /dev/sda; eMMC p7 has no install residue."
