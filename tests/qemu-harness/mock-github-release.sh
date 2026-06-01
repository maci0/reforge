#!/usr/bin/env bash
# =============================================================================
# mock-github-release.sh — offline stand-in for GitHub's releases API (HTTPS).
#
# OTA e2e tests must run without reaching the real github.com. This serves a
# tiny TLS endpoint that a qemu guest hits after the test (a) injects the CA
# printed below into the guest trust store and (b) points api.github.com +
# objects.githubusercontent.com at the qemu host gateway (10.0.2.2) via
# /etc/hosts. Moonraker's update_manager then talks to this mock instead.
#
# Routes:
#   GET /repos/maci0/reforge/releases/latest
#       -> {tag_name, assets:[{name, browser_download_url}]}, generated from
#          whatever *.zip files live in DIST_DIR (never a hardcoded list).
#   GET /assets/<name>
#       -> the raw bytes of DIST_DIR/<name> (the per-component OTA zip).
#
# Usage:
#   mock-github-release.sh                 # run the server (foreground)
#   mock-github-release.sh --self-test     # start, exercise, assert, exit 0/1
#   mock-github-release.sh --print-ca      # print the CA/cert path and exit
#
# Env:
#   DIST_DIR  dir of OTA zips to serve   (default: packaging/dist)
#   PORT      HTTPS listen port          (default: 8443)
#   TAG       release tag_name to report (default: contents of packaging/VERSION
#             prefixed with 'v', else 'v0.0.0-mock')
#   CERT_DIR  where the self-signed cert/key live (default: <harness>/build)
#
# The server is HTTPS only: Moonraker validates TLS, so plain http would fail.
# A self-signed cert covering SANs api.github.com + objects.githubusercontent.com
# is generated on first run (and reused thereafter). Because it is self-signed,
# the cert IS its own CA — the printed path can be dropped straight into the
# guest's trust store.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"

DIST_DIR="${DIST_DIR:-${REPO_ROOT}/packaging/dist}"
PORT="${PORT:-8443}"
CERT_DIR="${CERT_DIR:-${BUILD_DIR}}"
CERT="${CERT_DIR}/mock-github-cert.pem"
KEY="${CERT_DIR}/mock-github-key.pem"

# Default tag from packaging/VERSION when present.
if [ -z "${TAG:-}" ]; then
    if [ -f "${REPO_ROOT}/packaging/VERSION" ]; then
        TAG="v$(cat "${REPO_ROOT}/packaging/VERSION")"
    else
        TAG="v0.0.0-mock"
    fi
fi

log()  { echo "[mock-github] $*"; }
die()  { echo "[mock-github] ERROR: $*" >&2; exit 1; }

# Cleanup state, kept script-global so the EXIT trap can always reach it
# (a function-local would be out of scope by the time the trap fires).
SRV_PID=""
SELFTEST_TMP=""

# Reap the python server and any scratch dir on exit — no orphans, ever.
# shellcheck disable=SC2317  # invoked via trap, not statically reachable
cleanup() {
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && wait "${SRV_PID}" 2>/dev/null || true
    [ -n "${SELFTEST_TMP}" ] && rm -rf "${SELFTEST_TMP}"
    return 0
}
trap cleanup EXIT INT TERM

command -v python3 >/dev/null 2>&1 || die "python3 not installed"
command -v openssl >/dev/null 2>&1 || die "openssl not installed"

# ---------------------------------------------------------------------------
# ensure_cert — generate a self-signed cert/key (SANs: the two github hosts)
#   if either file is missing. Idempotent; reuses an existing pair.
# ---------------------------------------------------------------------------
ensure_cert() {
    if [ -f "${CERT}" ] && [ -f "${KEY}" ]; then
        return 0
    fi
    mkdir -p "${CERT_DIR}"
    log "generating self-signed cert (SAN: api.github.com, objects.githubusercontent.com)"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "${KEY}" -out "${CERT}" \
        -subj "/CN=api.github.com" \
        -addext "subjectAltName=DNS:api.github.com,DNS:objects.githubusercontent.com,DNS:localhost,IP:127.0.0.1" \
        >/dev/null 2>&1 \
        || die "openssl cert generation failed"
    chmod 600 "${KEY}"
}

# ---------------------------------------------------------------------------
# The python server. Reads DIST_DIR / PORT / TAG / CERT / KEY from the env so
# the bash wrapper stays the single source of truth for configuration.
# ---------------------------------------------------------------------------
run_server() {
    # exec so that when this function is backgrounded ('run_server &'), the job
    # PID ($!) is python itself — not a wrapping subshell. Killing $! then
    # actually stops the server (a subshell kill would orphan the python child).
    DIST_DIR="${DIST_DIR}" PORT="${PORT}" TAG="${TAG}" \
    CERT="${CERT}" KEY="${KEY}" \
    exec python3 - <<'PYEOF'
import json
import os
import ssl
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

DIST_DIR = os.path.abspath(os.environ["DIST_DIR"])
PORT = int(os.environ["PORT"])
TAG = os.environ["TAG"]
CERT = os.environ["CERT"]
KEY = os.environ["KEY"]

# Hosts the qemu guest resolves to the host gateway via /etc/hosts. The asset
# URLs we hand back must point at this mock, reachable as api.github.com.
PUBLIC_HOST = os.environ.get("PUBLIC_HOST", "api.github.com")


def list_zips():
    """Every *.zip currently in DIST_DIR (sorted, names only)."""
    if not os.path.isdir(DIST_DIR):
        return []
    return sorted(
        n for n in os.listdir(DIST_DIR)
        if n.endswith(".zip") and os.path.isfile(os.path.join(DIST_DIR, n))
    )


def releases_latest():
    """The releases/latest JSON, built live from DIST_DIR's zips."""
    assets = [
        {
            "name": name,
            "browser_download_url":
                "https://%s:%d/assets/%s" % (PUBLIC_HOST, PORT, name),
        }
        for name in list_zips()
    ]
    return {"tag_name": TAG, "assets": assets}


def safe_asset_path(name):
    """Resolve DIST_DIR/<name>, refusing anything that escapes DIST_DIR.

    Returns an absolute path inside DIST_DIR or None (traversal / not a file).
    """
    # A leading basename strip kills the obvious '../' tricks; the realpath
    # prefix check is the real guard (also catches symlinks).
    if not name or "/" in name or "\\" in name or name in (".", ".."):
        return None
    candidate = os.path.realpath(os.path.join(DIST_DIR, name))
    root = os.path.realpath(DIST_DIR)
    if candidate != root and not candidate.startswith(root + os.sep):
        return None
    if not os.path.isfile(candidate):
        return None
    return candidate


class Handler(BaseHTTPRequestHandler):
    # Quiet logs unless we are debugging the mock itself.
    def log_message(self, fmt, *args):
        if os.environ.get("MOCK_VERBOSE"):
            sys.stderr.write("[mock-github] " + (fmt % args) + "\n")

    def _send_json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_404(self):
        body = b'{"message":"Not Found"}'
        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # Strip any query string; route on the bare path only.
        path = self.path.split("?", 1)[0]

        if path == "/repos/maci0/reforge/releases/latest":
            self._send_json(releases_latest())
            return

        if path.startswith("/assets/"):
            name = path[len("/assets/"):]
            target = safe_asset_path(name)
            if target is None:
                self._send_404()
                return
            size = os.path.getsize(target)
            self.send_response(200)
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with open(target, "rb") as fh:
                while True:
                    chunk = fh.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            return

        self._send_404()


def main():
    httpd = HTTPServer(("0.0.0.0", PORT), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=CERT, keyfile=KEY)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    sys.stderr.write(
        "[mock-github] serving HTTPS on :%d  (DIST_DIR=%s, tag=%s)\n"
        % (PORT, DIST_DIR, TAG)
    )
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


main()
PYEOF
}

# ---------------------------------------------------------------------------
# self_test — happy path + malformed/traversal fuzz, on a throwaway DIST_DIR
#   when packaging/dist has no zips, so it runs without a full build.
# ---------------------------------------------------------------------------
self_test() {
    command -v curl >/dev/null 2>&1 || die "curl required for --self-test"
    command -v zip  >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 \
        || die "need zip or python3 to build the self-test fixture"

    local tmp original_dist
    tmp="$(mktemp -d)"
    SELFTEST_TMP="${tmp}"
    original_dist="${DIST_DIR}"

    # If the real DIST_DIR has no zips, fabricate a throwaway one so the test is
    # self-contained. Otherwise exercise the real dist so we test real assets.
    if ! ls "${DIST_DIR}"/*.zip >/dev/null 2>&1; then
        log "no zips in ${DIST_DIR}; building a throwaway DIST_DIR for the self-test"
        DIST_DIR="${tmp}/dist"
        mkdir -p "${DIST_DIR}"
        echo "dummy klipper payload" > "${tmp}/release_info.json"
        if command -v zip >/dev/null 2>&1; then
            ( cd "${tmp}" && zip -q "${DIST_DIR}/klipper.zip" release_info.json )
            ( cd "${tmp}" && zip -q "${DIST_DIR}/reforge.zip" release_info.json )
        else
            python3 -c "import zipfile,sys;[zipfile.ZipFile(sys.argv[1],'w').writestr('release_info.json','x') for _ in (0,)]" "${DIST_DIR}/klipper.zip"
            python3 -c "import zipfile,sys;[zipfile.ZipFile(sys.argv[1],'w').writestr('release_info.json','x') for _ in (0,)]" "${DIST_DIR}/reforge.zip"
        fi
    fi

    ensure_cert

    # Launch the server in the background on the (possibly throwaway) DIST_DIR.
    DIST_DIR="${DIST_DIR}" PORT="${PORT}" TAG="${TAG}" \
    CERT="${CERT}" KEY="${KEY}" run_server &
    SRV_PID=$!

    # Wait for the listener to come up.
    local base="https://127.0.0.1:${PORT}"
    local up=0 _i
    # shellcheck disable=SC2034  # _i is just a retry counter, intentionally unused
    for _i in $(seq 1 50); do
        if curl -sS --cacert "${CERT}" "${base}/repos/maci0/reforge/releases/latest" \
            >/dev/null 2>&1; then
            up=1
            break
        fi
        sleep 0.2
    done
    [ "${up}" -eq 1 ] || die "server did not come up on :${PORT}"

    local fails=0

    # --- happy path: releases/latest is valid JSON with tag_name + assets ----
    local json
    json="$(curl -sS --cacert "${CERT}" "${base}/repos/maci0/reforge/releases/latest")"
    if python3 - "$json" <<'PYCHK'
import json, sys
d = json.loads(sys.argv[1])
assert isinstance(d.get("tag_name"), str) and d["tag_name"], "tag_name missing"
assert isinstance(d.get("assets"), list) and d["assets"], "assets missing/empty"
for a in d["assets"]:
    assert a.get("name", "").endswith(".zip"), "asset name not a zip"
    assert a.get("browser_download_url", "").startswith("https://"), "bad url"
PYCHK
    then
        log "PASS  releases/latest -> tag_name + assets[]"
    else
        log "FAIL  releases/latest JSON invalid"
        fails=$((fails + 1))
    fi

    # --- happy path: an advertised asset downloads and is a real zip ---------
    local first_asset out
    first_asset="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["assets"][0]["name"])' "$json")"
    out="${tmp}/got.zip"
    if curl -sS --cacert "${CERT}" "${base}/assets/${first_asset}" -o "${out}" \
        && [ -s "${out}" ] \
        && python3 -c 'import zipfile,sys;sys.exit(0 if zipfile.is_zipfile(sys.argv[1]) else 1)' "${out}"; then
        log "PASS  /assets/${first_asset} -> valid zip ($(wc -c < "${out}") bytes)"
    else
        log "FAIL  /assets/${first_asset} did not return a valid zip"
        fails=$((fails + 1))
    fi

    # --- fuzz: malformed / traversal paths must all 404 (never 500, no escape)
    local bad code
    for bad in \
        "/" \
        "/repos/x" \
        "/repos/maci0/reforge/releases" \
        "/assets/" \
        "/assets/does-not-exist.zip" \
        "/assets/../etc/passwd" \
        "/assets/..%2f..%2fetc%2fpasswd" \
        "/assets/klipper.zip/../../../etc/passwd" \
        "/repos/maci0/reforge/releases/latest/extra" \
        "/random?q=$(printf '%s' 'a&b=../../x')" \
        "/assets/%00" ; do
        code="$(curl -sS --cacert "${CERT}" -o /dev/null -w '%{http_code}' "${base}${bad}" 2>/dev/null || echo 000)"
        if [ "${code}" = "404" ]; then
            log "PASS  fuzz ${bad} -> 404"
        else
            log "FAIL  fuzz ${bad} -> ${code} (expected 404)"
            fails=$((fails + 1))
        fi
    done

    # The query string on a KNOWN route must still resolve (route on bare path).
    code="$(curl -sS --cacert "${CERT}" -o /dev/null -w '%{http_code}' \
        "${base}/repos/maci0/reforge/releases/latest?foo=bar&x=1" 2>/dev/null || echo 000)"
    if [ "${code}" = "200" ]; then
        log "PASS  releases/latest?query -> 200"
    else
        log "FAIL  releases/latest?query -> ${code} (expected 200)"
        fails=$((fails + 1))
    fi

    DIST_DIR="${original_dist}"
    if [ "${fails}" -eq 0 ]; then
        log "SELF-TEST PASS"
        return 0
    fi
    log "SELF-TEST FAIL (${fails} failing check(s))"
    return 1
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    --self-test)
        self_test
        ;;
    --print-ca)
        ensure_cert
        # The self-signed cert is its own CA: feed THIS path to the guest trust
        # store and TLS validation against api.github.com will pass.
        echo "${CERT}"
        ;;
    -h|--help)
        sed -n '/^# Usage:/,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    "")
        ensure_cert
        log "CA/cert   : ${CERT}"
        log "key       : ${KEY}"
        log "listen    : https://0.0.0.0:${PORT}"
        log "DIST_DIR  : ${DIST_DIR}"
        log "tag_name  : ${TAG}"
        log "inject ${CERT} into the guest trust store; /etc/hosts: 10.0.2.2 api.github.com objects.githubusercontent.com"
        # The global EXIT trap reaps the server; just track its pid here.
        run_server &
        SRV_PID=$!
        wait "${SRV_PID}"
        ;;
    *)
        die "unknown argument: $1  (try --help)"
        ;;
esac
