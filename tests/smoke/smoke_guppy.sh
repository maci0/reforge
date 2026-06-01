#!/bin/sh
# qemu-user smoke test of the full-stack (guppyscreen) ReForge rootfs.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAR="$ROOT/build/output/images/rootfs.tar.xz"
EXTRACT="$ROOT/build/output/smoke-root"

[ -f "$TAR" ] || { echo "FAIL: no rootfs at $TAR"; exit 1; }
rm -rf "$EXTRACT"; mkdir -p "$EXTRACT"
tar -C "$EXTRACT" -xf "$TAR"

fail() { echo "FAIL: $1"; exit 1; }

# 1) Basic sanity: busybox must be ARM and run under qemu-user
file "$EXTRACT/bin/busybox" | grep -q "ARM" \
  || fail "busybox not ARM"
OUT=$(QEMU_LD_PREFIX="$EXTRACT" qemu-arm-static "$EXTRACT/bin/busybox" echo reforge-ok)
[ "$OUT" = "reforge-ok" ] \
  || fail "busybox did not run under qemu ($OUT)"

# 2) ReForge branding
grep -q "ID=reforge" "$EXTRACT/etc/os-release" \
  || fail "os-release branding missing"

# 3) Python3 binary exists and is ARM (may be a symlink — resolve it)
[ -f "$EXTRACT/usr/bin/python3" ] \
  || fail "/usr/bin/python3 missing"
PY3_REAL="$EXTRACT/usr/bin/python3"
# file(1) reports "symbolic link" instead of ELF info; resolve manually
if [ -L "$PY3_REAL" ]; then
  PY3_TARGET="$(readlink "$PY3_REAL")"
  # target may be relative (e.g. "python3.14") or absolute
  case "$PY3_TARGET" in
    /*) PY3_REAL="$EXTRACT$PY3_TARGET" ;;
    *)  PY3_REAL="$(dirname "$PY3_REAL")/$PY3_TARGET" ;;
  esac
fi
file "$PY3_REAL" | grep -q "ARM" \
  || fail "python3 not ARM (resolved: $PY3_REAL)"

# 4) Python3 can import numpy, tornado, ssl, sqlite3 under qemu
PYCHECK=$(QEMU_LD_PREFIX="$EXTRACT" qemu-arm-static \
  "$EXTRACT/usr/bin/python3" -c \
  "import numpy, tornado, ssl, sqlite3; print('py-ok')" 2>&1) \
  || true
echo "$PYCHECK" | grep -q "py-ok" \
  || fail "python3 import check failed: $PYCHECK"

# 5) Klipper: klippy.py and ARM chelper .so
[ -f "$EXTRACT/opt/klipper/klippy/klippy.py" ] \
  || fail "/opt/klipper/klippy/klippy.py missing"
CHELPER_SO=$(find "$EXTRACT/opt/klipper/klippy/chelper" -name "*.so" | head -1)
[ -n "$CHELPER_SO" ] \
  || fail "no chelper .so found under /opt/klipper/klippy/chelper"
file "$CHELPER_SO" | grep -q "ARM" \
  || fail "chelper .so not ARM: $CHELPER_SO"

# 6) Moonraker: moonraker.py
[ -f "$EXTRACT/opt/moonraker/moonraker/moonraker.py" ] \
  || fail "/opt/moonraker/moonraker/moonraker.py missing"

# 7) Mainsail web UI
[ -f "$EXTRACT/var/www/mainsail/index.html" ] \
  || fail "/var/www/mainsail/index.html missing"

# 8) busybox httpd applet present (serves Mainsail; replaces nginx)
[ -e "$EXTRACT/usr/sbin/httpd" ] \
  || fail "/usr/sbin/httpd missing (busybox httpd applet not enabled?)"

# 9) GuppyScreen binary is ARM
[ -f "$EXTRACT/opt/guppyscreen/guppyscreen" ] \
  || fail "/opt/guppyscreen/guppyscreen missing"
file "$EXTRACT/opt/guppyscreen/guppyscreen" | grep -q "ARM" \
  || fail "guppyscreen binary not ARM"

# 10) The 5 real init scripts live in the self-contained mod dir (run-in-place,
#     no /etc/init.d mirror) and are executable.
for svc in S00cloudblock S60klipper S65moonraker S70httpd S75guppyscreen; do
  SCRIPT="$EXTRACT/mod/init.d/$svc"
  [ -f "$SCRIPT" ] || fail "mod init script $svc missing"
  [ -x "$SCRIPT" ] || fail "mod init script $svc not executable"
done
# There must be NO /etc/init.d mirror of the ReForge S-scripts.
[ -e "$EXTRACT/etc/init.d/S60klipper" ] \
  && fail "stale /etc/init.d/S60klipper mirror present (should run from /mod)"

# 10b) mod/ is self-contained: start.sh/stop.sh + service wrappers + release_info
[ -x "$EXTRACT/mod/start.sh" ] || fail "/mod/start.sh missing or not executable"
[ -x "$EXTRACT/mod/stop.sh" ]  || fail "/mod/stop.sh missing or not executable"
for svc in klipper moonraker guppyscreen reforge; do
  [ -x "$EXTRACT/mod/services/$svc" ] || fail "/mod/services/$svc missing/not executable"
done
[ -f "$EXTRACT/mod/release_info.json" ] || fail "/mod/release_info.json missing"
grep -q '"project_owner": "maci0"' "$EXTRACT/mod/release_info.json" \
  || fail "/mod/release_info.json missing project_owner key"
# zram modules relocated into mod/
[ -f "$EXTRACT/mod/modules/zram.ko" ] || fail "/mod/modules/zram.ko missing"
# LKG baseline seeded by post-build
[ -f "$EXTRACT/lkg/release_info.json" ] || fail "/lkg seed missing (cp -a mod lkg)"

# 11) printer.cfg ships inside the mod dir (start.sh symlinks /etc/reforge -> /mod/etc/reforge)
[ -f "$EXTRACT/mod/etc/reforge/printer.cfg" ] \
  || fail "/mod/etc/reforge/printer.cfg missing"

echo "PASS: full-stack rootfs verified"
