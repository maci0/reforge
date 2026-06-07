#!/bin/sh
# ReForge UNINSTALLER — runs on the printer's stock OS after the USB
# updater unpacks the reforge-uninstall-<ver>.tgz.
#
# POSIX sh / BusyBox compatible.
#
# What it does:
#   1. Sanity checks (arch + machine/PID, same logic as installer)
#   2. Removes the /etc/init.d/S01reforge boot-hook symlink
#   3. Removes $DATA/.reforge (the overlay rootfs)
#   → printer boots pure stock after reboot
#
# REFORGE_DATA_ROOT env override (default /data) for Task 3 tests.
set -e

DATA="${REFORGE_DATA_ROOT:-/data}"
REFORGE_DIR="${DATA}/.mod/.reforge"
INITD_LINK="/etc/init.d/S01reforge"

MACHINE_A="Adventurer5MPro"
MACHINE_B="Adventurer5M"
PID_A="0024"
PID_B="0023"

WORK_DIR="$(dirname "$0")"
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
    echo "[reforge-uninstall] $*"
}

# ---------------------------------------------------------------------------
# Sanity checks (same as installer)
# ---------------------------------------------------------------------------
info "ReForge uninstaller starting"

ARCH="$(uname -m)"
if [ "${ARCH}" != "armv7l" ]; then
    die "Architecture mismatch: expected armv7l, got ${ARCH}"
fi
info "Architecture: ${ARCH} OK"

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
    info "Machine/PID args absent — skipping machine-type check"
fi

# ---------------------------------------------------------------------------
# Remove boot hook symlink
# ---------------------------------------------------------------------------
info "Removing boot hook symlink ${INITD_LINK} ..."
if [ -L "${INITD_LINK}" ] || [ -f "${INITD_LINK}" ]; then
    rm -f "${INITD_LINK}"
    info "  Removed ${INITD_LINK}"
else
    info "  ${INITD_LINK} not found — already removed or never installed"
fi

# ---------------------------------------------------------------------------
# Lazy-unmount any chroot mounts still active under $REFORGE_DIR
# (mirrors forge-x uninstall.sh:93 pattern)
# ---------------------------------------------------------------------------
if mount | grep -q "${REFORGE_DIR}"; then
    info "Unmounting active mounts under ${REFORGE_DIR} ..."
    mount | grep "${REFORGE_DIR}" | awk '{print $3}' | \
        while IFS= read -r mp; do
            umount -lf "${mp}" 2>/dev/null || true
        done
fi

# ---------------------------------------------------------------------------
# Remove the overlay directory
# ---------------------------------------------------------------------------
if [ -d "${REFORGE_DIR}" ]; then
    info "Removing ${REFORGE_DIR} ..."
    rm -rf "${REFORGE_DIR}"
    info "  Removed ${REFORGE_DIR}"
else
    info "  ${REFORGE_DIR} not found — already removed"
fi

sync

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
info "------------------------------------------------------------"
info "ReForge uninstalled. Printer will boot stock firmware on next reboot."
info "------------------------------------------------------------"

exit 0
