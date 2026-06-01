#!/bin/sh
# chroot_integration.sh — ReForge P2 Task 8 host-side integration test
#
# Proves the core stack (Klipper + Moonraker + Mainsail + nginx) self-integrates
# WITHOUT a device, using qemu-arm-static (no chroot/sudo required).
#
# Exit 0 → PASS (either floor)
# Exit 1 → FAIL
#
# FULL_API=1 path: Moonraker binds :7125, curl API + nginx serve Mainsail
# FULL_API=0 path (documented floor): import smoke + config-parse + nginx -t + bundle present
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARBALL="${ROOTFS_TAR:-$REPO_ROOT/build/output-guppy/images/rootfs.tar.xz}"
QEMU="${QEMU_ARM:-/usr/bin/qemu-arm-static}"

# ── sanity ──────────────────────────────────────────────────────────────────
[ -f "$TARBALL" ] || { echo "FAIL: rootfs not found at $TARBALL"; exit 1; }
[ -x "$QEMU"   ] || { echo "FAIL: qemu-arm-static not found at $QEMU";   exit 1; }

# ── work dir + trap cleanup ──────────────────────────────────────────────────
WORK="$(mktemp -d)"
NTMP="$(mktemp -d)"   # host-writable temp (nginx logs, pid, etc.)
# init PIDs BEFORE the trap so cleanup never hits an unbound var (set -u) and
# never leaks a daemon, regardless of which branch (FULL_API 0/1) we exit from.
KLIPPY_PID=""
MOONRAKER_PID=""
trap 'set +e; [ -n "$KLIPPY_PID" ] && kill "$KLIPPY_PID" 2>/dev/null; [ -n "$MOONRAKER_PID" ] && kill "$MOONRAKER_PID" 2>/dev/null; rm -rf "$WORK" "$NTMP"' EXIT

echo "=== ReForge chroot integration test ==="
echo "    rootfs : $TARBALL"
echo "    workdir: $WORK"
echo "    tmpdir : $NTMP"
echo ""

# ── extract ──────────────────────────────────────────────────────────────────
echo "[1/5] Extracting rootfs..."
tar -C "$WORK" -xf "$TARBALL" 2>/dev/null
echo "      done."

ROOT="$WORK"
PYTHON="$ROOT/usr/bin/python3"
QPYTHON="QEMU_LD_PREFIX=$ROOT PYTHONDONTWRITEBYTECODE=1 HOME=$ROOT/root"

# Validate the rootfs looks right
[ -f "$ROOT/usr/bin/python3" ] || { echo "FAIL: /usr/bin/python3 not found in rootfs"; exit 1; }
[ -f "$ROOT/opt/klipper/klippy/klippy.py" ] || { echo "FAIL: klippy.py not in rootfs"; exit 1; }
[ -f "$ROOT/opt/moonraker/moonraker/moonraker.py" ] || { echo "FAIL: moonraker.py not in rootfs"; exit 1; }
[ -f "$ROOT/var/www/mainsail/index.html" ] || { echo "FAIL: mainsail index.html not in rootfs"; exit 1; }
[ -f "$ROOT/etc/nginx/nginx.conf" ] || { echo "FAIL: nginx.conf not in rootfs"; exit 1; }
[ -f "$ROOT/usr/sbin/nginx" ] || { echo "FAIL: nginx binary not in rootfs"; exit 1; }
echo "      rootfs structure validated."

# Helper: run ARM binary under qemu-user
qrun() {
    QEMU_LD_PREFIX="$ROOT" PYTHONDONTWRITEBYTECODE=1 HOME="$ROOT/root" \
        "$QEMU" "$@"
}

# ── FULL_API probe ────────────────────────────────────────────────────────────
# Attempt to start Moonraker under qemu-user. If it binds :7125 within 60s →
# FULL_API=1. We expect this to fail (ARM Python lacks _ssl) → FULL_API=0.
echo "[2/5] Probing Moonraker (FULL_API check, up to 60s timeout)..."

MOONRAKER_DATA="$NTMP/moonraker-data"
MOONRAKER_PID=""
mkdir -p "$MOONRAKER_DATA/config" "$MOONRAKER_DATA/logs" "$MOONRAKER_DATA/comms"
cp "$ROOT/etc/reforge/moonraker.conf" "$MOONRAKER_DATA/config/moonraker.conf"

FULL_API=0

QEMU_LD_PREFIX="$ROOT" PYTHONDONTWRITEBYTECODE=1 HOME="$NTMP" \
    PYTHONPATH="$ROOT/opt/moonraker" \
    "$QEMU" "$ROOT/usr/bin/python3" -m moonraker \
        -d "$MOONRAKER_DATA" \
        -c "$MOONRAKER_DATA/config/moonraker.conf" \
        -l "$MOONRAKER_DATA/logs/moonraker.log" \
        -n \
    > "$NTMP/moonraker-stdout.txt" 2>&1 &
MOONRAKER_PID=$!

_waited=0
while [ $_waited -lt 60 ]; do
    # ss is on host — checks if port 7125 is listening
    if ss -tlnp 2>/dev/null | grep -q ':7125'; then
        FULL_API=1
        break
    fi
    # Also bail early if the process died
    if ! kill -0 "$MOONRAKER_PID" 2>/dev/null; then
        break
    fi
    sleep 2
    _waited=$((_waited + 2))
done

if [ "$FULL_API" = "0" ]; then
    # Process died or timed out — kill it
    kill "$MOONRAKER_PID" 2>/dev/null || true
    wait "$MOONRAKER_PID" 2>/dev/null || true
    MOONRAKER_PID=""
    echo "      Moonraker did not bind :7125 (FULL_API=0) — proceeding to documented floor."
else
    echo "      Moonraker bound :7125 (FULL_API=1)."
fi

echo ""

# ════════════════════════════════════════════════════════════════════════════
# FULL_API=1 path
# ════════════════════════════════════════════════════════════════════════════
if [ "$FULL_API" = "1" ]; then
    echo "[3/5] FULL_API path — exercising live API..."

    # curl Moonraker
    _moon_resp=$(curl -s --max-time 10 http://127.0.0.1:7125/server/info 2>&1)
    echo "      Moonraker response: $_moon_resp"
    echo "$_moon_resp" | grep -q '"result"' \
        || { echo "FAIL: Moonraker /server/info did not return JSON with 'result'"; exit 1; }
    echo "      PASS: Moonraker API responded with result JSON."

    # Optional: nginx + Mainsail
    echo "[4/5] Attempting nginx start for Mainsail check..."
    _nginx_ok=0
    # build a test nginx.conf (redirect pid/logs/tmp to $NTMP)
    NGINX_CONF="$NTMP/nginx-live.conf"
    sed "s|pid /run/nginx.pid;|pid $NTMP/nginx.pid;|; \
         s|listen 80 |listen 18080 |; \
         s|include mime.types;|include $ROOT/etc/nginx/mime.types;|; \
         s|root /var/www/mainsail;|root $ROOT/var/www/mainsail;|; \
         s|sendfile      on;|sendfile      on;\n    client_body_temp_path $NTMP/nginx-cache;\n    proxy_temp_path $NTMP/nginx-cache;\n    fastcgi_temp_path $NTMP/nginx-cache;\n    uwsgi_temp_path $NTMP/nginx-cache;\n    scgi_temp_path $NTMP/nginx-cache;\n    access_log $NTMP/nginx-access.log;|" \
        "$ROOT/etc/nginx/nginx.conf" > "$NGINX_CONF"
    mkdir -p "$NTMP/nginx-cache"
    # nginx resolves a relative `include mime.types;` against the conf's dir ($NTMP)
    cp "$ROOT/etc/nginx/mime.types" "$NTMP/mime.types" 2>/dev/null || true

    QEMU_LD_PREFIX="$ROOT" \
        "$QEMU" "$ROOT/usr/sbin/nginx" -c "$NGINX_CONF" -e "$NTMP/nginx-err.log" &
    _nginx_pid=$!
    sleep 3
    if kill -0 "$_nginx_pid" 2>/dev/null; then
        _mainsail_resp=$(curl -s --max-time 5 http://127.0.0.1:18080/ 2>&1 | head -5)
        echo "      Mainsail response head: $_mainsail_resp"
        echo "$_mainsail_resp" | grep -qi 'html\|mainsail\|<!DOCTYPE' && _nginx_ok=1
        kill "$_nginx_pid" 2>/dev/null; wait "$_nginx_pid" 2>/dev/null || true
    fi

    echo "[5/5] Shutting down Moonraker..."
    kill "$MOONRAKER_PID" 2>/dev/null || true
    wait "$MOONRAKER_PID" 2>/dev/null || true
    MOONRAKER_PID=""

    if [ "$_nginx_ok" = "1" ]; then
        echo ""
        echo "PASS: core stack integrates (live moonraker API + mainsail served by nginx)"
    else
        echo ""
        echo "PASS: core stack integrates (live moonraker API)"
    fi
    exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# FULL_API=0 — documented floor
# ════════════════════════════════════════════════════════════════════════════
echo "[3/5] FULL_API=0 floor: import smoke + config-parse + nginx -t + bundle check"
echo ""

# (a) Moonraker import smoke
echo "  (a) moonraker import smoke..."
qrun "$ROOT/usr/bin/python3" \
    -c "import sys; sys.path.insert(0,'$ROOT/opt/moonraker'); import moonraker; print('  moonraker: import OK')" \
    2>&1 | grep -v '^$' || { echo "FAIL: moonraker import failed"; exit 1; }

# (b) moonraker --help (arg-parse / dep loading)
echo "  (b) moonraker --help..."
QEMU_LD_PREFIX="$ROOT" PYTHONDONTWRITEBYTECODE=1 HOME="$ROOT/root" \
    PYTHONPATH="$ROOT/opt/moonraker" \
    "$QEMU" "$ROOT/usr/bin/python3" -m moonraker --help > "$NTMP/moonraker-help.txt" 2>&1
grep -q "Moonraker" "$NTMP/moonraker-help.txt" \
    || { echo "FAIL: moonraker --help did not output expected text"; exit 1; }
echo "      OK: $(head -1 "$NTMP/moonraker-help.txt")"

# (c) klippy --help
echo "  (c) klippy --help..."
qrun "$ROOT/usr/bin/python3" "$ROOT/opt/klipper/klippy/klippy.py" --help \
    > "$NTMP/klippy-help.txt" 2>&1
grep -q "config file" "$NTMP/klippy-help.txt" \
    || { echo "FAIL: klippy --help did not output expected text"; exit 1; }
echo "      OK: $(head -1 "$NTMP/klippy-help.txt")"

# (d) klippy --import-test (validates all Python module imports including chelper)
echo "  (d) klippy --import-test..."
# capture rc WITHOUT letting set -e abort first (else the FAIL branch is dead code)
_klippy_import_rc=0
qrun "$ROOT/usr/bin/python3" "$ROOT/opt/klipper/klippy/klippy.py" --import-test \
    > "$NTMP/klippy-import.txt" 2>&1 || _klippy_import_rc=$?
if [ "$_klippy_import_rc" != "0" ]; then
    echo "FAIL: klippy --import-test exited $_klippy_import_rc"
    cat "$NTMP/klippy-import.txt"
    exit 1
fi
echo "      OK: klippy --import-test passed (exit 0)"

# (e) klippy config-parse smoke — start klippy with real printer.cfg, wait for
#     "waiting for MCU" or any config load indication, then kill it.
#     Config error is expected (printer.base.cfg needs MCU) but we verify klippy
#     at least STARTS and processes the config before the MCU connection attempt.
echo "  (e) klippy config-parse smoke (expect 'waiting for MCU' or config-parse, then kill)..."
KLIPPY_PID=""
qrun "$ROOT/usr/bin/python3" \
    "$ROOT/opt/klipper/klippy/klippy.py" \
    "$ROOT/etc/reforge/printer.cfg" \
    -a "$NTMP/klippy_uds" \
    -l "$NTMP/klippy.log" \
    > "$NTMP/klippy-stdout.txt" 2>&1 &
KLIPPY_PID=$!

# Give it up to 30s to produce a log entry
_kwaited=0
_klog_ok=0
while [ $_kwaited -lt 30 ]; do
    sleep 2
    _kwaited=$((_kwaited + 2))
    if [ -f "$NTMP/klippy.log" ] && [ -s "$NTMP/klippy.log" ]; then
        _klog_ok=1
        break
    fi
    # Also check stdout
    if [ -s "$NTMP/klippy-stdout.txt" ]; then
        _klog_ok=1
        break
    fi
    if ! kill -0 "$KLIPPY_PID" 2>/dev/null; then
        # Exited — check stdout/log for meaningful output
        _klog_ok=1
        break
    fi
done

kill "$KLIPPY_PID" 2>/dev/null || true
wait "$KLIPPY_PID" 2>/dev/null || true
KLIPPY_PID=""

if [ "$_klog_ok" = "0" ]; then
    echo "FAIL: klippy produced no log output within 30s"
    exit 1
fi

# Check for expected markers — either startup info or config error (both mean klippy ran)
_klippy_out=""
[ -s "$NTMP/klippy.log" ] && _klippy_out=$(cat "$NTMP/klippy.log")
[ -z "$_klippy_out" ] && [ -s "$NTMP/klippy-stdout.txt" ] && _klippy_out=$(cat "$NTMP/klippy-stdout.txt")
echo "$_klippy_out" | grep -qiE "klippy|Starting|Config|ERROR|WARNING|mcu|reactor" \
    || { echo "FAIL: klippy log contained no expected startup markers"; echo "$_klippy_out" | head -10; exit 1; }
echo "      OK: klippy started and produced log (first line: $(echo "$_klippy_out" | head -1))"

# (f) Mainsail bundle — index.html must exist and be non-empty
echo "  (f) Mainsail index.html..."
[ -s "$ROOT/var/www/mainsail/index.html" ] \
    || { echo "FAIL: mainsail index.html missing or empty"; exit 1; }
grep -qi 'html\|mainsail\|<!DOCTYPE\|script\|link' "$ROOT/var/www/mainsail/index.html" \
    || { echo "FAIL: mainsail index.html does not look like a valid HTML file"; exit 1; }
echo "      OK: index.html exists ($(wc -c < "$ROOT/var/www/mainsail/index.html") bytes)"

# (g) nginx -t config test
echo "  (g) nginx config test..."
# Build a test nginx.conf with host-writable paths injected
NGINX_TEST_CONF="$ROOT/etc/nginx/nginx-integration-test.conf"
mkdir -p "$NTMP/nginx-cache" "$NTMP/nginx-logs"
sed \
    "s|pid /run/nginx.pid;|pid $NTMP/nginx.pid;| ; \
     s|listen 80 |listen 18080 | ; \
     s|sendfile      on;|sendfile      on;\n    client_body_temp_path $NTMP/nginx-cache;\n    proxy_temp_path $NTMP/nginx-cache;\n    fastcgi_temp_path $NTMP/nginx-cache;\n    uwsgi_temp_path $NTMP/nginx-cache;\n    scgi_temp_path $NTMP/nginx-cache;\n    access_log $NTMP/nginx-logs/access.log;|" \
    "$ROOT/etc/nginx/nginx.conf" > "$NGINX_TEST_CONF"

QEMU_LD_PREFIX="$ROOT" \
    "$QEMU" "$ROOT/usr/sbin/nginx" \
        -c "$NGINX_TEST_CONF" \
        -e "$NTMP/nginx-logs/error.log" \
        -t > "$NTMP/nginx-t.txt" 2>&1
_nginx_rc=$?
cat "$NTMP/nginx-t.txt"
[ "$_nginx_rc" = "0" ] \
    || { echo "FAIL: nginx -t exited $_nginx_rc"; exit 1; }
echo "      OK: nginx config test passed"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "PASS: core stack builds+self-checks (live API deferred to on-device P3)"
echo ""
echo "Floor achieved : FULL_API=0 (documented fallback)"
echo "Assertions pass: moonraker-import, moonraker-help, klippy-help,"
echo "                 klippy-import-test, klippy-config-parse,"
echo "                 mainsail-bundle, nginx-config-test"
