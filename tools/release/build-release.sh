#!/usr/bin/env bash
# build-release.sh — slice the built rootfs into per-component OTA zips.
#
# Pure host-side packaging: it reads build/output/target/opt/{klipper,moonraker,
# guppyscreen} and the reforge overlay files, injects a 4-key release_info.json
# at each zip ROOT, builds the USB .tgz, and (optionally) publishes a multi-asset
# GitHub Release. It NEVER touches the device or Moonraker.
#
# Usage:
#   build-release.sh [--no-publish]          # default; local/CI dry build
#   build-release.sh --publish <tag>         # draft -> upload assets -> publish
#
# Env:
#   VER       release version (default: packaging/VERSION)
#   DIST_DIR  output dir for assets (default: packaging/dist)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/release/release-info.sh
. "${REPO_ROOT}/tools/release/release-info.sh"

PACKAGING_DIR="${REPO_ROOT}/packaging"
TARGET_OPT="${REPO_ROOT}/build/output/target/opt"
ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar"

VER="${VER:-$(cat "${PACKAGING_DIR}/VERSION")}"
DIST_DIR="${DIST_DIR:-${PACKAGING_DIR}/dist}"

PUBLISH=0
PUBLISH_TAG=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-publish) PUBLISH=0; shift ;;
        --publish)
            PUBLISH=1
            PUBLISH_TAG="${2:-}"
            [ -n "${PUBLISH_TAG}" ] || { echo "ERROR: --publish requires a <tag>" >&2; exit 2; }
            shift 2
            ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "${TARGET_OPT}" ] || die "build/output/target/opt missing — run 'make rootfs' first"

echo "[build-release] version : ${VER}"
echo "[build-release] dist dir: ${DIST_DIR}"

mkdir -p "${DIST_DIR}"
# Absolute DIST_DIR so the `(cd <stage> && zip ...)` subshells resolve it correctly.
DIST_DIR="$(cd "${DIST_DIR}" && pwd)"

STAGE="$(mktemp -d /tmp/reforge-release-XXXXXX)"
trap 'rm -rf "${STAGE}"' EXIT

# ---------------------------------------------------------------------------
# zip_component <name> <staged-dir>
#   Injects release_info.json at the staged dir root, then zips the dir
#   CONTENTS (cd into it, zip '.') so release_info.json lands at the zip ROOT.
# ---------------------------------------------------------------------------
zip_component() {
    name="$1"
    stage="$2"
    emit_release_info "${name}" "${VER}" "${name}.zip" > "${stage}/release_info.json"
    rm -f "${DIST_DIR}/${name}.zip"
    ( cd "${stage}" && zip -rq "${DIST_DIR}/${name}.zip" . )
    echo "[build-release]   wrote ${DIST_DIR}/${name}.zip"
}

# ---------------------------------------------------------------------------
# /opt components: klipper, moonraker, guppyscreen
# ---------------------------------------------------------------------------
for c in klipper moonraker guppyscreen; do
    echo "[build-release] staging ${c} ..."
    [ -d "${TARGET_OPT}/${c}" ] || die "build/output/target/opt/${c} missing"
    cp -a "${TARGET_OPT}/${c}" "${STAGE}/${c}"

    if [ "${c}" = "klipper" ]; then
        # The device has no compiler: the prebuilt chelper MUST ship in the zip.
        [ -f "${STAGE}/klipper/klippy/chelper/c_helper.so" ] \
            || die "klipper c_helper.so missing from target — cannot publish klipper.zip"
    fi

    zip_component "${c}" "${STAGE}/${c}"
done

# ---------------------------------------------------------------------------
# reforge component: the self-contained mod tree that post-build.sh assembles at
# build/output/target/mod (init.d/, services/, start.sh/stop.sh, etc/reforge,
# modules/, usr/bin, .shell). reforge.zip = the mod CONTENTS, so the device's
# `[update_manager reforge] path: /mod` extract reproduces /mod exactly.
# ---------------------------------------------------------------------------
echo "[build-release] staging reforge (from the built /mod tree) ..."
TARGET_MOD="${REPO_ROOT}/build/output/target/mod"
[ -d "${TARGET_MOD}" ] || die "build/output/target/mod missing — run 'make rootfs' (post-build assembles it)"
cp -a "${TARGET_MOD}" "${STAGE}/reforge"
RF="${STAGE}/reforge"
# sanity: the mod tree must be self-contained (Task 3 layout), not the old flat overlay
{ [ -d "${RF}/init.d" ] && [ -f "${RF}/start.sh" ] && [ -d "${RF}/services" ]; } \
    || die "built mod/ missing init.d/ + start.sh + services/ — bad layout"
zip_component "reforge" "${RF}"

# ---------------------------------------------------------------------------
# USB .tgz — reuse the existing packager, then place it in DIST_DIR as the
# requested VER. build-tgz.sh keys its filename off packaging/VERSION, so we
# locate the produced .tgz and copy it to reforge-<VER>.tgz.
# ---------------------------------------------------------------------------
echo "[build-release] building USB .tgz ..."
[ -f "${ROOTFS_TAR}" ] || die "build/output/images/rootfs.tar missing — run 'make rootfs' first"

TGZ_VER="$(cat "${PACKAGING_DIR}/VERSION")"
"${PACKAGING_DIR}/build-tgz.sh"
SRC_TGZ="${PACKAGING_DIR}/dist/reforge-${TGZ_VER}.tgz"
[ -f "${SRC_TGZ}" ] || die "build-tgz.sh did not produce ${SRC_TGZ}"

DST_TGZ="${DIST_DIR}/reforge-${VER}.tgz"
if [ "${SRC_TGZ}" != "${DST_TGZ}" ]; then
    cp -a "${SRC_TGZ}" "${DST_TGZ}"
fi
echo "[build-release]   placed ${DST_TGZ}"

# ---------------------------------------------------------------------------
# Publish (CI): draft -> upload assets -> un-draft. The draft-then-publish
# avoids consumers seeing a half-uploaded release.
# ---------------------------------------------------------------------------
if [ "${PUBLISH}" -eq 1 ]; then
    echo "[build-release] publishing release ${PUBLISH_TAG} ..."
    ASSETS=(
        "${DIST_DIR}/klipper.zip"
        "${DIST_DIR}/moonraker.zip"
        "${DIST_DIR}/guppyscreen.zip"
        "${DIST_DIR}/reforge.zip"
        "${DST_TGZ}"
    )
    gh release create "${PUBLISH_TAG}" --draft --title "${PUBLISH_TAG}" --notes "ReForge ${VER}"
    gh release upload "${PUBLISH_TAG}" "${ASSETS[@]}" --clobber
    gh release edit "${PUBLISH_TAG}" --draft=false
    echo "[build-release]   published ${PUBLISH_TAG}"
fi

echo "[build-release] done."
ls -lh "${DIST_DIR}"/klipper.zip "${DIST_DIR}"/moonraker.zip \
       "${DIST_DIR}"/guppyscreen.zip "${DIST_DIR}"/reforge.zip "${DST_TGZ}"
