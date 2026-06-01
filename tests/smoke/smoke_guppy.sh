#!/bin/sh
# qemu-user smoke test of the full-stack (guppyscreen) ReForge rootfs.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAR="$ROOT/build/output-guppy/images/rootfs.tar.xz"
EXTRACT="$ROOT/build/output-guppy/smoke-root"

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

# 8) nginx binary is present and is ARM
[ -f "$EXTRACT/usr/sbin/nginx" ] \
  || fail "/usr/sbin/nginx missing"
file "$EXTRACT/usr/sbin/nginx" | grep -q "ARM" \
  || fail "nginx not ARM"

# 9) GuppyScreen binary is ARM
[ -f "$EXTRACT/opt/guppyscreen/guppyscreen" ] \
  || fail "/opt/guppyscreen/guppyscreen missing"
file "$EXTRACT/opt/guppyscreen/guppyscreen" | grep -q "ARM" \
  || fail "guppyscreen binary not ARM"

# 10) The 5 real init scripts exist and are executable
for svc in S00cloudblock S60klipper S65moonraker S70nginx S75guppyscreen; do
  SCRIPT="$EXTRACT/etc/init.d/$svc"
  [ -f "$SCRIPT" ] || fail "init script $svc missing"
  [ -x "$SCRIPT" ] || fail "init script $svc not executable"
done

# 11) printer.cfg exists
[ -f "$EXTRACT/etc/reforge/printer.cfg" ] \
  || fail "/etc/reforge/printer.cfg missing"

echo "PASS: full-stack rootfs verified"
