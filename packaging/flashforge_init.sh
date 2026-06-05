#!/bin/sh
# ReForge installer — runs on the printer's stock OS after the USB updater
# unpacks the .tgz.  POSIX sh / BusyBox compatible.
#
# Boot-hook injection point (see "HOOK POINT" comment below):
#   The stock /etc/rcS iterates /etc/init.d/S??* and execs each one with
#   "start".  forge-x uses the identical mechanism: its installer symlinks
#   /opt/config/mod/.shell/S00init → /etc/init.d/S00init  (confirmed in
#   fw-analysis/fx-build/flashforge_init.sh:243 and the stock rcS).
#   ReForge mirrors this exactly: we install reforge-boot at
#   /data/.mod/.reforge/.shell/reforge-boot and symlink it as
#   /etc/init.d/S01reforge  (slot S01 — after any S00 stock scripts,
#   before the rest of the stock stack).  Rationale for S01 vs S00:
#   avoids colliding with an existing forge-x S00init if the user ever
#   runs both; also gives the /data partition mount (done by auto_run.sh
#   before rcS) time to settle.  Assumption to validate in qemu: confirm
#   /data is already mounted when S01 runs.
#
# NEVER writes outside /data (or $DATA if REFORGE_DATA_ROOT is set).
# Env overrides for loopback/CI tests on non-armv7 hosts:
#   REFORGE_DATA_ROOT=<dir>    — redirect /data to a temp dir (loopback mount)
#   REFORGE_SKIP_ARCH_CHECK=1  — skip armv7l uname check on x86 test hosts
#   REFORGE_INITD_DIR=<dir>    — redirect /etc/init.d symlink to a temp dir
#                                (prevents writes to host /etc/init.d)
set -e

# ---------------------------------------------------------------------------
# Env / paths
# ---------------------------------------------------------------------------
DATA="${REFORGE_DATA_ROOT:-/data}"
REFORGE_DIR="${DATA}/.mod/.reforge"
BOOT_HOOK_DEST="${REFORGE_DIR}/.shell/reforge-boot"
# REFORGE_INITD_DIR overrides the init.d path so loopback/CI tests can
# redirect the boot-hook symlink to a temp dir instead of the host /etc/init.d.
INITD_DIR="${REFORGE_INITD_DIR:-/etc/init.d}"
INITD_LINK="${INITD_DIR}/S01reforge"

MACHINE_A="Adventurer5MPro"
MACHINE_B="Adventurer5M"
PID_A="0024"
PID_B="0023"

WORK_DIR="$(dirname "$0")"
# Make WORK_DIR absolute in case we were invoked with a relative path
case "$WORK_DIR" in
    /*) ;;
    *)  WORK_DIR="$(cd "$WORK_DIR" && pwd)" ;;
esac

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "[reforge] $*"
}

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
info "ReForge installer starting"

# Architecture check — must be armv7l (the AD5M Pro SoC)
# Set REFORGE_SKIP_ARCH_CHECK=1 to bypass (loopback/CI tests on x86 hosts).
ARCH="$(uname -m)"
if [ -z "${REFORGE_SKIP_ARCH_CHECK:-}" ] && [ "${ARCH}" != "armv7l" ]; then
    die "Architecture mismatch: expected armv7l, got ${ARCH}"
fi
info "Architecture: ${ARCH} (check $( [ -n "${REFORGE_SKIP_ARCH_CHECK:-}" ] && echo 'SKIPPED' || echo 'OK' ))"

# ---------------------------------------------------------------------------
# Pre-flight: refuse to install over a competing mod.
#
# ReForge owns /etc/init.d/S01reforge + the /data/.mod/.reforge/ chroot.
# Another mod sitting at /etc/init.d/S00init (forge-x slot), /opt/config/mod/,
# /data/.mod/.forge-x/, or any of the well-known S?? symlinks they install
# will conflict at boot: races for the printer serial, the Moonraker HTTP
# port, the framebuffer; doubled RSS on the 128 MB box; shared state
# (/etc/hosts, /opt/klipper/klippy/extras/) in inconsistent shape.
#
# The user must run the other mod's uninstaller and reboot to clean stock
# BEFORE running this installer. Override with REFORGE_FORCE_OVER_OTHER_MOD=1
# only if you understand the consequences (unsupported).
#
# Drawn directly from forge-x's uninstall.sh + S00init footprint (see
# tools/recovery/make-clean-golden.sh for the full list).
# ---------------------------------------------------------------------------
pre_install_conflict_check() {
    [ -n "${REFORGE_FORCE_OVER_OTHER_MOD:-}" ] && {
        info "REFORGE_FORCE_OVER_OTHER_MOD=1 set — skipping competing-mod check (UNSUPPORTED)"
        return 0
    }

    _hits=""
    # forge-x boot hooks (symlinks to /opt/config/mod/.shell/*).
    for _s in S00init S55boot S60dropbear S98camera S98zssh S99root K99root \
              S99moon K99moon S50sshd S55date; do
        if [ -L "/etc/init.d/${_s}" ] || [ -f "/etc/init.d/${_s}" ]; then
            _hits="${_hits} /etc/init.d/${_s}"
        fi
    done
    # forge-x install roots.
    [ -d /opt/config/mod ]      && _hits="${_hits} /opt/config/mod/"
    [ -d /opt/config/mod_data ] && _hits="${_hits} /opt/config/mod_data/"
    [ -d /data/.mod/.forge-x ]  && _hits="${_hits} /data/.mod/.forge-x/"
    # Entware/opt directories forge-x installs.
    for _d in /opt/bin /opt/etc /opt/home /opt/lib /opt/libexec /opt/root \
              /opt/sbin /opt/share /opt/tmp /opt/usr /opt/var; do
        [ -d "${_d}" ] && _hits="${_hits} ${_d}"
    done
    # Dropbear binaries forge-x ships.
    for _b in /bin/dropbear /bin/dropbearmulti /bin/dropbearkey; do
        [ -e "${_b}" ] && _hits="${_hits} ${_b}"
    done

    if [ -n "${_hits}" ]; then
        echo "" >&2
        echo "ERROR: another mod is installed. Uninstall it FIRST, reboot to" >&2
        echo "       clean stock, then run this installer again." >&2
        echo "" >&2
        echo "  Detected files/paths from a competing mod:" >&2
        for _h in ${_hits}; do echo "    ${_h}" >&2; done
        echo "" >&2
        echo "  Most likely forge-x. To uninstall:" >&2
        echo "    /data/.mod/.forge-x/uninstall.sh   # or wherever the mod is installed" >&2
        echo "  Reboot, confirm firmwareExe starts and /etc/init.d/ has no" >&2
        echo "  third-party S?? symlinks, then re-run this installer." >&2
        echo "" >&2
        echo "  If you no longer have the original uninstaller, reflash a stock" >&2
        echo "  factory .tgz over USB (see tools/recovery/RUNBOOK.md Path A) to" >&2
        echo "  return to a known clean baseline." >&2
        echo "" >&2
        echo "  Override (UNSUPPORTED): REFORGE_FORCE_OVER_OTHER_MOD=1 $0 ..." >&2
        echo "" >&2
        die "refusing to install over a competing mod"
    fi
    info "no competing mod detected"
}
pre_install_conflict_check

# Machine / PID guard — mirrors the stock script logic:
#   - If $1 and $2 are both non-empty, validate them.
#   - If either is empty (old-style invocation or test env), skip the check.
# Called by auto_run.sh as:  flashforge_init.sh Adventurer5MPro 0024
ARG_MACHINE="$1"
ARG_PID="$2"
if [ -n "${ARG_MACHINE}" ] && [ -n "${ARG_PID}" ]; then
    if [ "${ARG_MACHINE}" != "${MACHINE_A}" ] && [ "${ARG_MACHINE}" != "${MACHINE_B}" ]; then
        die "Machine mismatch: expected ${MACHINE_A} or ${MACHINE_B}, got ${ARG_MACHINE}"
    fi
    if [ "${ARG_PID}" != "${PID_A}" ] && [ "${ARG_PID}" != "${PID_B}" ]; then
        die "PID mismatch: expected ${PID_A} or ${PID_B}, got ${ARG_PID}"
    fi
    info "Machine=${ARG_MACHINE} PID=${ARG_PID} OK"
else
    info "Machine/PID args absent — skipping machine-type check (old-style or test invoke)"
fi

# ---------------------------------------------------------------------------
# Locate software-*.tar.xz
# ---------------------------------------------------------------------------
SW_ARCHIVE="$(ls -1t "${WORK_DIR}"/software-*.tar.xz 2>/dev/null | head -n 1)"
if [ -z "${SW_ARCHIVE}" ]; then
    die "No software-*.tar.xz found in ${WORK_DIR}"
fi
info "Found archive: ${SW_ARCHIVE}"

# Derive version from filename: software-<ver>.tar.xz
_basename="$(basename "${SW_ARCHIVE}")"
REFORGE_VER="${_basename#software-}"
REFORGE_VER="${REFORGE_VER%.tar.xz}"
info "Version: ${REFORGE_VER}"

# ---------------------------------------------------------------------------
# Clean any prior install
# ---------------------------------------------------------------------------
info "Preparing ${REFORGE_DIR} ..."
if [ -d "${REFORGE_DIR}" ]; then
    info "  Removing prior install at ${REFORGE_DIR}"
    rm -rf "${REFORGE_DIR}"
fi
# NOTE: do NOT mkdir REFORGE_DIR here — mv renames TEMP_DIR → REFORGE_DIR
# atomically only when the destination does not yet exist.

# ---------------------------------------------------------------------------
# Extract to a temp dir first, verify md5sum, then rename into place
# ---------------------------------------------------------------------------
TEMP_DIR="${DATA}/.reforge_tmp_$$"
rm -rf "${TEMP_DIR}"
mkdir -p "${TEMP_DIR}"

info "Extracting ${SW_ARCHIVE} ..."
tar -xf "${SW_ARCHIVE}" -C "${TEMP_DIR}" || die "Extraction failed"
sync

info "Verifying md5sum.list ..."
if [ ! -f "${TEMP_DIR}/md5sum.list" ]; then
    rm -rf "${TEMP_DIR}"
    die "md5sum.list missing in archive"
fi
(
    cd "${TEMP_DIR}"
    md5sum -c md5sum.list
) || {
    rm -rf "${TEMP_DIR}"
    die "md5sum verification failed"
}
info "Checksum OK"

# Rename temp dir to final location (atomic when dest does not exist).
# Ensure parent exists (in case DATA was just created by mkfs/mount).
mkdir -p "${DATA}"
mv "${TEMP_DIR}" "${REFORGE_DIR}"
sync

# ---------------------------------------------------------------------------
# Seed the last-known-good (LKG) baseline for the trial/rollback safety net.
# The shipped rootfs carries the OTA-updatable /mod; a fresh install has no
# lkg yet, so copy mod -> lkg once.  (The trial/LKG logic itself lands in a
# later task; this just guarantees a baseline exists from first boot.)
# ---------------------------------------------------------------------------
if [ -d "${REFORGE_DIR}/mod" ] && [ ! -d "${REFORGE_DIR}/lkg" ]; then
    info "Seeding last-known-good baseline (mod -> lkg) ..."
    cp -a "${REFORGE_DIR}/mod" "${REFORGE_DIR}/lkg"
    sync
fi

# ---------------------------------------------------------------------------
# Install the boot hook (HOOK POINT — see top-of-file comment)
# ---------------------------------------------------------------------------
# reforge-boot is shipped inside the rootfs at /.shell/reforge-boot
# (packed as part of the software-*.tar.xz).  We expose it as
# /data/.mod/.reforge/.shell/reforge-boot and symlink it into /etc/init.d/.
# ---------------------------------------------------------------------------
info "Installing boot hook ..."

if [ ! -f "${BOOT_HOOK_DEST}" ]; then
    die "Boot hook not found at ${BOOT_HOOK_DEST} — archive may be incomplete"
fi
chmod 755 "${BOOT_HOOK_DEST}"

# Remove any stale symlink / file from a previous install
mkdir -p "${INITD_DIR}"
rm -f "${INITD_LINK}"
ln -s "${BOOT_HOOK_DEST}" "${INITD_LINK}"
info "  Symlinked ${INITD_LINK} -> ${BOOT_HOOK_DEST}"

# ---------------------------------------------------------------------------
# Persist default screen mode
# ---------------------------------------------------------------------------
# Modes: HEADLESS (no display daemon), GUPPY (GuppyScreen), STOCK (reserved)
mkdir -p "${REFORGE_DIR}/config"
printf 'SCREEN_MODE=HEADLESS\n' > "${REFORGE_DIR}/config/screen.conf"
info "Default screen mode: HEADLESS"

# ---------------------------------------------------------------------------
# Write install stamp
# ---------------------------------------------------------------------------
printf '%s\n' "${REFORGE_VER}" > "${REFORGE_DIR}/.installed"
sync

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
info "------------------------------------------------------------"
info "ReForge ${REFORGE_VER} installed successfully."
info "Reboot the printer to activate."
info "------------------------------------------------------------"

exit 0
