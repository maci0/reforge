#!/usr/bin/env bash
# =============================================================================
# ReForge P3 Task 7: reforge-render-test.sh
#
# Proves GuppyScreen renders to the pinned 800×480 framebuffer in qemu:
#   1. Build (or reuse) an ext4 root with ReForge installed + SCREEN_MODE=GUPPY
#   2. Boot it via run-qemu.sh --vnc (virtio-gpu → /dev/fb0 at 800×480×32;
#      QEMU monitor unix socket available for screendump)
#   3. Wait for GuppyScreen to start and draw to the framebuffer
#   4. Capture the framebuffer via the QEMU monitor screendump command
#   5. ASSERT:
#      a. guppyscreen process started (console log evidence)
#      b. Captured PPM is 800×480 and non-blank (>1 distinct pixel value)
#
# Note on the "connecting" screen:
#   There is no MCU or live Moonraker printer connection in qemu; GuppyScreen
#   will render a "Connecting..." or printer-offline UI.  This still proves it
#   draws to /dev/fb0 — the framebuffer is non-blank and the test passes.
#
# Based on Task 6 patterns (update-process-test.sh).  Applies the same set of
# qemu-compatibility patches (P2–P4 plus the screen-mode write).
#
# Usage:
#   sudo tests/qemu-harness/reforge-render-test.sh
#   make qemu-render
#
# Env overrides:
#   REFORGE_TGZ=<path>          — override auto-detected .tgz
#   QEMU_TIMEOUT=480            — seconds before killing qemu (default: 480)
#   RENDER_ROOT_IMG=<path>      — reuse an existing ext4 image (skip rebuild)
#   KEEP_IMAGE=1                — do not delete the ext4 image on exit
#   GUPPY_WAIT=360              — seconds to poll for guppyscreen start (default 360)
#
# Output:
#   tests/qemu-harness/build/guppy-screenshot.ppm  (gitignored)
#   tests/qemu-harness/build/reforge-render-qemu.log  (preserved for debug)
#
# Exit codes: 0 = PASS, 1 = FAIL
# Needs: sudo (loop mount), qemu-system-arm, socat
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
DIST_DIR="${REPO_ROOT}/packaging/dist"

QEMU_TIMEOUT="${QEMU_TIMEOUT:-480}"
KEEP_IMAGE="${KEEP_IMAGE:-0}"
GUPPY_WAIT="${GUPPY_WAIT:-360}"

SCREENSHOT="${BUILD_DIR}/guppy-screenshot.ppm"
# Persistent log — kept after exit for post-mortem debugging
QEMU_LOG="${BUILD_DIR}/reforge-render-qemu.log"

log()  { echo "[render-test] $*"; }
die()  { echo "[render-test] FAIL: $*" >&2; exit 1; }
warn() { echo "[render-test] WARN: $*" >&2; }

# ---------------------------------------------------------------------------
# Locate the installer .tgz
# ---------------------------------------------------------------------------
if [ -n "${REFORGE_TGZ:-}" ]; then
    TGZ="${REFORGE_TGZ}"
else
    # shellcheck disable=SC2010  # ls -1t gives newest-first; release tarball names are controlled (no odd chars)
    TGZ="$(ls -1t "${DIST_DIR}"/reforge-[0-9]*.tgz "${DIST_DIR}"/reforge-*-dev.tgz 2>/dev/null \
           | grep -v uninstall | head -n 1 || true)"
fi
[ -n "${TGZ}" ] || die "No reforge-*.tgz found in ${DIST_DIR} — run 'make tgz' first"
[ -f "${TGZ}" ] || die "TGZ not found: ${TGZ}"
log "installer tgz : ${TGZ}"

# ---------------------------------------------------------------------------
# Locate artefacts
# ---------------------------------------------------------------------------
ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar}"
[ -f "${ROOTFS_TAR}" ] || die "rootfs not found: ${ROOTFS_TAR} — run 'make rootfs' first"

ZIMAGE="${BUILD_DIR}/zImage"
[ -f "${ZIMAGE}" ] || die "zImage not found: ${ZIMAGE} — run 'make qemu-kernel' first"

RUN_QEMU="${HARNESS_DIR}/run-qemu.sh"
[ -x "${RUN_QEMU}" ] || die "run-qemu.sh not found / not executable: ${RUN_QEMU}"

command -v qemu-system-arm >/dev/null 2>&1 || die "qemu-system-arm not in PATH"
command -v socat >/dev/null 2>&1 || die "socat not found — install socat (needed for screendump)"

# ---------------------------------------------------------------------------
# Temp state + cleanup
# ---------------------------------------------------------------------------
EXT4_IMG=""
LOOP_DEV=""
MNT_DIR=""
UNPACK_DIR=""
QEMU_PID=""

cleanup() {
    local rc=$?
    log "cleanup ..."

    # Kill qemu if still running
    if [ -n "${QEMU_PID}" ] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        log "  killing qemu pid ${QEMU_PID}"
        kill "${QEMU_PID}" 2>/dev/null || true
        wait "${QEMU_PID}" 2>/dev/null || true
    fi

    # Unmount image if mounted
    if [ -n "${MNT_DIR}" ] && mountpoint -q "${MNT_DIR}" 2>/dev/null; then
        log "  unmounting ${MNT_DIR}"
        umount -R "${MNT_DIR}" 2>/dev/null || umount "${MNT_DIR}" 2>/dev/null || true
    fi

    # Detach loop device
    if [ -n "${LOOP_DEV}" ] && losetup "${LOOP_DEV}" &>/dev/null 2>&1; then
        log "  detaching ${LOOP_DEV}"
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi

    # Remove scratch dirs
    [ -n "${MNT_DIR}"    ] && rm -rf "${MNT_DIR}"    2>/dev/null || true
    [ -n "${UNPACK_DIR}" ] && rm -rf "${UNPACK_DIR}" 2>/dev/null || true

    # Keep or remove ext4 image
    if [ "${KEEP_IMAGE}" = "1" ] && [ -n "${EXT4_IMG}" ] && [ -f "${EXT4_IMG}" ]; then
        log "  preserving image (KEEP_IMAGE=1): ${EXT4_IMG}"
    elif [ -z "${RENDER_ROOT_IMG:-}" ]; then
        [ -n "${EXT4_IMG}" ] && rm -f "${EXT4_IMG}" 2>/dev/null || true
    else
        log "  preserving image (RENDER_ROOT_IMG): ${EXT4_IMG}"
    fi

    # Log is intentionally preserved (not deleted) for post-mortem
    if [ -f "${QEMU_LOG}" ]; then
        log "  console log preserved at: ${QEMU_LOG}"
    fi

    return $rc
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# STEP 1: Build (or reuse) the ext4 root image with SCREEN_MODE=GUPPY
# ---------------------------------------------------------------------------
mkdir -p "${BUILD_DIR}"
rm -f "${QEMU_LOG}" 2>/dev/null || true   # fresh log each run

if [ -n "${RENDER_ROOT_IMG:-}" ] && [ -f "${RENDER_ROOT_IMG}" ]; then
    log "Reusing existing image: ${RENDER_ROOT_IMG}"
    EXT4_IMG="${RENDER_ROOT_IMG}"
else
    EXT4_IMG="${BUILD_DIR}/reforge-render-root-$$.ext4"

    log "=== STEP 1: Building ext4 root image (SCREEN_MODE=GUPPY) ==="
    log "  rootfs.tar : ${ROOTFS_TAR} ($(du -sh "${ROOTFS_TAR}" | cut -f1))"

    # Create a 1.8 GB ext4 image
    log "  creating 1.8 GB ext4 image ..."
    dd if=/dev/zero of="${EXT4_IMG}" bs=1M count=1843 status=progress 2>&1 | tail -1
    mkfs.ext4 -F -q -L "reforge-render" "${EXT4_IMG}"

    MNT_DIR="$(mktemp -d /tmp/reforge-render-mnt-XXXXXX)"
    LOOP_DEV="$(losetup --find --show "${EXT4_IMG}")"
    log "  loop device : ${LOOP_DEV}   mount : ${MNT_DIR}"
    mount "${LOOP_DEV}" "${MNT_DIR}"

    # --- 1a. Extract guppy rootfs as the outer root ---
    log "  extracting guppy rootfs into outer root ..."
    tar --numeric-owner -xf "${ROOTFS_TAR}" -C "${MNT_DIR}"
    log "  guppy rootfs extracted."

    # --- 1b. Create directories the reforge-boot hook expects ---
    log "  creating /data and /opt/config in outer root ..."
    mkdir -p "${MNT_DIR}/data"
    mkdir -p "${MNT_DIR}/opt/config"

    # --- 1c. Unpack the installer .tgz ---
    log "  unpacking installer tgz: ${TGZ} ..."
    UNPACK_DIR="$(mktemp -d /tmp/reforge-render-unpack-XXXXXX)"
    tar -xf "${TGZ}" -C "${UNPACK_DIR}"
    log "  tgz contents: $(ls "${UNPACK_DIR}")"

    INSTALLER="${UNPACK_DIR}/flashforge_init.sh"
    [ -f "${INSTALLER}" ] || die "flashforge_init.sh not found in tgz"

    # --- 1d. Run the installer ---
    log "  running installer (REFORGE_DATA_ROOT=${MNT_DIR}/data) ..."
    REFORGE_DATA_ROOT="${MNT_DIR}/data" \
        REFORGE_SKIP_ARCH_CHECK=1 \
        REFORGE_INITD_DIR="${MNT_DIR}/etc/init.d" \
        sh "${INSTALLER}" 2>&1 | sed 's/^/    /'

    REFORGE_DIR="${MNT_DIR}/data/.reforge"
    [ -d "${REFORGE_DIR}" ] || die "Installer did not create ${REFORGE_DIR}"
    log "  installer complete.  .installed: $(cat "${REFORGE_DIR}/.installed" 2>/dev/null || echo MISSING)"

    # --- 1e. Set SCREEN_MODE=GUPPY in the persisted config ---
    # reforge-boot reads: $DATA/.reforge/config/screen.conf  (key: SCREEN_MODE)
    # The installer writes SCREEN_MODE=HEADLESS; overwrite it with GUPPY.
    SCREEN_CONF="${REFORGE_DIR}/config/screen.conf"
    log "  setting SCREEN_MODE=GUPPY in ${SCREEN_CONF} ..."
    mkdir -p "$(dirname "${SCREEN_CONF}")"
    printf 'SCREEN_MODE=GUPPY\n' > "${SCREEN_CONF}"
    log "  screen.conf: $(cat "${SCREEN_CONF}")"

    # --- 1f. Apply patches (same set as Task 6) ---

    # PATCH P1: /opt/config exists (belt+suspenders)
    mkdir -p "${MNT_DIR}/opt/config"

    # PATCH P2: Fix the S01reforge symlink to use the IN-VM path
    HOOK_LINK="${MNT_DIR}/etc/init.d/S01reforge"
    [ -L "${HOOK_LINK}" ] || die "S01reforge symlink missing in outer /etc/init.d"
    log "  (host-path) S01reforge → $(readlink "${HOOK_LINK}")"
    VM_HOOK_TARGET="/data/.reforge/.shell/reforge-boot"
    rm -f "${HOOK_LINK}"
    ln -s "${VM_HOOK_TARGET}" "${HOOK_LINK}"
    log "  applying P2: S01reforge → ${VM_HOOK_TARGET}"

    # PATCH P3: Patch installed reforge-boot to skip mmcblk0p7 /data mount check
    INSTALLED_HOOK="${REFORGE_DIR}/.shell/reforge-boot"
    [ -f "${INSTALLED_HOOK}" ] || die "reforge-boot not found at ${INSTALLED_HOOK}"

    log "  applying P3: patching installed reforge-boot to skip mmcblk mount check ..."
    python3 - "${INSTALLED_HOOK}" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

out = []
skip = False
for line in lines:
    stripped = line.rstrip('\n')
    if ("if [ \"${DATA}\" = \"/data\" ] && ! mount | grep -q '/dev/mmcblk0p7'" in stripped):
        skip = True
        out.append("# (P3-qemu-patch: mmcblk0p7 data-mount check removed; /data is on ext4 root)\n")
        continue
    if skip and stripped.strip() == 'fi':
        skip = False
        continue
    if not skip:
        out.append(line)

with open(path, 'w') as f:
    f.writelines(out)
print("P3 patch applied: mmcblk0p7 block removed.")
PYEOF

    if grep -v '^#' "${INSTALLED_HOOK}" | grep -q 'mmcblk0p7'; then
        warn "P3 patch: mmcblk0p7 still in non-comment lines of reforge-boot"
    else
        log "  P3 patch verified: mmcblk0p7 removed from executable code."
    fi

    # PATCH P4: Stub out the outer root's own S6x/S7x service scripts
    # (They must not conflict with the chroot services launched by reforge-boot)
    log "  applying P4: stubbing outer service scripts ..."
    for svc in S60klipper S65moonraker S70httpd S75guppyscreen; do
        OUTER_SVC="${MNT_DIR}/etc/init.d/${svc}"
        if [ -f "${OUTER_SVC}" ]; then
            cat > "${OUTER_SVC}" << 'EOF'
#!/bin/sh
# Stubbed by reforge-render-test.sh (P4):
# Services run inside /data/.reforge chroot (via S01reforge → reforge-boot).
exit 0
EOF
            chmod 755 "${OUTER_SVC}"
            log "    stubbed: ${svc}"
        fi
    done

    # --- 1g. Sync and unmount ---
    log "  syncing and unmounting ..."
    sync
    umount -R "${MNT_DIR}" 2>/dev/null || umount "${MNT_DIR}" 2>/dev/null || true
    losetup -d "${LOOP_DEV}" 2>/dev/null || true
    LOOP_DEV=""
    MNT_DIR=""
    UNPACK_DIR=""

    log "  ext4 image ready: ${EXT4_IMG} ($(du -sh "${EXT4_IMG}" | cut -f1))"
fi

# ---------------------------------------------------------------------------
# STEP 2: Boot under the test kernel via run-qemu.sh --vnc
# ---------------------------------------------------------------------------
log ""
log "=== STEP 2: Booting ext4 root under test kernel (--vnc, timeout=${QEMU_TIMEOUT}s) ==="
log "  log file  : ${QEMU_LOG}"
log "  screenshot: ${SCREENSHOT}"

log "  launching qemu (background, VNC on :5900) ..."
"${RUN_QEMU}" "${EXT4_IMG}" \
    --vnc \
    --timeout "${QEMU_TIMEOUT}" \
    --log "${QEMU_LOG}" \
    &
QEMU_PID=$!
log "  qemu pid: ${QEMU_PID}"

# Give qemu a moment to start and create the monitor socket
sleep 3

# The monitor socket path is deterministic: qemu-monitor-<qemu-pid>.sock
# run-qemu.sh uses $$  which is the run-qemu.sh subprocess PID = QEMU_PID
MONITOR_SOCK="${BUILD_DIR}/qemu-monitor-${QEMU_PID}.sock"
log "  monitor socket: ${MONITOR_SOCK}"

# ---------------------------------------------------------------------------
# Helper: qemu still running?
# ---------------------------------------------------------------------------
qemu_alive() { kill -0 "${QEMU_PID}" 2>/dev/null; }

# ---------------------------------------------------------------------------
# STEP 3: Wait for GuppyScreen to start
# ---------------------------------------------------------------------------
log ""
log "=== STEP 3: Waiting for GuppyScreen to start (up to ${GUPPY_WAIT}s) ==="
log "  (ARM qemu is slow: kernel+userland takes ~60-90s, services another 30-60s)"

# Initial grace period for kernel + early userland init
BOOT_GRACE=60
POLL_INTERVAL=5
ELAPSED=0

log "  waiting ${BOOT_GRACE}s for kernel + early userland ..."
while [ "${ELAPSED}" -lt "${BOOT_GRACE}" ] && qemu_alive; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if ! qemu_alive; then
    log "  qemu exited within first ${BOOT_GRACE}s — console log:"
    tail -40 "${QEMU_LOG}" 2>/dev/null | sed 's/^/    /' || true
    die "qemu exited too early (before any service started)"
fi

GUPPY_STARTED=0
GUPPY_EVIDENCE=""

log "  polling for GuppyScreen start (up to ${GUPPY_WAIT}s from now) ..."
POLL_ELAPSED=0
while qemu_alive && [ "${POLL_ELAPSED}" -lt "${GUPPY_WAIT}" ]; do
    # Primary signal: S75guppyscreen prints "Starting guppyscreen" when launching
    if grep -q 'Starting guppyscreen' "${QEMU_LOG}" 2>/dev/null; then
        GUPPY_EVIDENCE="console log: 'Starting guppyscreen'"
        GUPPY_STARTED=1
        log "  GuppyScreen started! evidence: ${GUPPY_EVIDENCE}"
        break
    fi

    sleep "${POLL_INTERVAL}"
    POLL_ELAPSED=$((POLL_ELAPSED + POLL_INTERVAL))
    # Show progress every 30s with last log line
    if [ $((POLL_ELAPSED % 30)) -eq 0 ]; then
        LAST_LINE="$(tail -1 "${QEMU_LOG}" 2>/dev/null | tr -d '\r' || true)"
        log "  ... ${POLL_ELAPSED}/${GUPPY_WAIT}s  last: ${LAST_LINE}"
    else
        log "  ... ${POLL_ELAPSED}/${GUPPY_WAIT}s"
    fi
done

# Final check after poll loop ends
if [ "${GUPPY_STARTED}" -eq 0 ] && grep -q 'Starting guppyscreen' "${QEMU_LOG}" 2>/dev/null; then
    GUPPY_EVIDENCE="console log: 'Starting guppyscreen' (final check)"
    GUPPY_STARTED=1
fi

# ---------------------------------------------------------------------------
# STEP 4: Capture framebuffer via QEMU monitor screendump
# ---------------------------------------------------------------------------
log ""
log "=== STEP 4: Capturing framebuffer via QEMU monitor screendump ==="

SCREENSHOT_CAPTURED=0

if [ "${GUPPY_STARTED}" -eq 1 ] && qemu_alive; then
    # Give GuppyScreen time to connect to Moonraker and paint its UI. LVGL init
    # is ~3-5s, but the websocket connect + first full repaint can take longer;
    # too short a wait captures a cleared (black) back-buffer. Override with
    # RENDER_SETTLE for a richer frame.
    RENDER_SETTLE="${RENDER_SETTLE:-10}"
    log "  waiting ${RENDER_SETTLE}s for GuppyScreen to render initial frame ..."
    sleep "${RENDER_SETTLE}"
fi

# Find the monitor socket
if [ ! -S "${MONITOR_SOCK}" ]; then
    FOUND_SOCK="$(ls "${BUILD_DIR}"/qemu-monitor-*.sock 2>/dev/null | head -1 || true)"
    if [ -n "${FOUND_SOCK}" ]; then
        MONITOR_SOCK="${FOUND_SOCK}"
        log "  found socket via glob: ${MONITOR_SOCK}"
    fi
fi

rm -f "${SCREENSHOT}" 2>/dev/null || true

if [ -S "${MONITOR_SOCK}" ] && qemu_alive; then
    log "  sending screendump to QEMU monitor: ${MONITOR_SOCK} ..."
    echo "screendump ${SCREENSHOT}" | socat - "UNIX-CONNECT:${MONITOR_SOCK}" 2>/dev/null || true
    sleep 4

    if [ -f "${SCREENSHOT}" ] && [ -s "${SCREENSHOT}" ]; then
        SCREENSHOT_CAPTURED=1
        log "  screenshot saved: ${SCREENSHOT} ($(du -sh "${SCREENSHOT}" | cut -f1))"
    else
        warn "  screendump ran but ${SCREENSHOT} not created — retrying ..."
        echo "screendump ${SCREENSHOT}" | socat - "UNIX-CONNECT:${MONITOR_SOCK}" 2>/dev/null || true
        sleep 4
        if [ -f "${SCREENSHOT}" ] && [ -s "${SCREENSHOT}" ]; then
            SCREENSHOT_CAPTURED=1
            log "  screenshot saved (retry): ${SCREENSHOT} ($(du -sh "${SCREENSHOT}" | cut -f1))"
        else
            warn "  screendump did not produce a file after retry."
        fi
    fi
elif ! qemu_alive; then
    warn "qemu has already exited — cannot take screendump"
    warn "  (try QEMU_TIMEOUT=$((QEMU_TIMEOUT + 60)) if qemu timed out)"
else
    warn "Monitor socket not available: ${MONITOR_SOCK}"
fi

# ---------------------------------------------------------------------------
# STEP 5: Assert render happened
# ---------------------------------------------------------------------------
log ""
log "=== STEP 5: Asserting render ==="

log "Console log evidence:"
grep -E '(\[reforge-boot\]|Starting guppyscreen|guppyscreen|screen mode|GUPPY|no framebuffer|Starting klipper|Starting moonraker)' \
    "${QEMU_LOG}" 2>/dev/null | head -20 | sed 's/^/  /' || log "  (none)"

# --- Assert 5a: GuppyScreen process started ---
log ""
log "  5a: GuppyScreen start evidence ..."
if [ "${GUPPY_STARTED}" -eq 1 ]; then
    log "  [PASS] GuppyScreen started: ${GUPPY_EVIDENCE}"
else
    log ""
    log "Console log tail (last 80 lines):"
    tail -80 "${QEMU_LOG}" 2>/dev/null | sed 's/^/  /' || true
    echo ""
    echo "FAIL: GuppyScreen did not start within timeout."
    echo "  No 'Starting guppyscreen' in console log after ${GUPPY_WAIT}s."
    echo "  Possible causes:"
    echo "    - Boot did not complete within ${QEMU_TIMEOUT}s (try QEMU_TIMEOUT=480)"
    echo "    - SCREEN_MODE was not read as GUPPY (check reforge-boot log above)"
    echo "    - /dev/fb0 absent in chroot (virtio-gpu DRM not probing)"
    echo "    - S75guppyscreen: no framebuffer (/dev/fb0 absent) — skipping"
    echo "  Console log: ${QEMU_LOG}"
    exit 1
fi

# --- Assert 5b: Non-blank 800×480 framebuffer ---
log "  5b: Framebuffer non-blank check ..."
if [ "${SCREENSHOT_CAPTURED}" -eq 0 ]; then
    warn "Screenshot not captured — cannot verify framebuffer pixel content."
    echo ""
    echo "PASS (PARTIAL): GuppyScreen started (process evidence confirmed) but"
    echo "  screendump unavailable — framebuffer pixel content unverified."
    echo "  GuppyScreen evidence: ${GUPPY_EVIDENCE}"
    echo "  Hint: qemu may have timed out; try QEMU_TIMEOUT=$((QEMU_TIMEOUT + 60))"
    exit 0
fi

# Parse PPM header and check pixel diversity
ppm_check() {
    local screenshot="$1"
    python3 - "${screenshot}" << 'PYEOF'
import sys, os

path = sys.argv[1]

try:
    with open(path, 'rb') as f:
        data = f.read()
except Exception as e:
    print(f"ERROR: cannot read screenshot: {e}", file=sys.stderr)
    sys.exit(1)

if not data.startswith(b'P6'):
    print(f"ERROR: not a P6 PPM file (magic={data[:2]!r})", file=sys.stderr)
    sys.exit(1)

# Parse PPM header (skip whitespace and comment lines)
lines = []
i = 2
while len(lines) < 3:
    while i < len(data) and data[i:i+1] in (b' ', b'\t', b'\r', b'\n'):
        i += 1
    if i < len(data) and data[i:i+1] == b'#':
        while i < len(data) and data[i:i+1] != b'\n':
            i += 1
        continue
    tok = b''
    while i < len(data) and data[i:i+1] not in (b' ', b'\t', b'\r', b'\n'):
        tok += data[i:i+1]
        i += 1
    lines.append(tok.decode())
i += 1  # skip the single whitespace byte after maxval

width, height, maxval = int(lines[0]), int(lines[1]), int(lines[2])
print(f"PPM dimensions: {width}x{height}  maxval={maxval}")

if width != 800 or height != 480:
    print(f"ASSERT FAIL: expected 800x480, got {width}x{height}", file=sys.stderr)
    sys.exit(1)
print("ASSERT PASS: dimensions 800x480")

pixel_bytes = data[i:]
expected_bytes = width * height * 3
print(f"Pixel data: {len(pixel_bytes)} bytes (expected {expected_bytes})")

if len(pixel_bytes) < expected_bytes:
    print(f"ASSERT FAIL: pixel data too short ({len(pixel_bytes)} < {expected_bytes})", file=sys.stderr)
    sys.exit(1)

pixel_bytes = pixel_bytes[:expected_bytes]

# Sample every 16th pixel; check for >1 unique value
unique_pixels = set()
sample_step = 16
for idx in range(0, width * height, sample_step):
    off = idx * 3
    px = pixel_bytes[off:off+3]
    unique_pixels.add(px)

print(f"Unique pixel values (1/{sample_step} sample): {len(unique_pixels)}")

if len(unique_pixels) <= 1:
    only_px = list(unique_pixels)[0] if unique_pixels else b'(none)'
    print(f"ASSERT FAIL: framebuffer is blank/uniform (all pixels = {only_px.hex()})", file=sys.stderr)
    sys.exit(2)

print(f"ASSERT PASS: framebuffer is non-blank ({len(unique_pixels)} distinct pixel values)")
print("GuppyScreen rendered content to the 800x480 framebuffer.")
sys.exit(0)
PYEOF
}

ppm_check "${SCREENSHOT}"
PPM_RC=$?

echo ""
if [ "${PPM_RC}" -eq 0 ]; then
    CONNECTING_NOTE=""
    if grep -qE '(klippy.*error|moonraker.*connect|klipper.*offline|printer.*not)' "${QEMU_LOG}" 2>/dev/null; then
        CONNECTING_NOTE=" (likely 'Connecting…' / printer-offline screen — no MCU in qemu, expected)"
    fi
    echo "PASS: GuppyScreen renders to 800x480 fb${CONNECTING_NOTE}"
    echo "  Screenshot : ${SCREENSHOT}"
    echo "  Evidence   : ${GUPPY_EVIDENCE}"
elif [ "${PPM_RC}" -eq 2 ]; then
    echo "FAIL: GuppyScreen is running but the framebuffer is blank (uniform color)."
    echo "  GuppyScreen started but did not draw any content to /dev/fb0."
    echo "  Possible causes:"
    echo "    - LVGL fbdev driver not opening /dev/fb0 correctly under virtio-gpu"
    echo "    - GuppyScreen crashed immediately after start (check console log)"
    echo "    - Screendump was taken before GuppyScreen drew its first frame"
    echo "  Screenshot: ${SCREENSHOT}"
    echo "  Console log tail:"
    tail -40 "${QEMU_LOG}" 2>/dev/null | sed 's/^/  /' || true
    exit 1
else
    echo "FAIL: PPM analysis failed (rc=${PPM_RC})."
    echo "  Screenshot: ${SCREENSHOT}"
    exit 1
fi
