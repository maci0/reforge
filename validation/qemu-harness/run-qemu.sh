#!/usr/bin/env bash
# =============================================================================
# ReForge P3 Task 5: run-qemu.sh
# Parameterized qemu-system-arm wrapper using Task 4's proven virt machine args.
#
# Usage:
#   run-qemu.sh <root-image-or-initramfs.cpio.gz> [OPTIONS] [-- EXTRA_QEMU_ARGS...]
#
# Positional:
#   <root>    Path to an ext4 raw image  → boots as virtio-blk /dev/vda
#             Path to a *.cpio* or *.gz (cpio.gz)  → passed as -initrd
#
# Options:
#   --usb <file>        Attach a second virtio-blk drive (/dev/vdb) carrying
#                       the given file (e.g. update .tgz; simulates a USB stick).
#                       Task 6 uses this to drive the update-process test.
#
#   --vnc               Enable VNC display (port 5900) instead of -nographic.
#                       Adds a QEMU monitor unix socket at
#                       build/qemu-monitor-<PID>.sock so screendump can be used:
#                         echo 'screendump /tmp/fb.ppm' | socat - UNIX-CONNECT:<sock>
#
#   --timeout <secs>    Kill qemu after N seconds (default: 120).
#                       0 = no timeout (run until qemu exits on its own).
#
#   --append <extra>    Append extra kernel cmdline tokens (quoted as one arg).
#
#   --log <file>        Tee qemu output to <file> in addition to stdout/stderr.
#
#   --dry-run           Print the final qemu command line without running it.
#
#   --                  Anything after -- is passed verbatim to qemu-system-arm.
#
# Fixed / proven qemu configuration (from Task 4 smoke test):
#   -M virt,highmem=off        REQUIRED: keeps PCI ECAM < 4 GiB; without it the
#                               pci-host-generic driver returns -EBUSY and the whole
#                               PCI bus (including virtio-gpu) fails to probe.
#   -cpu cortex-a7             Matches AD5M Pro SoC ABI (armv7 hard-float).
#   -m 256                     256 MiB RAM (stock rootfs requirement).
#   -device virtio-gpu-pci,xres=800,yres=480
#                               Registers /dev/fb0 via DRM fbdev emulation at
#                               800×480×32 (virtio_gpudrmfb).
#   -device virtio-net-pci     Network (DHCP via user-mode slirp).
#   -device virtio-input-host  virtio HID input (required by Task 7/8 UI tests).
#
# Kernel: validation/qemu-harness/build/zImage  (built by Task 4 build-test-kernel.sh)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/validation/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"

log()  { echo "[run-qemu] $*"; }
die()  { echo "[run-qemu] ERROR: $*" >&2; exit 1; }
warn() { echo "[run-qemu] WARN:  $*" >&2; }

usage() {
    sed -n '/^# Usage:/,/^# =====/p' "$0" | sed 's/^# \{0,3\}//' | head -60
    exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
ROOT_ARG=""
USB_ARG=""
VNC=0
TIMEOUT=120
EXTRA_APPEND=""
LOG_FILE=""
DRY_RUN=0
EXTRA_QEMU=()

if [[ $# -eq 0 ]]; then
    usage
fi

# First positional = root image/initramfs (resolve to absolute path)
ROOT_ARG="$(realpath "$1")"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --usb)
            [[ $# -ge 2 ]] || die "--usb requires a filename"
            USB_ARG="$(realpath "$2")"
            shift 2
            ;;
        --vnc)
            VNC=1
            shift
            ;;
        --timeout)
            [[ $# -ge 2 ]] || die "--timeout requires a value"
            TIMEOUT="$2"
            shift 2
            ;;
        --append)
            [[ $# -ge 2 ]] || die "--append requires a quoted string"
            EXTRA_APPEND="$2"
            shift 2
            ;;
        --log)
            [[ $# -ge 2 ]] || die "--log requires a filename"
            LOG_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --)
            shift
            EXTRA_QEMU+=("$@")
            break
            ;;
        -*)
            die "Unknown option: $1  (use -- to pass raw qemu args)"
            ;;
        *)
            die "Unexpected positional argument: $1  (root image must be the first arg)"
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
[[ -f "${ROOT_ARG}" ]] || die "Root image/initramfs not found: ${ROOT_ARG}"
[[ -f "${ZIMAGE}" ]]   || die "zImage not found: ${ZIMAGE}  (run: make qemu-kernel)"
command -v qemu-system-arm >/dev/null 2>&1 || die "qemu-system-arm not in PATH"

if [[ -n "${USB_ARG}" ]]; then
    [[ -f "${USB_ARG}" ]] || die "--usb file not found: ${USB_ARG}"
fi

# ---------------------------------------------------------------------------
# Classify root argument: cpio initramfs vs ext4 block image
# ---------------------------------------------------------------------------
ROOT_TYPE=""
case "${ROOT_ARG}" in
    *.cpio|*.cpio.gz|*.cpio.xz|*initramfs*|*initrd*)
        ROOT_TYPE="initramfs"
        ;;
    *.ext4|*.img|*.raw)
        ROOT_TYPE="blk"
        ;;
    *)
        # Probe by magic: gz cpio starts with 1f8b, raw cpio with 070701
        if file "${ROOT_ARG}" 2>/dev/null | grep -qi 'cpio\|gzip'; then
            ROOT_TYPE="initramfs"
        else
            ROOT_TYPE="blk"
        fi
        ;;
esac
log "Root: ${ROOT_ARG}  (type: ${ROOT_TYPE})"

# ---------------------------------------------------------------------------
# Build kernel command line
# ---------------------------------------------------------------------------
CMDLINE="console=ttyAMA0,115200 earlyprintk loglevel=8"
if [[ "${ROOT_TYPE}" == "blk" ]]; then
    CMDLINE+=" root=/dev/vda rw"
    # vda = first virtio-blk; if USB drive also attached it becomes vdb
    CMDLINE+=" rootwait"
else
    # initramfs: kernel auto-unpacks; rdinit=/init
    CMDLINE+=" rdinit=/init"
fi
[[ -n "${EXTRA_APPEND}" ]] && CMDLINE+=" ${EXTRA_APPEND}"

# ---------------------------------------------------------------------------
# Build qemu argument array
# ---------------------------------------------------------------------------

# Monitor socket path (used for screendump in VNC mode)
MONITOR_SOCK="${BUILD_DIR}/qemu-monitor-$$.sock"

QEMU_ARGS=(
    qemu-system-arm
    -M   virt,highmem=off
    -cpu cortex-a7
    -m   256
    -kernel "${ZIMAGE}"
    -append "${CMDLINE}"
    # --- display ---
)

if [[ "${VNC}" -eq 1 ]]; then
    QEMU_ARGS+=(
        -display vnc=:0
        -monitor "unix:${MONITOR_SOCK},server,nowait"
    )
    log "VNC mode: display on :5900  |  monitor socket: ${MONITOR_SOCK}"
    log "  Screendump: echo 'screendump /tmp/fb.ppm' | socat - UNIX-CONNECT:${MONITOR_SOCK}"
else
    QEMU_ARGS+=( -nographic )
fi

# --- virtio GPU (800×480×32 fb) ---
QEMU_ARGS+=(
    -device virtio-gpu-pci,xres=800,yres=480
)

# --- root drive or initramfs ---
if [[ "${ROOT_TYPE}" == "blk" ]]; then
    QEMU_ARGS+=(
        -drive "file=${ROOT_ARG},if=virtio,format=raw,cache=unsafe"
    )
else
    QEMU_ARGS+=(
        -initrd "${ROOT_ARG}"
    )
fi

# --- USB/update drive (second virtio-blk = /dev/vdb) ---
if [[ -n "${USB_ARG}" ]]; then
    log "USB drive: ${USB_ARG} → /dev/vdb"
    QEMU_ARGS+=(
        -drive "file=${USB_ARG},if=virtio,format=raw,cache=unsafe,read-only=on"
    )
fi

# --- network (user-mode slirp, DHCP) ---
QEMU_ARGS+=(
    -netdev "user,id=net0"
    -device "virtio-net-pci,netdev=net0"
)

# --- virtio input (HID for UI tests Task 7/8) ---
# virtio-input-host requires a real device; use virtio-keyboard-pci instead
# which works in all environments including CI headless.
QEMU_ARGS+=(
    -device virtio-keyboard-pci
    -device virtio-mouse-pci
)

# --- any caller-supplied extra args ---
if [[ ${#EXTRA_QEMU[@]} -gt 0 ]]; then
    QEMU_ARGS+=( "${EXTRA_QEMU[@]}" )
fi

# ---------------------------------------------------------------------------
# Dry-run: just print the command
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "Dry-run mode — would execute:"
    printf '  %s\n' "${QEMU_ARGS[@]}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Launch qemu (with optional timeout + log tee)
# ---------------------------------------------------------------------------
log "Launching qemu (timeout=${TIMEOUT}s) ..."
log "  kernel : ${ZIMAGE}"
log "  root   : ${ROOT_ARG}  [${ROOT_TYPE}]"
[[ -n "${USB_ARG}" ]] && log "  usb    : ${USB_ARG}"
log "  cmdline: ${CMDLINE}"
echo ""

# Cleanup on exit
cleanup_qemu() {
    rm -f "${MONITOR_SOCK}" 2>/dev/null || true
}
trap cleanup_qemu EXIT INT TERM

# Build the final command: optionally prefix with 'timeout N'
FINAL_CMD=()
if [[ "${TIMEOUT}" -gt 0 ]]; then
    FINAL_CMD+=( timeout "${TIMEOUT}" )
fi
FINAL_CMD+=( "${QEMU_ARGS[@]}" )

RC=0
if [[ -n "${LOG_FILE}" ]]; then
    "${FINAL_CMD[@]}" 2>&1 | tee "${LOG_FILE}" || RC=${PIPESTATUS[0]}
else
    "${FINAL_CMD[@]}" 2>&1 || RC=$?
fi

if [[ "${RC}" -eq 124 ]]; then
    log "qemu timed out after ${TIMEOUT}s — treating as normal exit"
    exit 0
fi
exit "${RC}"
