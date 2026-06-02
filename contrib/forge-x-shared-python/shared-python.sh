#!/bin/sh
# shared-python.sh — opt-in toggle: run klippy under moonraker's hard-float Python 3.11
# venv instead of the separate stock soft-float Python 3.7, so the two share one resident
# interpreter. Reversible; stock behaviour when disabled. Run ON THE DEVICE.
#
#   shared-python.sh enable | disable | status
#
# Prereqs for `enable` (stage them next to this script first — see README.md):
#   ./c_helper.hf.so          hard-float c_helper.so built from THIS klipper's chelper
#                             (tools/build-chelper-hardfloat.sh)
#   ./wheels/*.whl            cffi + pycparser + greenlet, cp311 armv7 (hard-float)
set -eu

FLAG=/opt/config/mod_data/shared_python
START=/opt/klipper/start.sh
CHELPER=/opt/klipper/klippy/chelper
VENV=/root/moonraker-env
HERE=$(cd "$(dirname "$0")" && pwd)
MARK="# >>> shared-python toggle >>>"

restart_klipper() {
  if [ -x /opt/config/mod/.shell/restart_klipper.sh ]; then
    /opt/config/mod/.shell/restart_klipper.sh
  else
    # kill the running klippy, then re-run the (patched) launcher
    for p in $(ps w 2>/dev/null | grep "[k]lippy.py" | awk '{print $1}'); do kill "$p" 2>/dev/null || true; done
    sleep 2
    sh "$START" >/dev/null 2>&1 &
  fi
}

patch_start() {
  # Idempotent: insert a flag-gated interpreter+chelper select before the klippy launch,
  # and route the launch through $KLIPPER_PY. Stock byte-for-byte when the flag is absent.
  grep -q "$MARK" "$START" && return 0
  [ -f "$START.preshared" ] || cp -p "$START" "$START.preshared"
  # back up the stock soft-float c_helper.so once
  [ -f "$CHELPER/c_helper.soft.so" ] || cp -p "$CHELPER/c_helper.so" "$CHELPER/c_helper.soft.so"

  tmp=$(mktemp)
  awk -v mark="$MARK" -v flag="$FLAG" -v ch="$CHELPER" -v venv="$VENV" '
    /klippy\.py/ && !done {
      print mark
      print "KLIPPER_PY=/opt/Python-3.7.11/bin/python3.7"
      print "if [ -f " flag " ]; then"
      print "    KLIPPER_PY=" venv "/bin/python3"
      print "    [ -f " ch "/c_helper.hf.so ] && cp -f " ch "/c_helper.hf.so " ch "/c_helper.so"
      print "    export LD_LIBRARY_PATH=" venv "/lib:$LD_LIBRARY_PATH"
      print "else"
      print "    [ -f " ch "/c_helper.soft.so ] && cp -f " ch "/c_helper.soft.so " ch "/c_helper.so"
      print "fi"
      print "# <<< shared-python toggle <<<"
      # route this launch line through $KLIPPER_PY (replace the hardcoded interpreter)
      sub(/\/opt\/Python-3\.7\.11\/bin\/python3\.7/, "\"$KLIPPER_PY\"")
      done=1
    }
    { print }
  ' "$START" > "$tmp"
  grep -q "$MARK" "$tmp" || { echo "patch FAILED (no klippy.py launch line found in $START)"; rm -f "$tmp"; exit 1; }
  cat "$tmp" > "$START"; rm -f "$tmp"
  echo "patched $START (stock launch preserved when flag absent; backup at $START.preshared)"
}

install_deps() {
  # cffi + pycparser + greenlet into the 3.11 venv (offline, from staged wheels).
  [ -f "$HERE/c_helper.hf.so" ] || { echo "missing $HERE/c_helper.hf.so (build it — see README)"; exit 1; }
  cp -f "$HERE/c_helper.hf.so" "$CHELPER/c_helper.hf.so"
  if [ -d "$HERE/wheels" ]; then
    "$VENV/bin/python3" -m pip install --no-index --find-links "$HERE/wheels" cffi pycparser greenlet \
      || { echo "pip install of cffi/pycparser/greenlet into $VENV failed"; exit 1; }
  fi
  # sanity: the venv must now import klippy's C-ext deps
  "$VENV/bin/python3" -c "import cffi,pycparser,greenlet,serial" \
    || { echo "venv missing klippy deps after install"; exit 1; }
}

case "${1:-}" in
  enable)
    patch_start
    install_deps
    mkdir -p "$(dirname "$FLAG")"; : > "$FLAG"
    echo "shared-python ENABLED — restarting klippy under $VENV/bin/python3 ..."
    restart_klipper
    ;;
  disable)
    rm -f "$FLAG"
    echo "shared-python DISABLED — restarting klippy under stock python3.7 ..."
    restart_klipper
    ;;
  status)
    if [ -f "$FLAG" ]; then echo "flag: ENABLED ($FLAG)"; else echo "flag: disabled"; fi
    grep -q "$MARK" "$START" 2>/dev/null && echo "start.sh: patched" || echo "start.sh: stock (unpatched)"
    kp=$(ps w 2>/dev/null | grep "[k]lippy.py" | awk '{print $1}' | head -1)
    [ -n "$kp" ] && echo "klippy pid=$kp interp=$(readlink -f /proc/$kp/exe 2>/dev/null) libpython=$(grep -oE 'libpython3\.[0-9]+' /proc/$kp/maps 2>/dev/null | head -1)" || echo "klippy: not running"
    ;;
  *) echo "usage: $0 {enable|disable|status}"; exit 1 ;;
esac
