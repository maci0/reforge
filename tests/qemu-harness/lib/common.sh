#!/bin/bash
# common.sh — shared vars + helpers for the qemu harnesses. SOURCE this first.
#
#   TAG=mytest; . "$(dirname "$0")/lib/common.sh"
#
# Provides: REPO_ROOT, QH_DIR (tests/qemu-harness), BUILD_DIR, LIBDIR, and the
# log/die/skip helpers every harness hand-rolled. Sets vars only if unset, so a
# harness can override before sourcing.

# Resolve paths from this file's location (works no matter the caller's cwd).
LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QH_DIR="$(cd "${LIBDIR}/.." && pwd)"
: "${REPO_ROOT:=$(cd "${QH_DIR}/../.." && pwd)}"
: "${BUILD_DIR:=${QH_DIR}/build}"
mkdir -p "${BUILD_DIR}"

: "${TAG:=qemu}"
log()  { echo "[${TAG}] $*"; }
die()  { echo "[${TAG}] ERROR: $*" >&2; exit 1; }
skip() { echo "[${TAG}] SKIP: $*"; exit 0; }

# need_cmd <cmd...> — die if any tool is missing.
need_cmd() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"; done; }

# mkext4 <out> <size> <label> [dir] — make an ext4 the stock/BSP 5.4 guest kernel
# can actually mount. e2fsprogs >= 1.47 defaults the `orphan_file` feature, which
# 5.4 rejects ("unsupported feature(s): FEATURE_C12") → the partition won't mount.
# Disable it (and metadata_csum_seed) so /data, the rootfs, and the USB all mount.
mkext4() {
    local out="$1" size="$2" label="$3" dir="${4:-}"
    rm -f "${out}"
    if [ -n "${dir}" ]; then
        mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L "${label}" -d "${dir}" "${out}" "${size}"
    else
        mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L "${label}" "${out}" "${size}"
    fi
}
