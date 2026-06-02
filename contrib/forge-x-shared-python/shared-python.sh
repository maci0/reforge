#!/bin/sh
# shared-python.sh — opt-in toggle: run klippy under moonraker's hard-float Python 3.11
# FROM THE HOST ROOT (not chroot), so klippy keeps the host filesystem (its
# gcode_shell_command macros — camera/screen/reboot/zmem — exec host rootfs scripts and
# MUST run with host / as root), while mapping the SAME libpython3.11 inode moonraker uses
# (COW-shared once instead of resident twice). Reversible; stock when disabled. Run ON DEVICE.
#
#   shared-python.sh enable | disable | status
#
# How the host launch works (no chroot):
#   * The chroot's python3.11 + hard-float glibc live under $MOD. Its binaries hardcode the
#     loader path /lib/ld-linux-armhf.so.3 (absent on the soft-float host), so we add a host
#     symlink /lib/ld-linux-armhf.so.3 -> $MOD/lib/ld-linux-armhf.so.3.
#   * We launch the BASE interpreter $MOD/usr/bin/python3.11 (the venv wrapper is an older
#     build that faults from host) with PYTHONHOME=$MOD/usr (stdlib), PYTHONPATH=<venv
#     site-packages> (cffi/greenlet/pycparser + moonraker's jinja2/pyserial/numpy), and
#     LD_LIBRARY_PATH=$MOD/usr/lib:$MOD/lib (hard-float libs).
#   * That LD_LIBRARY_PATH would break host soft-float macro children (busybox: libc ABI
#     mismatch -> "internal error"). klipper's gcode_shell_command Popen has no env=, so it
#     leaks. We patch gcode_shell_command.py to spawn children with those vars stripped.
#
# Prereqs for `enable` (stage next to this script — see README.md):
#   ./c_helper.hf.so   hard-float c_helper.so (tools/build-chelper-hardfloat.sh)
#   ./wheels/*.whl     cffi + pycparser + greenlet, cp311 armv7 (hard-float)
set -eu

MOD=/data/.mod/.forge-x
FLAG=/opt/config/mod_data/shared_python
START=/opt/klipper/start.sh
CHELPER=/opt/klipper/klippy/chelper
GSC=/opt/klipper/klippy/extras/gcode_shell_command.py
LDLINK=/lib/ld-linux-armhf.so.3
LDMARK=/opt/config/mod_data/shared_python.ldlink   # records that WE created $LDLINK
SP="$MOD/root/moonraker-env/lib/python3.11/site-packages"
HERE=$(cd "$(dirname "$0")" && pwd)
MARK="# >>> shared-python toggle >>>"

restart_klipper() {
  if [ -x /opt/config/mod/.shell/restart_klipper.sh ]; then
    /opt/config/mod/.shell/restart_klipper.sh --hard
  else
    for p in $(ps w 2>/dev/null | grep "[k]lippy.py" | awk '{print $1}'); do kill "$p" 2>/dev/null || true; done
    sleep 2
    sh "$START" >/dev/null 2>&1 &
  fi
}

ensure_ldlink() {
  # host needs /lib/ld-linux-armhf.so.3 for the hard-float python to run from the host root
  if [ ! -e "$LDLINK" ]; then
    ln -s "$MOD/lib/ld-linux-armhf.so.3" "$LDLINK"
    : > "$LDMARK"   # remember we created it, so disable only removes our own
  fi
}

patch_start() {
  # Always (re)apply from a clean stock start.sh so an older toggle block can't linger.
  if [ -f "$START.preshared" ]; then
    cp -p "$START.preshared" "$START"            # restore stock, then patch fresh
  else
    cp -p "$START" "$START.preshared"            # first run: capture stock
  fi
  [ -f "$CHELPER/c_helper.soft.so" ] || cp -p "$CHELPER/c_helper.so" "$CHELPER/c_helper.soft.so"
  tmp=$(mktemp)
  awk -v mark="$MARK" -v flag="$FLAG" -v ch="$CHELPER" -v mod="$MOD" -v sp="$SP" '
    /klippy\.py/ && !done {
      print mark
      print "KLIPPER_PY=/opt/Python-3.7.11/bin/python3.7"
      print "if [ -f " flag " ]; then"
      print "    # swap the .so with host busybox cp BEFORE exporting the hard-float env"
      print "    # (cp is soft-float; a hard-float LD_LIBRARY_PATH would fault it)."
      print "    [ -f " ch "/c_helper.hf.so ] && cp -f " ch "/c_helper.hf.so " ch "/c_helper.so"
      print "    KLIPPER_PY=" mod "/usr/bin/python3.11"
      print "    export PYTHONHOME=" mod "/usr"
      print "    export PYTHONPATH=" sp
      print "    export LD_LIBRARY_PATH=" mod "/usr/lib:" mod "/lib"   # overwrite, not append (no soft-float libs)"
      print "else"
      print "    [ -f " ch "/c_helper.soft.so ] && cp -f " ch "/c_helper.soft.so " ch "/c_helper.so"
      print "fi"
      print "# <<< shared-python toggle <<<"
      sub(/\/opt\/Python-3\.7\.11\/bin\/python3\.7/, "$KLIPPER_PY")
      done=1
    }
    { print }
  ' "$START" > "$tmp"
  grep -q "$MARK" "$tmp" || { echo "patch FAILED (no klippy.py launch line in $START)"; rm -f "$tmp"; exit 1; }
  cat "$tmp" > "$START"; rm -f "$tmp"
  echo "patched $START"
}

patch_gsc() {
  # Make gcode_shell_command spawn children with the hard-float python env stripped, so host
  # soft-float macro scripts (camera/screen/reboot/...) don't inherit LD_LIBRARY_PATH etc.
  grep -q "_shared_python_env" "$GSC" && return 0
  [ -f "$GSC.preshared" ] || cp -p "$GSC" "$GSC.preshared"
  # use the always-present stock soft-float py3.7 — this is pure text editing, no env needed
  /opt/Python-3.7.11/bin/python3.7 - "$GSC" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
helper=('\nimport os as _os\n'
        'def _shared_python_env():\n'
        '    e=dict(_os.environ)\n'
        '    for k in ("LD_LIBRARY_PATH","PYTHONHOME","PYTHONPATH","VIRTUAL_ENV"):\n'
        '        e.pop(k,None)\n'
        '    return e\n')
s=s.replace('import subprocess\n','import subprocess\n'+helper,1)
s=s.replace('stdout=subprocess.PIPE, stderr=subprocess.STDOUT,\n                start_new_session=True',
            'stdout=subprocess.PIPE, stderr=subprocess.STDOUT,\n                start_new_session=True, env=_shared_python_env()')
s=s.replace('self.command + gcode_params, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)',
            'self.command + gcode_params, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=_shared_python_env())')
open(p,'w').write(s)
PY
  grep -q "_shared_python_env" "$GSC" && echo "patched $GSC" || { echo "patch_gsc FAILED"; exit 1; }
}

install_deps() {
  [ -f "$HERE/c_helper.hf.so" ] || { echo "missing $HERE/c_helper.hf.so (build it — see README)"; exit 1; }
  cp -f "$HERE/c_helper.hf.so" "$CHELPER/c_helper.hf.so"
  if [ -d "$HERE/wheels" ]; then
    [ -d "$SP" ] || { echo "venv site-packages not found at $SP"; exit 1; }
    for w in "$HERE"/wheels/*.whl; do [ -f "$w" ] || continue
      unzip -oq "$w" -d "$SP" || { echo "unzip of $(basename "$w") failed"; exit 1; }
    done
  fi
}

verify_launch() {
  # dry import + chelper dlopen via the exact host-launch env (before touching klippy)
  ensure_ldlink
  rm -rf /tmp/sp-vl; mkdir -p /tmp/sp-vl; cp -r "$CHELPER/." /tmp/sp-vl/; cp -f "$HERE/c_helper.hf.so" /tmp/sp-vl/c_helper.so
  env -i HOME=/root PYTHONHOME="$MOD/usr" PYTHONPATH="$SP" LD_LIBRARY_PATH="$MOD/usr/lib:$MOD/lib" \
    "$MOD/usr/bin/python3.11" - <<PY
import sys,importlib.util
import cffi,serial,greenlet,pycparser
sp=importlib.util.spec_from_file_location("chelper","/tmp/sp-vl/__init__.py")
ch=importlib.util.module_from_spec(sp); sys.modules["chelper"]=ch; sp.loader.exec_module(ch)
m,l=ch.get_ffi(); assert hasattr(l,"serialqueue_alloc")
print("VERIFY_OK")
PY
  rc=$?; rm -rf /tmp/sp-vl
  [ "$rc" = 0 ] || { echo "verify_launch FAILED (host py3.11 cannot load chelper)"; exit 1; }
}

case "${1:-}" in
  enable)
    install_deps
    verify_launch
    patch_start
    patch_gsc
    mkdir -p "$(dirname "$FLAG")"; : > "$FLAG"
    echo "shared-python ENABLED — restarting klippy as host $MOD/usr/bin/python3.11 ..."
    restart_klipper
    ;;
  disable)
    rm -f "$FLAG"
    [ -f "$GSC.preshared" ] && cp -p "$GSC.preshared" "$GSC"
    if [ -f "$LDMARK" ]; then rm -f "$LDLINK" "$LDMARK"; fi
    echo "shared-python DISABLED — restarting klippy under stock python3.7 ..."
    restart_klipper
    ;;
  status)
    if [ -f "$FLAG" ]; then echo "flag: ENABLED ($FLAG)"; else echo "flag: disabled"; fi
    grep -q "$MARK" "$START" 2>/dev/null && echo "start.sh: patched" || echo "start.sh: stock"
    grep -q "_shared_python_env" "$GSC" 2>/dev/null && echo "gcode_shell_command: patched" || echo "gcode_shell_command: stock"
    [ -e "$LDLINK" ] && echo "ld symlink: present ($(readlink "$LDLINK"))" || echo "ld symlink: absent"
    kp=$(ps w 2>/dev/null | grep "[k]lippy.py" | awk '{print $1}' | head -1)
    if [ -n "$kp" ]; then
      echo "klippy pid=$kp root=$(readlink /proc/$kp/root 2>/dev/null) libpython=$(grep -oE 'libpython3\.[0-9]+' /proc/$kp/maps 2>/dev/null | head -1)"
    else echo "klippy: not running"; fi
    ;;
  *) echo "usage: $0 {enable|disable|status}"; exit 1 ;;
esac
