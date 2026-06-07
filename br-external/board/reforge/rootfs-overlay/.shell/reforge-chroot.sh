#!/bin/sh
# reforge-chroot.sh — shared chroot setup for the ReForge boot paths.
#
# Sourced (NOT executed) by both entry points so they don't carry two copies of
# the mount layout:
#   - install: .shell/reforge-boot          (rootfs bind-mounted at /reforge)
#   - live:    packaging/live/flashforge_init.sh (F2FS USB partition at /reforge)
#
# Both converge on "the ReForge rootfs is mounted at $REFORGE_ROOT"; this helper
# wires the runtime filesystems into it and exposes the printer's /data. The
# mount SOURCE differs per mode (dir bind vs USB block device); the mount LAYOUT
# is identical and lives here.
#
# POSIX sh / BusyBox. -e / -u clean: defines a function, runs nothing at source
# time, and references only its own positional parameters.

# reforge_chroot_mounts <root> <data> [tmp_mode]
#   <root>      where the ReForge rootfs is already mounted (e.g. /reforge)
#   <data>      the printer's persistent /data to expose at <root>/data
#   [tmp_mode]  "bind" (default) binds the host /tmp into the chroot — install
#               mode shares the stock /tmp (SKIP_MOD markers etc). "tmpfs"
#               mounts a fresh tmpfs — live mode wants an ephemeral /tmp.
#
# Mounts are issued plainly: the caller's error policy applies unchanged
# (reforge-boot runs under `set -e` so a failure aborts the boot; the live
# launcher is lenient and continues). Mountpoint dirs are created first so a
# fresh rootfs that is missing one does not fail the mount.
reforge_chroot_mounts() {
    _rcm_root="$1"
    _rcm_data="$2"
    _rcm_tmp="${3:-bind}"

    for _rcm_d in proc sys dev run tmp data; do
        mkdir -p "${_rcm_root}/${_rcm_d}"
    done

    mount -t proc proc        "${_rcm_root}/proc"
    mount --rbind /sys        "${_rcm_root}/sys"
    mount --rbind /dev        "${_rcm_root}/dev"
    mount --bind  /run        "${_rcm_root}/run"

    if [ "${_rcm_tmp}" = "tmpfs" ]; then
        mount -t tmpfs tmpfs  "${_rcm_root}/tmp"
    else
        mount --bind  /tmp    "${_rcm_root}/tmp"
    fi

    # $DATA is the printer's /data = mmcblk0p7 = ReForge's own space, NOT the
    # stock rootfs. Klipper/Moonraker reach gcodes etc. through it.
    mount --bind  "${_rcm_data}" "${_rcm_root}/data"
}
