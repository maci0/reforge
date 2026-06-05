#!/usr/bin/env bash
# =============================================================================
# ReForge P3 Task 6: update-process-test.sh
#
# Proves the ReForge UPDATE PROCESS end-to-end:
#   1. Build an ext4 root image (guppy rootfs + ReForge installed via installer)
#   2. Boot it under the Task 4 test kernel via run-qemu.sh
#   3. Assert ReForge came up (LIVE: Moonraker :7125 API / FLOOR: console log)
#
# Root approach chosen: Option (a) — guppy rootfs as outer ext4 root
# ---------------------------------------------------------------------------
# Why option (a)?
#   The guppy rootfs (build/output/images/rootfs.tar) already contains:
#     - BusyBox + inittab + rcS (a complete boot environment)
#     - python3, busybox httpd, all ReForge services
#   Using it as the outer root means the qemu VM boots into a real Linux
#   userland immediately.  The installer then lays a second copy of the
#   ReForge stack under /data/.mod/.reforge and symlinks S01reforge into
#   /etc/init.d.  On boot:
#       inittab → rcS → S01reforge → reforge-boot → chroot /data/.mod/.reforge
#   This exercises the real overlay+chroot boot path (the same one the
#   printer uses after a USB update).
#
#   The outer root's own service scripts (S60klipper, S65moonraker, etc.)
#   are stubbed out so they don't conflict with the chroot launch; the
#   services run exclusively inside the /data/.mod/.reforge chroot.
#
# Patches applied after install (all documented inline):
#   P1. Create /opt/config in the outer root — reforge-boot bind-mounts
#       it into the chroot; without it the mount fails.
#   P2. Fix the S01reforge symlink to use the in-VM path (/data/.mod/.reforge/...)
#       not the host mount path (/tmp/reforge-update-mnt-XXX/data/.mod/.reforge/...).
#       The installer creates the symlink with the host absolute path; we
#       rewrite it to the VM-relative path so it resolves correctly at boot.
#   P3. Patch the installed /data/.mod/.reforge/.shell/reforge-boot to skip the
#       mmcblk0p7 /data-mount check.  In qemu /data is a directory on the
#       ext4 root (already mounted as /); there is no separate mmcblk0p7.
#   P4. Stub out the outer root's own S6x/S7x service scripts so they don't
#       conflict with the chroot.  S01reforge → reforge-boot launches the
#       services inside the chroot; the outer scripts must not also start them.
#
# Network port-forward for LIVE check:
#   -netdev user,id=n1,hostfwd=tcp::17125-:7125
#   Moonraker inside the chroot binds 0.0.0.0:7125 (same network namespace
#   as the VM — chroot does not isolate the network stack).
#   The host curls http://127.0.0.1:17125/server/info.
#
# Usage: sudo tests/qemu-harness/update-process-test.sh
#        make qemu-update
#
# Env overrides:
#   REFORGE_TGZ=<path>      — override auto-detected .tgz
#   QEMU_TIMEOUT=480        — seconds before killing qemu (default: 480)
#   MOONRAKER_PORT=17125    — host port to forward VM :7125 to (default: 17125)
#   UPDATE_ROOT_IMG=<path>  — reuse an existing ext4 image (skip rebuild)
#   KEEP_IMAGE=1            — do not delete the ext4 image on exit
#
# Exit codes: 0 = PASS, 1 = FAIL
# Needs: sudo (loop mount), qemu-system-arm, curl
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
DIST_DIR="${REPO_ROOT}/packaging/dist"

QEMU_TIMEOUT="${QEMU_TIMEOUT:-480}"
MOONRAKER_PORT="${MOONRAKER_PORT:-17125}"
KEEP_IMAGE="${KEEP_IMAGE:-0}"

log()  { echo "[update-test] $*"; }
die()  { echo "[update-test] FAIL: $*" >&2; exit 1; }
warn() { echo "[update-test] WARN: $*" >&2; }

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
ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar"
[ -f "${ROOTFS_TAR}" ] || die "Guppy rootfs not found: ${ROOTFS_TAR} — run 'make rootfs' first"

ZIMAGE="${BUILD_DIR}/zImage"
[ -f "${ZIMAGE}" ] || die "zImage not found: ${ZIMAGE} — run 'make qemu-kernel' first"

RUN_QEMU="${HARNESS_DIR}/run-qemu.sh"
[ -x "${RUN_QEMU}" ] || die "run-qemu.sh not found / not executable: ${RUN_QEMU}"

command -v qemu-system-arm >/dev/null 2>&1 || die "qemu-system-arm not in PATH"
command -v curl            >/dev/null 2>&1 || warn "curl not found — LIVE check unavailable"

# ---------------------------------------------------------------------------
# Temp state + cleanup
# ---------------------------------------------------------------------------
EXT4_IMG=""
LOOP_DEV=""
MNT_DIR=""
UNPACK_DIR=""
QEMU_PID=""
QEMU_LOG=""

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

    # Remove scratch dirs/files
    [ -n "${MNT_DIR}"    ] && rm -rf "${MNT_DIR}"    2>/dev/null || true
    [ -n "${UNPACK_DIR}" ] && rm -rf "${UNPACK_DIR}" 2>/dev/null || true

    # Keep or remove ext4 image
    if [ "${KEEP_IMAGE}" = "1" ] && [ -n "${EXT4_IMG}" ] && [ -f "${EXT4_IMG}" ]; then
        log "  preserving image (KEEP_IMAGE=1): ${EXT4_IMG}"
    elif [ -z "${UPDATE_ROOT_IMG:-}" ]; then
        [ -n "${EXT4_IMG}" ] && rm -f "${EXT4_IMG}" 2>/dev/null || true
    else
        log "  preserving image (UPDATE_ROOT_IMG): ${EXT4_IMG}"
    fi

    # Remove qemu log (it was already printed / tailed)
    [ -n "${QEMU_LOG}" ] && rm -f "${QEMU_LOG}" 2>/dev/null || true

    return $rc
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# STEP 1: Build (or reuse) the ext4 root image
# ---------------------------------------------------------------------------
mkdir -p "${BUILD_DIR}"

if [ -n "${UPDATE_ROOT_IMG:-}" ] && [ -f "${UPDATE_ROOT_IMG}" ]; then
    log "Reusing existing image: ${UPDATE_ROOT_IMG}"
    EXT4_IMG="${UPDATE_ROOT_IMG}"
else
    EXT4_IMG="${BUILD_DIR}/reforge-update-root-$$.ext4"

    log "=== STEP 1: Building ext4 root image ==="
    log "  rootfs.tar : ${ROOTFS_TAR} ($(du -sh "${ROOTFS_TAR}" | cut -f1))"

    # Create a 1.8 GB ext4 image (guppy rootfs ~500 MB unpacked + /data/.mod/.reforge ~500 MB)
    log "  creating 1.8 GB ext4 image ..."
    dd if=/dev/zero of="${EXT4_IMG}" bs=1M count=1843 status=progress 2>&1 | tail -1
    mkfs.ext4 -F -q -L "reforge-root" "${EXT4_IMG}"

    MNT_DIR="$(mktemp -d /tmp/reforge-update-mnt-XXXXXX)"
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
    UNPACK_DIR="$(mktemp -d /tmp/reforge-update-unpack-XXXXXX)"
    tar -xf "${TGZ}" -C "${UNPACK_DIR}"
    log "  tgz contents: $(ls "${UNPACK_DIR}")"

    INSTALLER="${UNPACK_DIR}/flashforge_init.sh"
    [ -f "${INSTALLER}" ] || die "flashforge_init.sh not found in tgz"

    # --- 1d. Run the installer (REFORGE_DATA_ROOT=<mnt>/data) ---
    # REFORGE_INITD_DIR points to the outer root's /etc/init.d so
    # the S01reforge symlink lands where inittab/rcS will find it.
    log "  running installer (REFORGE_DATA_ROOT=${MNT_DIR}/data) ..."
    REFORGE_DATA_ROOT="${MNT_DIR}/data" \
        REFORGE_SKIP_ARCH_CHECK=1 \
        REFORGE_INITD_DIR="${MNT_DIR}/etc/init.d" \
        sh "${INSTALLER}" 2>&1 | sed 's/^/    /'

    REFORGE_DIR="${MNT_DIR}/data/.mod/.reforge"
    [ -d "${REFORGE_DIR}" ] || die "Installer did not create ${REFORGE_DIR}"
    log "  installer complete.  .installed: $(cat "${REFORGE_DIR}/.installed" 2>/dev/null || echo MISSING)"

    # Show what symlink the installer created
    HOOK_LINK="${MNT_DIR}/etc/init.d/S01reforge"
    [ -L "${HOOK_LINK}" ] || die "S01reforge symlink missing in outer /etc/init.d"
    log "  (host-path) S01reforge → $(readlink "${HOOK_LINK}")"

    # --- 1e. Apply patches ---

    # PATCH P1: Ensure /opt/config exists (already done above, belt+suspenders)
    mkdir -p "${MNT_DIR}/opt/config"

    # PATCH P2: Fix the S01reforge symlink to use the IN-VM path.
    # The installer creates:  S01reforge -> /tmp/reforge-update-mnt-XXX/data/.mod/.reforge/.shell/reforge-boot
    # But inside the VM the mount prefix doesn't exist; the path must be:
    #   S01reforge -> /data/.mod/.reforge/.shell/reforge-boot
    log "  applying P2: fixing S01reforge symlink to in-VM path ..."
    VM_HOOK_TARGET="/data/.mod/.reforge/.shell/reforge-boot"
    rm -f "${HOOK_LINK}"
    ln -s "${VM_HOOK_TARGET}" "${HOOK_LINK}"
    log "  (vm-path)  S01reforge → ${VM_HOOK_TARGET}"

    # PATCH P3: In the INSTALLED reforge-boot, skip the mmcblk0p7 /data mount check.
    # In the qemu VM, /data is a directory on the ext4 root (already mounted as /);
    # there is no separate mmcblk0p7 partition.  The check would fail and abort boot.
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
    # Detect start of the mmcblk conditional block
    if ("if [ \"${DATA}\" = \"/data\" ] && ! mount | grep -q '/dev/mmcblk0p7'" in stripped):
        skip = True
        out.append("# (P3-qemu-patch: mmcblk0p7 data-mount check removed; /data is on ext4 root)\n")
        continue
    # Detect end of skipped block
    if skip and stripped.strip() == 'fi':
        skip = False
        continue
    if not skip:
        out.append(line)

with open(path, 'w') as f:
    f.writelines(out)
print("P3 patch applied: mmcblk0p7 block removed.")
PYEOF

    # Verify patch: should have no mmcblk0p7 that's executable (comments are OK)
    if grep -v '^#' "${INSTALLED_HOOK}" | grep -q 'mmcblk0p7'; then
        warn "P3 patch: mmcblk0p7 still in non-comment lines of reforge-boot"
        grep -n 'mmcblk0p7' "${INSTALLED_HOOK}" | sed 's/^/    /' || true
    else
        log "  P3 patch verified: mmcblk0p7 removed from executable code."
    fi

    # PATCH P4: Stub out the outer root's own S60klipper, S65moonraker, S70httpd,
    # S75guppyscreen so they don't conflict with the services launched inside the
    # chroot by reforge-boot.  These outer scripts would try to start klipper/
    # moonraker on the host filesystem paths which don't match the chroot layout.
    log "  applying P4: stubbing outer service scripts (S60klipper, S65moonraker, S70httpd, S75guppyscreen) ..."
    for svc in S60klipper S65moonraker S70httpd S75guppyscreen; do
        OUTER_SVC="${MNT_DIR}/etc/init.d/${svc}"
        if [ -f "${OUTER_SVC}" ]; then
            # Replace with a stub that does nothing
            cat > "${OUTER_SVC}" << 'EOF'
#!/bin/sh
# Stubbed by update-process-test.sh (P4):
# This service runs inside the /data/.mod/.reforge chroot (via S01reforge → reforge-boot).
# The outer-root copy is disabled to prevent double-start.
exit 0
EOF
            chmod 755 "${OUTER_SVC}"
            log "    stubbed: ${svc}"
        fi
    done

    # PATCH P5: Configure eth1 (second NIC, netdev=net1) with DHCP inside the
    # chroot rootfs so Moonraker is reachable via the port-forwarded interface.
    # The outer root's network/interfaces configures eth0; the chroot copy also
    # needs eth1 so that the hostfwd (net1 → host:17125) carries Moonraker traffic.
    CHROOT_IFACES="${REFORGE_DIR}/etc/network/interfaces"
    log "  applying P5: adding eth1 DHCP to chroot network/interfaces ..."
    if [ -f "${CHROOT_IFACES}" ]; then
        if ! grep -q 'eth1' "${CHROOT_IFACES}"; then
            printf '\nauto eth1\niface eth1 inet dhcp\n' >> "${CHROOT_IFACES}"
            log "    eth1 added to ${CHROOT_IFACES}"
        else
            log "    eth1 already present in ${CHROOT_IFACES}"
        fi
    else
        mkdir -p "$(dirname "${CHROOT_IFACES}")"
        cat > "${CHROOT_IFACES}" << 'EOF'
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
auto eth1
iface eth1 inet dhcp
EOF
        log "    created ${CHROOT_IFACES} with lo + eth0 + eth1"
    fi

    # --- 1f. Sync and unmount ---
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
# STEP 2: Boot under the test kernel via run-qemu.sh
# ---------------------------------------------------------------------------
log ""
log "=== STEP 2: Booting ext4 root under test kernel ==="

QEMU_LOG="${BUILD_DIR}/reforge-update-qemu-$$.log"

log "  log file     : ${QEMU_LOG}"
log "  timeout      : ${QEMU_TIMEOUT}s"
log "  port-forward : host:${MOONRAKER_PORT} → VM:7125"

# run-qemu.sh already adds -netdev user,id=net0 -device virtio-net-pci,netdev=net0
# Add a second netdev (net1) with the Moonraker port-forward.
# The VM gets two NICs:
#   net0 (10.0.2.0/24) → eth0 — default DHCP for general connectivity
#   net1 (10.0.3.0/24) → eth1 — host-forwarded, hostfwd ::${MOONRAKER_PORT} → :7125
# Using a DIFFERENT subnet for net1 avoids dual-NIC routing conflicts that
# would occur if both NICs got the same 10.0.2.15 IP from slirp.
# Moonraker binds 0.0.0.0:7125 so it's reachable via eth1 (10.0.3.15).
# eth1 is configured via the chroot's network/interfaces (P5 patch above).

log "  launching qemu (background) ..."
"${RUN_QEMU}" "${EXT4_IMG}" \
    --timeout "${QEMU_TIMEOUT}" \
    --log "${QEMU_LOG}" \
    -- \
    -netdev "user,id=net1,net=10.0.3.0/24,host=10.0.3.2,hostfwd=tcp::${MOONRAKER_PORT}-:7125" \
    -device "virtio-net-pci,netdev=net1" \
    &
QEMU_PID=$!
log "  qemu pid: ${QEMU_PID}"

# ---------------------------------------------------------------------------
# STEP 3: Assert ReForge came up
# ---------------------------------------------------------------------------
log ""
log "=== STEP 3: Waiting for ReForge to come up ==="

LEVEL="UNKNOWN"
PASS=0

# Helper: check if qemu still running
qemu_alive() { kill -0 "${QEMU_PID}" 2>/dev/null; }

# --- FLOOR check: watch console log for init chain evidence ---
# We look for reforge-boot launching the chroot AND services starting.
# The services print "Starting klipper..." etc. from inside the chroot via rcS.
floor_check() {
    local log="$1"
    # Minimum evidence: the chroot init chain launched + at least one service started
    if grep -q '\[reforge-boot\] launching ReForge via chroot' "${log}" 2>/dev/null && \
       grep -qE '(Starting klipper|Starting moonraker|Starting httpd)' "${log}" 2>/dev/null; then
        return 0
    fi
    return 1
}

# --- LIVE check: curl Moonraker API ---
live_check() {
    local port="$1"
    local response
    response="$(curl -sf --max-time 10 "http://127.0.0.1:${port}/server/info" 2>/dev/null || true)"
    if echo "${response}" | grep -q '"klippy_state"'; then
        echo "${response}"
        return 0
    fi
    return 1
}

# Poll loop: check every 10 seconds up to the timeout
BOOT_GRACE=60    # seconds to wait before first poll
POLL_INTERVAL=10
ELAPSED=0

log "  waiting ${BOOT_GRACE}s for initial boot ..."
while [ "${ELAPSED}" -lt "${BOOT_GRACE}" ] && qemu_alive; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if ! qemu_alive; then
    wait "${QEMU_PID}" 2>/dev/null || true
    QEMU_PID=""
    log "  qemu exited early — checking console log ..."
    if floor_check "${QEMU_LOG}"; then
        LEVEL="FLOOR"
        PASS=1
    fi
else
    MAX_WAIT="${QEMU_TIMEOUT}"
    log "  polling for Moonraker API and console evidence (up to ${MAX_WAIT}s total) ..."

    while qemu_alive && [ "${ELAPSED}" -lt "${MAX_WAIT}" ]; do
        # Try LIVE check
        if command -v curl >/dev/null 2>&1; then
            LIVE_RESP="$(live_check "${MOONRAKER_PORT}" 2>/dev/null || true)"
            if [ -n "${LIVE_RESP}" ]; then
                log "  LIVE: Moonraker responded!"
                LEVEL="LIVE"
                PASS=1
                break
            fi
        fi

        # Try FLOOR check
        if floor_check "${QEMU_LOG}"; then
            LEVEL="FLOOR"
            PASS=1
            # Keep polling to try upgrading to LIVE
            # Moonraker + python startup under emulation can take 60-120s after
            # the "Starting moonraker..." line appears in the log.
            if command -v curl >/dev/null 2>&1; then
                log "  FLOOR evidence found; polling for LIVE upgrade (120s more) ..."
                local_elapsed=0
                while [ "${local_elapsed}" -lt 120 ] && qemu_alive; do
                    sleep 10
                    local_elapsed=$((local_elapsed + 10))
                    LIVE_RESP="$(live_check "${MOONRAKER_PORT}" 2>/dev/null || true)"
                    if [ -n "${LIVE_RESP}" ]; then
                        log "  LIVE upgrade: Moonraker responded! ${LIVE_RESP}"
                        LEVEL="LIVE"
                        break
                    fi
                    log "  ... LIVE upgrade poll ${local_elapsed}/120s"
                done
            fi
            break
        fi

        sleep "${POLL_INTERVAL}"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        log "  ... ${ELAPSED}s elapsed"
    done

    # Final check after timeout
    if [ "${PASS}" -eq 0 ]; then
        log "  poll loop ended; final floor check ..."
        if floor_check "${QEMU_LOG}"; then
            LEVEL="FLOOR"
            PASS=1
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Emit console log tail for debugging (always)
# ---------------------------------------------------------------------------
log ""
log "=== Console log tail (last 80 lines) ==="
tail -80 "${QEMU_LOG}" 2>/dev/null | sed 's/^/  /' || true

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
log ""
log "=== RESULT ==="

log "Boot evidence in console log:"
grep -E '(\[reforge-boot\]|Starting klipper|Starting moonraker|Starting httpd|klippy_state|ReForge|Welcome to)' \
    "${QEMU_LOG}" 2>/dev/null | head -30 | sed 's/^/  /' || log "  (none found)"

if [ "${PASS}" -eq 1 ]; then
    echo ""
    echo "PASS: update process (install → ReForge boots in qemu) [${LEVEL}]"
    exit 0
else
    echo ""
    echo "FAIL: ReForge did not come up within ${QEMU_TIMEOUT}s"
    echo "  LEVEL attempted: LIVE + FLOOR"
    echo "  Check console log above for details."
    exit 1
fi
