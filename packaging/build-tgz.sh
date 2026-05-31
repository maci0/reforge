#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build-tgz.sh — build a stock-format FlashForge OTA installer .tgz
#
# Produces:  packaging/dist/reforge-<ver>.tgz
#
# The outer tar contains:
#   software-<ver>.tar.xz  — ReForge rootfs tree + inner md5sum.list
#   library-<ver>.tar.xz   — stub (rootfs is self-contained)
#   control-<ver>.tar.xz   — stub (reserved for Plan 4 MCU work)
#   flashforge_init.sh     — installer script (stub; real logic in Task 2)
#   md5sum.list            — md5 of the three .tar.xz files (outer manifest)
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGING_DIR="${REPO_ROOT}/packaging"
DIST_DIR="${PACKAGING_DIR}/dist"
ROOTFS_TAR="${REPO_ROOT}/output-guppy/images/rootfs.tar"
VER="$(cat "${PACKAGING_DIR}/VERSION")"

# Staging dir — cleaned on exit
STAGING="$(mktemp -d /tmp/reforge-pkg-XXXXXX)"
trap 'rm -rf "${STAGING}"' EXIT

echo "[build-tgz] version: ${VER}"
echo "[build-tgz] staging: ${STAGING}"

# Verify rootfs exists
if [ ! -f "${ROOTFS_TAR}" ]; then
    echo ""
    echo "ERROR: rootfs not found at:"
    echo "  ${ROOTFS_TAR}"
    echo ""
    echo "Run 'make guppy' first to build the ReForge rootfs."
    exit 1
fi

mkdir -p "${DIST_DIR}"

# ---------------------------------------------------------------------------
# 1. software-<ver>.tar.xz — ReForge rootfs tree + inner md5sum.list
# ---------------------------------------------------------------------------
echo "[build-tgz] building software-${VER}.tar.xz ..."

SW_STAGE="${STAGING}/software"
mkdir -p "${SW_STAGE}"

# Extract rootfs contents into staging (strip leading ./ from paths)
echo "[build-tgz]   extracting rootfs.tar ..."
tar -xf "${ROOTFS_TAR}" -C "${SW_STAGE}"

# Generate inner md5sum.list (md5 of every regular file, relative paths)
echo "[build-tgz]   generating inner md5sum.list ..."
(
    cd "${SW_STAGE}"
    # find every regular file, excluding md5sum.list itself
    find . -type f ! -name 'md5sum.list' -print0 \
        | sort -z \
        | xargs -0 md5sum \
        > md5sum.list
)

# Pack + xz-compress
echo "[build-tgz]   compressing to software-${VER}.tar.xz ..."
(
    cd "${SW_STAGE}"
    tar -cf - . | xz -T0 > "${STAGING}/software-${VER}.tar.xz"
)

# ---------------------------------------------------------------------------
# 2. library-<ver>.tar.xz — stub
# ---------------------------------------------------------------------------
echo "[build-tgz] building library-${VER}.tar.xz (stub) ..."

LIB_STAGE="${STAGING}/library"
mkdir -p "${LIB_STAGE}"
cat > "${LIB_STAGE}/README" <<'EOF'
reserved; the full-stack rootfs is self-contained
EOF

(
    cd "${LIB_STAGE}"
    tar -cf - . | xz -T0 > "${STAGING}/library-${VER}.tar.xz"
)

# ---------------------------------------------------------------------------
# 3. control-<ver>.tar.xz — stub
# ---------------------------------------------------------------------------
echo "[build-tgz] building control-${VER}.tar.xz (stub) ..."

CTRL_STAGE="${STAGING}/control"
mkdir -p "${CTRL_STAGE}"
cp "${PACKAGING_DIR}/control-stub/RESERVED-FOR-MCU-PLAN4" "${CTRL_STAGE}/"

(
    cd "${CTRL_STAGE}"
    tar -cf - . | xz -T0 > "${STAGING}/control-${VER}.tar.xz"
)

# ---------------------------------------------------------------------------
# 4. Outer md5sum.list (md5 of the three .tar.xz files)
# ---------------------------------------------------------------------------
echo "[build-tgz] generating outer md5sum.list ..."
(
    cd "${STAGING}"
    md5sum \
        "software-${VER}.tar.xz" \
        "library-${VER}.tar.xz" \
        "control-${VER}.tar.xz" \
        > md5sum.list
)

# ---------------------------------------------------------------------------
# 5. Assemble the outer .tgz
# ---------------------------------------------------------------------------
# NOTE: despite the .tgz extension, the stock FlashForge OTA is a PLAIN (uncompressed)
# tar of xz subpackages — verified: real stock .tgz is "POSIX tar archive", not gzip.
# Use plain `tar -cf` so the stock USB updater accepts it. Do NOT gzip.
OUTPUT="${DIST_DIR}/reforge-${VER}.tgz"
echo "[build-tgz] assembling ${OUTPUT} (plain tar, stock format) ..."

(
    cd "${STAGING}"
    tar -cf "${OUTPUT}" \
        "software-${VER}.tar.xz" \
        "library-${VER}.tar.xz" \
        "control-${VER}.tar.xz" \
        md5sum.list \
        -C "${PACKAGING_DIR}" flashforge_init.sh
)

echo ""
echo "[build-tgz] Done: ${OUTPUT}"
ls -lh "${OUTPUT}"

# ---------------------------------------------------------------------------
# 6. Uninstall package — same stock format, stub subpackages + uninstaller
# ---------------------------------------------------------------------------
echo ""
echo "[build-tgz] building uninstall package ..."

UNSTAGE="$(mktemp -d /tmp/reforge-unpkg-XXXXXX)"
# clean up on exit alongside the main STAGING dir
trap 'rm -rf "${STAGING}" "${UNSTAGE}"' EXIT

# Stub library for uninstall pkg
LIB_UNSTAGE="${UNSTAGE}/library"
mkdir -p "${LIB_UNSTAGE}"
cat > "${LIB_UNSTAGE}/README" <<'EOF'
uninstall package — no software payload
EOF
( cd "${LIB_UNSTAGE}" && tar -cf - . | xz -T0 > "${UNSTAGE}/library-${VER}.tar.xz" )

# Stub control for uninstall pkg
CTRL_UNSTAGE="${UNSTAGE}/control"
mkdir -p "${CTRL_UNSTAGE}"
cp "${PACKAGING_DIR}/control-stub/RESERVED-FOR-MCU-PLAN4" "${CTRL_UNSTAGE}/"
( cd "${CTRL_UNSTAGE}" && tar -cf - . | xz -T0 > "${UNSTAGE}/control-${VER}.tar.xz" )

# Stub software for uninstall pkg (no rootfs — uninstaller needs nothing to extract)
SW_UNSTAGE="${UNSTAGE}/software"
mkdir -p "${SW_UNSTAGE}"
cat > "${SW_UNSTAGE}/README" <<'EOF'
uninstall package — no software payload
EOF
( cd "${SW_UNSTAGE}" && tar -cf - . | xz -T0 > "${UNSTAGE}/software-${VER}.tar.xz" )

# Outer md5sum.list for uninstall pkg
( cd "${UNSTAGE}" && md5sum \
    "software-${VER}.tar.xz" \
    "library-${VER}.tar.xz" \
    "control-${VER}.tar.xz" \
    > md5sum.list )

UNINSTALL_OUTPUT="${DIST_DIR}/reforge-uninstall-${VER}.tgz"
echo "[build-tgz] assembling ${UNINSTALL_OUTPUT} ..."
(
    cd "${UNSTAGE}"
    tar -cf "${UNINSTALL_OUTPUT}" \
        "software-${VER}.tar.xz" \
        "library-${VER}.tar.xz" \
        "control-${VER}.tar.xz" \
        md5sum.list \
        -C "${PACKAGING_DIR}/uninstall" flashforge_init.sh
)

echo "[build-tgz] Done: ${UNINSTALL_OUTPUT}"
ls -lh "${UNINSTALL_OUTPUT}"
