#!/usr/bin/env bash
# tests/loopback-install-test.sh — ReForge loopback install validation
#
# Proves the installer (packaging/flashforge_init.sh) works on a fake /data
# without a physical printer.  Needs sudo (loopback mount + ext4 mkfs).
#
# Usage:  sudo tests/loopback-install-test.sh
#         make validate-loopback          (calls sudo automatically)
#
# Env overrides honoured by the installer (set here):
#   REFORGE_DATA_ROOT=<dir>    — fake /data on the loopback image
#   REFORGE_SKIP_ARCH_CHECK=1  — bypass armv7l check on x86 hosts
#   REFORGE_INITD_DIR=<dir>    — redirect init.d symlink to a temp dir
#                                (avoids touching host /etc/init.d)
#
# Exit codes: 0 = PASS, 1 = FAIL (with specific message)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/packaging/dist"

# ---------------------------------------------------------------------------
# Locate the installer .tgz
# ---------------------------------------------------------------------------
TGZ="$(ls -1t "${DIST_DIR}"/reforge-[0-9]*.tgz "${DIST_DIR}"/reforge-*-dev.tgz 2>/dev/null | grep -v uninstall | head -n 1 || true)"
if [ -z "${TGZ}" ]; then
    echo "FAIL: no reforge-*.tgz found in ${DIST_DIR} — run 'make tgz' first" >&2
    exit 1
fi
echo "[test] using: ${TGZ}"

# ---------------------------------------------------------------------------
# Temp dirs + cleanup trap
# ---------------------------------------------------------------------------
LOOP_IMG=""
LOOP_DEV=""
MOUNT_DIR=""
UNPACK_DIR=""
FAKE_HOME=""
FAKE_INITD=""

cleanup() {
    local rc=$?
    # Unmount loopback if mounted
    if [ -n "${MOUNT_DIR}" ] && mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
        umount "${MOUNT_DIR}" 2>/dev/null || true
    fi
    # Detach loop device
    if [ -n "${LOOP_DEV}" ] && losetup "${LOOP_DEV}" &>/dev/null 2>&1; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
    # Remove temp dirs
    [ -n "${MOUNT_DIR}"  ] && rm -rf "${MOUNT_DIR}"  2>/dev/null || true
    [ -n "${UNPACK_DIR}" ] && rm -rf "${UNPACK_DIR}" 2>/dev/null || true
    [ -n "${LOOP_IMG}"   ] && rm -f  "${LOOP_IMG}"   2>/dev/null || true
    [ -n "${FAKE_HOME}"  ] && rm -rf "${FAKE_HOME}"  2>/dev/null || true
    [ -n "${FAKE_INITD}" ] && rm -rf "${FAKE_INITD}" 2>/dev/null || true
    return $rc
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Create 2 GB ext4 loopback image → mount as fake /data
# ---------------------------------------------------------------------------
echo "[test] creating 2 GB loopback image ..."
LOOP_IMG="$(mktemp /tmp/reforge-loopback-XXXXXX.img)"
dd if=/dev/zero of="${LOOP_IMG}" bs=1M count=2048 status=progress 2>&1 | tail -1
mkfs.ext4 -q "${LOOP_IMG}"

MOUNT_DIR="$(mktemp -d /tmp/reforge-data-XXXXXX)"
LOOP_DEV="$(losetup --find --show "${LOOP_IMG}")"
echo "[test] loop device: ${LOOP_DEV}  mount: ${MOUNT_DIR}"
mount "${LOOP_DEV}" "${MOUNT_DIR}"

# ---------------------------------------------------------------------------
# Fake HOME (so the installer cannot write to the real user home)
# Fake INITD dir (so the installer cannot write to host /etc/init.d)
# ---------------------------------------------------------------------------
FAKE_HOME="$(mktemp -d /tmp/reforge-home-XXXXXX)"
FAKE_INITD="$(mktemp -d /tmp/reforge-initd-XXXXXX)"

# ---------------------------------------------------------------------------
# Unpack the .tgz to a temp dir
# ---------------------------------------------------------------------------
echo "[test] unpacking ${TGZ} ..."
UNPACK_DIR="$(mktemp -d /tmp/reforge-unpack-XXXXXX)"
tar -xf "${TGZ}" -C "${UNPACK_DIR}"
ls "${UNPACK_DIR}"

# ---------------------------------------------------------------------------
# Run the installer with all overrides set
# ---------------------------------------------------------------------------
echo "[test] running installer ..."
INSTALLER="${UNPACK_DIR}/flashforge_init.sh"
if [ ! -f "${INSTALLER}" ]; then
    echo "FAIL: flashforge_init.sh not found in unpacked .tgz" >&2
    exit 1
fi

INSTALL_LOG="$(mktemp /tmp/reforge-install-log-XXXXXX)"
HOME="${FAKE_HOME}" \
    REFORGE_DATA_ROOT="${MOUNT_DIR}" \
    REFORGE_SKIP_ARCH_CHECK=1 \
    REFORGE_INITD_DIR="${FAKE_INITD}" \
    sh "${INSTALLER}" 2>&1 | tee "${INSTALL_LOG}"

echo "[test] installer exited $?"

# ---------------------------------------------------------------------------
# Helper: assert
# ---------------------------------------------------------------------------
FAIL_COUNT=0
assert_exists() {
    local label="$1"
    local path="$2"
    if [ -e "${path}" ]; then
        echo "[PASS] ${label}: ${path}"
    else
        echo "[FAIL] ${label}: ${path} — NOT FOUND"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}
assert_executable() {
    local label="$1"
    local path="$2"
    if [ -x "${path}" ]; then
        echo "[PASS] ${label} (executable): ${path}"
    else
        echo "[FAIL] ${label} (executable): ${path} — NOT EXECUTABLE / NOT FOUND"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}
assert_contains() {
    local label="$1"
    local path="$2"
    local needle="$3"
    if grep -q "${needle}" "${path}" 2>/dev/null; then
        echo "[PASS] ${label}: '${needle}' in ${path}"
    else
        echo "[FAIL] ${label}: '${needle}' NOT found in ${path}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}
assert_symlink_target() {
    local label="$1"
    local link="$2"
    local expected_target="$3"
    if [ -L "${link}" ]; then
        local actual_target
        actual_target="$(readlink "${link}")"
        if [ "${actual_target}" = "${expected_target}" ]; then
            echo "[PASS] ${label}: ${link} -> ${actual_target}"
        else
            echo "[FAIL] ${label}: ${link} -> ${actual_target} (expected ${expected_target})"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "[FAIL] ${label}: ${link} is not a symlink"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}
assert_not_written_outside_data() {
    # Check that installer did NOT create files in host /opt or host /etc/init.d
    # (It should only write to MOUNT_DIR and FAKE_INITD)
    local label="$1"
    local suspicious_path="$2"
    # We check if the path was modified in the last 10 seconds (a rough heuristic)
    # More robustly: check that the test-controlled dirs contain expected content
    # and that /opt and /etc/init.d have no new reforge entries beyond what we know
    if [ -e "${suspicious_path}" ]; then
        echo "[FAIL] ${label}: unexpected path exists on host: ${suspicious_path}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "[PASS] ${label}: host path not touched: ${suspicious_path}"
    fi
}

REFORGE_DIR="${MOUNT_DIR}/.reforge"

echo ""
echo "[test] --- ASSERTIONS ---"

# 1. klipper klippy.py exists (rootfs content check)
assert_exists "klipper/klippy.py" "${REFORGE_DIR}/opt/klipper/klippy/klippy.py"

# 2. python3 exists
assert_exists "usr/bin/python3" "${REFORGE_DIR}/usr/bin/python3"

# 3. boot hook file exists + executable (it shipped inside the rootfs)
assert_executable ".shell/reforge-boot" "${REFORGE_DIR}/.shell/reforge-boot"

# 4. boot hook symlink: installer created FAKE_INITD/S01reforge -> REFORGE_DIR/.shell/reforge-boot
EXPECTED_LINK="${FAKE_INITD}/S01reforge"
EXPECTED_TARGET="${REFORGE_DIR}/.shell/reforge-boot"
assert_symlink_target "init.d symlink" "${EXPECTED_LINK}" "${EXPECTED_TARGET}"

# 5. .installed stamp present with the version string
assert_exists ".installed stamp" "${REFORGE_DIR}/.installed"
VER="$(cat "${REFORGE_DIR}/.installed" 2>/dev/null || true)"
if [ -n "${VER}" ]; then
    echo "[PASS] .installed contains version: ${VER}"
else
    echo "[FAIL] .installed is empty"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 6. Default screen mode = HEADLESS
assert_exists "config/screen.conf" "${REFORGE_DIR}/config/screen.conf"
assert_contains "SCREEN_MODE=HEADLESS" "${REFORGE_DIR}/config/screen.conf" "^SCREEN_MODE=HEADLESS"

# 6b. Self-contained mod/ + LKG seed (run-from-mod model)
assert_executable "mod/start.sh" "${REFORGE_DIR}/mod/start.sh"
assert_exists "mod/init.d/S60klipper" "${REFORGE_DIR}/mod/init.d/S60klipper"
assert_exists "mod/release_info.json" "${REFORGE_DIR}/mod/release_info.json"
assert_exists "lkg seed (release_info.json)" "${REFORGE_DIR}/lkg/release_info.json"
# No /etc/init.d mirror of the reforge S-scripts inside the installed chroot.
assert_not_written_outside_data "no /etc/init.d S-script mirror" "${REFORGE_DIR}/etc/init.d/S60klipper"

# 7. Installer did NOT write outside $DATA
#    - host /etc/init.d should NOT have S01reforge (we used FAKE_INITD)
assert_not_written_outside_data "host /etc/init.d clean" "/etc/init.d/S01reforge"
#    - host /opt should not have a reforge dir
assert_not_written_outside_data "host /opt clean" "/opt/reforge"
#    - FAKE_HOME should be empty (installer doesn't write to home)
if [ -z "$(ls -A "${FAKE_HOME}" 2>/dev/null)" ]; then
    echo "[PASS] fake HOME is clean (no writes)"
else
    echo "[WARN] fake HOME has content: $(ls "${FAKE_HOME}")"
    # Not a hard fail — installer may legitimately touch HOME in edge cases
fi

echo ""
echo "--- SUMMARY ---"
if [ "${FAIL_COUNT}" -eq 0 ]; then
    echo "PASS: loopback install verified"
    exit 0
else
    echo "FAIL: ${FAIL_COUNT} assertion(s) failed"
    exit 1
fi
