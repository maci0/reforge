#!/bin/bash
# rootfs.sh — stage the ReForge rootfs (build/output rootfs.tar) the way ~7
# harnesses each open-coded it.
#
#   rootfs_tar                 # echoes the rootfs.tar(.xz) path, or returns 1
#   stage_rootfs <dir> [tar]   # extract the rootfs into <dir>
#   rootfs_p6_ext4 <out> [MiB] # the rootfs as a p6-sized ext4 (default 1280M)

rootfs_tar() {
    local t="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar}"
    [ -f "${t}" ] || t="${REPO_ROOT}/build/output/images/rootfs.tar.xz"
    [ -f "${t}" ] || return 1
    printf '%s' "${t}"
}

stage_rootfs() {
    local d="$1" t="${2:-}"
    [ -n "${t}" ] || t="$(rootfs_tar)" || die "no rootfs.tar (run: make rootfs)"
    mkdir -p "${d}"
    tar -C "${d}" -xf "${t}"
    [ -x "${d}/mod/start.sh" ] || die "rootfs has no /mod/start.sh (old/wrong build): ${t}"
}

rootfs_p6_ext4() {
    local out="$1" sz="${2:-1280M}" d
    d="$(mktemp -d "${BUILD_DIR}/.rfs-XXXXXX")"
    stage_rootfs "${d}"
    mkext4 "${out}" "${sz}" rootfs "${d}"
    rm -rf "${d}"
}
