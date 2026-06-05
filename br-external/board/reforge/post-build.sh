#!/bin/sh
# ReForge rootfs post-build hook.
#
# Assembles the self-contained OTA `mod/` directory at the chroot root
# (`${TARGET_DIR}/mod` == chroot-internal `/mod`).  The rootfs built here IS
# the on-device `/data/.mod/.reforge` chroot, so `/mod` inside it is the OTA-updatable
# overlay layer that holds ONLY ReForge-authored files (init scripts, default
# configs, zram .ko, banner, service-control wrappers, start/stop).  It carries
# no busybox/glibc/opt, so a future zip update's rmtree(/mod)+extract is safe.
#
# `reforge-boot` execs `chroot ${REFORGE_DIR} /mod/start.sh`, which runs
# `/mod/init.d/S*` in place — no `/etc/init.d` mirror.
#
# Layout assembled here (chroot-internal /mod):
#   mod/
#     release_info.json
#     start.sh stop.sh
#     init.d/{S00cloudblock,S35zram,S60klipper,S65moonraker,S70httpd,S72camera,S75guppyscreen,S99ok}
#     etc/reforge/{printer.cfg,printer.base.cfg,moonraker.conf,zram.conf}
#     modules/{zram.ko,zsmalloc.ko,swapon_prio}
#     usr/bin/reforge-banner
#     services/{klipper,moonraker,guppyscreen,reforge}
#     .shell/{reforge-boot,reforge-lkg.sh}
#
# An LKG seed (`cp -a mod lkg`) is created alongside so the device ships with a
# last-known-good baseline; a USB .tgz install seeds it separately in
# packaging/flashforge_init.sh.
set -e

TARGET_DIR="$1"
BOARD_DIR="$(dirname "$0")"
OVERLAY="${BOARD_DIR}/rootfs-overlay"
REPO_ROOT="$(cd "${BOARD_DIR}/../../.." && pwd)"

echo "reforge-foundation" > "$TARGET_DIR/etc/reforge-stage"

# ---------------------------------------------------------------------------
# Version for release_info.json
# ---------------------------------------------------------------------------
VER="$(cat "${REPO_ROOT}/packaging/VERSION" 2>/dev/null || echo "0.0.0-unknown")"

MOD="${TARGET_DIR}/mod"

echo "[post-build] assembling self-contained mod/ at ${MOD}"
rm -rf "${MOD}"
mkdir -p "${MOD}/init.d" "${MOD}/etc/reforge" "${MOD}/modules" \
         "${MOD}/usr/bin" "${MOD}/services" "${MOD}/.shell"

# ---------------------------------------------------------------------------
# init.d — the ReForge S-scripts (run in place from /mod/init.d, no mirror).
# They were staged into ${TARGET_DIR}/etc/init.d by the rootfs overlay; move
# them into mod/ and remove the originals so there is NO /etc/init.d mirror.
# ---------------------------------------------------------------------------
for s in S00cloudblock S35zram S60klipper S65moonraker S70httpd S72camera S75guppyscreen S99ok; do
    if [ -f "${TARGET_DIR}/etc/init.d/${s}" ]; then
        cp -a "${TARGET_DIR}/etc/init.d/${s}" "${MOD}/init.d/${s}"
        rm -f "${TARGET_DIR}/etc/init.d/${s}"
    elif [ -f "${OVERLAY}/etc/init.d/${s}" ]; then
        # Fallback to the overlay source if the staged copy is absent.
        cp -a "${OVERLAY}/etc/init.d/${s}" "${MOD}/init.d/${s}"
    else
        echo "[post-build] ERROR: init script ${s} not found" >&2
        exit 1
    fi
    chmod 0755 "${MOD}/init.d/${s}"
done

# ---------------------------------------------------------------------------
# etc/reforge — default configs.  The daemons read /etc/reforge/* ; start.sh
# symlinks /etc/reforge -> /mod/etc/reforge so they resolve from the
# OTA-updatable mod dir.  Move the staged copies into mod/.
# ---------------------------------------------------------------------------
for c in printer.cfg printer.base.cfg zram.conf moonraker.conf; do
    if [ -f "${TARGET_DIR}/etc/reforge/${c}" ]; then
        cp -a "${TARGET_DIR}/etc/reforge/${c}" "${MOD}/etc/reforge/${c}"
    fi
done
# Drop the original /etc/reforge so it is not a stale duplicate; start.sh
# recreates it as a symlink to /mod/etc/reforge at boot.
rm -rf "${TARGET_DIR}/etc/reforge"

# ---------------------------------------------------------------------------
# modules — zram .ko + swapon_prio.  Staged at /opt/reforge/zram by
# reforge-zram.mk; move into mod/modules and drop the original.
# ---------------------------------------------------------------------------
for m in zram.ko zsmalloc.ko swapon_prio; do
    if [ -f "${TARGET_DIR}/opt/reforge/zram/${m}" ]; then
        cp -a "${TARGET_DIR}/opt/reforge/zram/${m}" "${MOD}/modules/${m}"
    elif [ -f "${REPO_ROOT}/modules/zram-bsp/dist/${m}" ]; then
        cp -a "${REPO_ROOT}/modules/zram-bsp/dist/${m}" "${MOD}/modules/${m}"
    fi
done
chmod 0755 "${MOD}/modules/swapon_prio" 2>/dev/null || true
rm -rf "${TARGET_DIR}/opt/reforge"

# ---------------------------------------------------------------------------
# usr/bin/reforge-banner — keep a copy in mod/ (the OTA copy) AND leave the
# rootfs /usr/bin/reforge-banner in place (profile.d login banner + the
# pre-chroot banner render in reforge-boot both reference /usr/bin).
# ---------------------------------------------------------------------------
if [ -f "${TARGET_DIR}/usr/bin/reforge-banner" ]; then
    cp -a "${TARGET_DIR}/usr/bin/reforge-banner" "${MOD}/usr/bin/reforge-banner"
elif [ -f "${OVERLAY}/usr/bin/reforge-banner" ]; then
    cp -a "${OVERLAY}/usr/bin/reforge-banner" "${MOD}/usr/bin/reforge-banner"
fi
chmod 0755 "${MOD}/usr/bin/reforge-banner" 2>/dev/null || true

# ---------------------------------------------------------------------------
# .shell — reforge-boot copy (for self-update) + reforge-lkg.sh (trial/LKG
# helpers, sourced by both reforge-boot on the stock side and S99ok inside the
# chroot).  Both are authored in the rootfs overlay; copy them into mod/.
# ---------------------------------------------------------------------------
if [ -f "${OVERLAY}/.shell/reforge-boot" ]; then
    cp -a "${OVERLAY}/.shell/reforge-boot" "${MOD}/.shell/reforge-boot"
    chmod 0755 "${MOD}/.shell/reforge-boot"
fi
if [ -f "${OVERLAY}/.shell/reforge-lkg.sh" ]; then
    cp -a "${OVERLAY}/.shell/reforge-lkg.sh" "${MOD}/.shell/reforge-lkg.sh"
    chmod 0755 "${MOD}/.shell/reforge-lkg.sh"
else
    echo "[post-build] ERROR: reforge-lkg.sh not found in overlay" >&2
    exit 1
fi
# reforge-vmtune.sh — zram-as-primary-swap VM tuning, sourced by S35zram.
if [ -f "${OVERLAY}/.shell/reforge-vmtune.sh" ]; then
    cp -a "${OVERLAY}/.shell/reforge-vmtune.sh" "${MOD}/.shell/reforge-vmtune.sh"
    chmod 0755 "${MOD}/.shell/reforge-vmtune.sh"
else
    echo "[post-build] ERROR: reforge-vmtune.sh not found in overlay" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# services/ — SimpleProvider script_path wrappers (delegate to the S-scripts).
# ---------------------------------------------------------------------------
cat > "${MOD}/services/klipper" <<'EOF'
#!/bin/sh
exec /mod/init.d/S60klipper "$1"
EOF
cat > "${MOD}/services/moonraker" <<'EOF'
#!/bin/sh
exec /mod/init.d/S65moonraker "$1"
EOF
cat > "${MOD}/services/guppyscreen" <<'EOF'
#!/bin/sh
exec /mod/init.d/S75guppyscreen "$1"
EOF
cat > "${MOD}/services/reforge" <<'EOF'
#!/bin/sh
# The `reforge` component itself: start/stop the whole S-chain.
case "$1" in
    start)   exec /mod/start.sh ;;
    stop)    exec /mod/stop.sh ;;
    restart) /mod/stop.sh; exec /mod/start.sh ;;
    *)       echo "Usage: $0 {start|stop|restart}" >&2; exit 1 ;;
esac
EOF
chmod 0755 "${MOD}/services/klipper" "${MOD}/services/moonraker" \
           "${MOD}/services/guppyscreen" "${MOD}/services/reforge"

# ---------------------------------------------------------------------------
# start.sh / stop.sh — run/stop the /mod/init.d/S* chain in place.
# ---------------------------------------------------------------------------
cat > "${MOD}/start.sh" <<'EOF'
#!/bin/sh
# /mod/start.sh — bring up the ReForge stack by running /mod/init.d/S* in
# sorted order.  Runs INSIDE the chroot (cwd = chroot root = /).  No mirror
# to /etc/init.d: the S-scripts execute directly from /mod/init.d.
set -e

MOD=/mod

# Make the OTA-updatable default configs visible at the path the daemons read
# (/etc/reforge/printer.cfg, moonraker.conf, zram.conf).  Replace any stale
# /etc/reforge with a symlink into /mod so updates are picked up live.
if [ ! -L /etc/reforge ]; then
    rm -rf /etc/reforge
    ln -s "${MOD}/etc/reforge" /etc/reforge
fi

# SCREEN_MODE is exported by reforge-boot; default headless.
SCREEN_MODE="${SCREEN_MODE:-HEADLESS}"
export SCREEN_MODE

set +e
for s in "${MOD}"/init.d/S*; do
    [ -f "$s" ] || continue
    case "$(basename "$s")" in
        S75guppyscreen)
            # Only launch the GUI when GuppyScreen mode is selected; the script
            # self-skips without a framebuffer regardless.
            [ "$SCREEN_MODE" = "GUPPY" ] || continue
            ;;
    esac
    echo "[start.sh] $(basename "$s") start"
    "$s" start
done
EOF
chmod 0755 "${MOD}/start.sh"

cat > "${MOD}/stop.sh" <<'EOF'
#!/bin/sh
# /mod/stop.sh — stop the ReForge stack by running /mod/init.d/S* in REVERSE
# order with `stop`.  Runs inside the chroot.
MOD=/mod
for s in $(ls -r "${MOD}"/init.d/S* 2>/dev/null); do
    [ -f "$s" ] || continue
    echo "[stop.sh] $(basename "$s") stop"
    "$s" stop 2>/dev/null || true
done
EOF
chmod 0755 "${MOD}/stop.sh"

# ---------------------------------------------------------------------------
# release_info.json — 4 keys (Moonraker reads version on-device).
# ---------------------------------------------------------------------------
cat > "${MOD}/release_info.json" <<EOF
{
  "project_name": "reforge",
  "project_owner": "maci0",
  "version": "${VER}",
  "asset_name": "reforge.zip"
}
EOF

# '.writeable' marker: Moonraker's update_manager will not overwrite a component
# dir without it (else NetDeploy reserves the path -> "Invalid Installation" ->
# OTA refused). Mark the first-install image paths so the very first OTA is
# allowed; the OTA zips themselves carry the marker too (see build-release.sh).
: > "${MOD}/.writeable"
for _c in klipper moonraker guppyscreen; do
    [ -d "${TARGET_DIR}/opt/${_c}" ] && : > "${TARGET_DIR}/opt/${_c}/.writeable"
done

# ---------------------------------------------------------------------------
# Seed the last-known-good baseline (a verbatim copy of the shipped mod/).
# ---------------------------------------------------------------------------
echo "[post-build] seeding LKG: cp -a mod lkg"
rm -rf "${TARGET_DIR}/lkg"
cp -a "${MOD}" "${TARGET_DIR}/lkg"

echo "[post-build] mod/ assembled (version ${VER})"

# ---------------------------------------------------------------------------
# Disable iwd auto-start. Buildroot's iwd package installs /etc/init.d/S40iwd
# which would start iwd at boot in parallel with our wpa_supplicant (launched
# from net-up.sh). Two daemons on wlan0 collide.
#
# We ship the iwd BINARY (/usr/libexec/iwd, /etc/iwd/main.conf) so we can A/B
# test on real hardware with the rtl8821cu USB driver, but the init script
# itself is moved out of /etc/init.d/ so rcS's `S??*` glob doesn't pick it up.
# IMPORTANT: rcS matches `S??*` (S, two chars, anything), so "S40iwd.disabled"
# would STILL match. We move the script to /etc/init.d/disabled/iwd instead
# (a subdir glob's loop doesn't recurse into). To activate iwd as the default
# daemon later, move it back: `mv /etc/init.d/disabled/iwd /etc/init.d/S40iwd`
# (and adjust net-up.sh to NOT launch wpa_supplicant).
#
# Tracked: docs/BACKLOG.md "Mode 3 net stack: switch to iwd, skip ConnMan".
# ---------------------------------------------------------------------------
if [ -f "${TARGET_DIR}/etc/init.d/S40iwd" ]; then
    echo "[post-build] disabling iwd auto-start (S40iwd -> disabled/iwd)"
    mkdir -p "${TARGET_DIR}/etc/init.d/disabled"
    mv "${TARGET_DIR}/etc/init.d/S40iwd" "${TARGET_DIR}/etc/init.d/disabled/iwd"
fi
# Also clean up any stale .disabled file from the prior (broken) approach.
rm -f "${TARGET_DIR}/etc/init.d/S40iwd.disabled"

# ---------------------------------------------------------------------------
# Scrub any __pycache__ + *.pyc that snuck in from the rootfs-overlay.
#
# Anything under br-external/board/reforge/rootfs-overlay/ is copied verbatim
# into ${TARGET_DIR} by Buildroot, including stale host-generated Python
# bytecode caches that Python 3.x leaves next to any script you run on the
# host. Those caches are host-arch (sometimes a different Python minor too)
# and would either crash the device or shadow the .py source with stale code.
# .gitignore catches them at the repo level; this scrub catches them at build
# time so neither a fresh clone nor a developer who briefly ran a script in
# rootfs-overlay/ can ship junk to the device.
#
# We also touch any moonraker/klipper __pycache__ here — those are legitimate
# (Python apps cache their own .pyc at runtime on-device anyway) but the
# host-arch caches under /opt/{moonraker,klipper}/ from a host-run install
# would still mismatch the device. Safer to remove and let on-device runtime
# regenerate.
# ---------------------------------------------------------------------------
echo "[post-build] scrubbing __pycache__ + *.pyc from rootfs ..."
find "${TARGET_DIR}" -depth -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
find "${TARGET_DIR}" -name '*.pyc' -delete 2>/dev/null || true
find "${TARGET_DIR}" -name '*.pyo' -delete 2>/dev/null || true
