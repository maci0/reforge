#!/usr/bin/env bash
# =============================================================================
# build-klipper-mcu.sh — cross-build Klipper's Linux-process MCU (klipper_mcu)
# for the armv7 qemu guest, so the harness can run a REAL klippy (reaching
# "ready") with no physical N32G455 MCU.
#
# Klipper's CONFIG_MACH_LINUX target compiles the MCU firmware as an ordinary
# Linux executable (src/linux/*). Run in the guest it creates the unix socket
# /tmp/klipper_host_mcu; klippy connects to it via `[mcu] serial:
# /tmp/klipper_host_mcu` and reaches "ready" — a faithful host+MCU stack with
# zero hardware. This replaces the fake-klippy API stand-in (whose status-push
# format is incompatible with this Moonraker and floods the event loop).
#
# Cross-compiles with the buildroot ARM toolchain already in the tree
# (build/output/host/bin/arm-buildroot-linux-gnueabihf-gcc), against the same
# pinned Klipper source the image ships. Output is cached at
# tests/qemu-harness/build/klipper_mcu (rebuilt only when missing or FORCE=1).
#
# Usage:   tests/qemu-harness/build-klipper-mcu.sh        # prints the artifact path
#          FORCE=1 tests/qemu-harness/build-klipper-mcu.sh
# Exit 0 + path on success; exit 1 (no path) if prerequisites are missing.
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
OUT="${BUILD_DIR}/klipper_mcu"
CROSS="${REPO_ROOT}/build/output/host/bin/arm-buildroot-linux-gnueabihf-"

err() { echo "[build-klipper-mcu] $*" >&2; }

# Cached + not forced -> done.
if [ "${FORCE:-0}" != 1 ] && [ -x "${OUT}" ]; then
    echo "${OUT}"
    exit 0
fi

# Locate the pinned Klipper source the image was built from.
KSRC="$(ls -d "${REPO_ROOT}"/build/output/build/klipper-* 2>/dev/null | head -1)"
[ -n "${KSRC}" ] && [ -d "${KSRC}/src/linux" ] || { err "klipper source not found (run 'make' first)"; exit 1; }
[ -x "${CROSS}gcc" ] || { err "ARM toolchain not found: ${CROSS}gcc"; exit 1; }

mkdir -p "${BUILD_DIR}"
WORK="$(mktemp -d /tmp/klipper-mcu-build-XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
cp -a "${KSRC}/." "${WORK}/"

cd "${WORK}" || exit 1
# Patch the Linux MCU to take its socket path as a positional arg (upstream
# hardcodes /tmp/klipper_host_mcu). Lets us run TWO instances on two sockets to
# mirror the printer's dual-MCU topology (main board + toolhead "eboard").
MAINC="src/linux/main.c"
if grep -q 'console_setup("/tmp/klipper_host_mcu")' "${MAINC}"; then
    sed -i 's#int ret = console_setup("/tmp/klipper_host_mcu");#char *mcu_dev = (optind < argc) ? argv[optind] : "/tmp/klipper_host_mcu";\n    int ret = console_setup(mcu_dev);#' "${MAINC}"
    grep -q 'console_setup(mcu_dev)' "${MAINC}" || { err "main.c socket-path patch failed"; exit 1; }
fi
# Minimal config: Linux-process machine; olddefconfig fills the rest.
echo "CONFIG_MACH_LINUX=y" > .config
make olddefconfig CROSS_PREFIX="${CROSS}" >/dev/null 2>&1 || { err "olddefconfig failed"; exit 1; }
grep -q "CONFIG_MACH_LINUX=y" .config || { err "MACH_LINUX not selected"; exit 1; }
if ! make CROSS_PREFIX="${CROSS}" -j"$(nproc 2>/dev/null || echo 2)" >/dev/null 2>&1; then
    err "klipper_mcu build failed"; exit 1
fi
[ -f out/klipper.elf ] || { err "out/klipper.elf not produced"; exit 1; }

cp out/klipper.elf "${OUT}"
chmod +x "${OUT}"
err "built $(file -b "${OUT}" 2>/dev/null | cut -d, -f1-2)"
echo "${OUT}"
exit 0
