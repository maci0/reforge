#!/bin/sh
# dinit-services-test.sh — structural validator for the staged dinit service
# descriptions (br-external/.../rootfs-overlay/etc/dinit.d/).
#
# Host-runnable (no ARM dinit-check needed): checks that every service file has
# the required keys, and that every depends-on / waits-for target resolves to an
# existing service file (no dangling dependency). Includes a negative case so
# the linter itself is exercised against a malformed service.
#
# Exit 0 = PASS, 1 = FAIL.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DINITD="${REPO_ROOT}/br-external/board/reforge/rootfs-overlay/etc/dinit.d"

fail() { echo "[dinit-test] FAIL: $*" >&2; exit 1; }
pass() { echo "[dinit-test]   [PASS] $*"; }

# get_keys <file> <key> -> values of every "key = value" line
get_vals() { grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | sed -E "s/^[^=]*=[[:space:]]*//"; }

# lint_service <file> <service-dir> : validate one service file. Echoes nothing
# on success; calls fail() on the first problem.
lint_service() {
    _f="$1"; _dir="$2"; _name="$(basename "$_f")"
    [ "$_name" = "README.md" ] && return 0

    _type="$(get_vals "$_f" type | head -n1)"
    [ -n "$_type" ] || fail "$_name: missing 'type ='"
    case "$_type" in
        process|bgprocess|scripted|internal) : ;;
        *) fail "$_name: invalid type '$_type'" ;;
    esac

    case "$_type" in
        process|bgprocess|scripted)
            [ -n "$(get_vals "$_f" command | head -n1)" ] \
                || fail "$_name: type=$_type needs a 'command ='" ;;
    esac

    # every depends-on / waits-for target must be an existing service file
    for _rel in depends-on waits-for; do
        for _dep in $(get_vals "$_f" "$_rel"); do
            [ -f "${_dir}/${_dep}" ] \
                || fail "$_name: $_rel '$_dep' has no service file in ${_dir}"
        done
    done
    return 0
}

[ -d "$DINITD" ] || fail "service dir not found: $DINITD"

# --- 1. expected service set is present ---
for s in boot prepare cloudblock zram eboard klipper moonraker httpd camera guppyscreen ok; do
    [ -f "${DINITD}/${s}" ] || fail "missing expected service '${s}'"
done
pass "all 11 expected service files present"

# --- 2. lint every real service ---
for f in "${DINITD}"/*; do
    lint_service "$f" "${DINITD}"
done
pass "all service files lint clean (keys + no dangling deps)"

# --- 3. boot target pulls in the core daemons ---
_bootdeps="$(get_vals "${DINITD}/boot" depends-on | tr '\n' ' ')"
for d in klipper moonraker httpd ok; do
    case " ${_bootdeps} " in *" ${d} "*) : ;; *) fail "boot target missing depends-on ${d}" ;; esac
done
pass "boot target depends on klipper/moonraker/httpd/ok"

# --- 4. negative case: a malformed service must be rejected by the linter ---
_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT
# (a) dangling dependency
printf 'type = process\ncommand = /bin/true\ndepends-on = nonexistent\n' > "${_tmp}/bad1"
if ( lint_service "${_tmp}/bad1" "${_tmp}" ) 2>/dev/null; then
    fail "linter accepted a dangling depends-on (should reject)"
fi
# (b) missing type
printf 'command = /bin/true\n' > "${_tmp}/bad2"
if ( lint_service "${_tmp}/bad2" "${_tmp}" ) 2>/dev/null; then
    fail "linter accepted a service with no type (should reject)"
fi
# (c) process with no command
printf 'type = process\n' > "${_tmp}/bad3"
if ( lint_service "${_tmp}/bad3" "${_tmp}" ) 2>/dev/null; then
    fail "linter accepted a process with no command (should reject)"
fi
pass "linter rejects malformed services (dangling dep / no type / no command)"

echo "[dinit-test] PASS: dinit service descriptions are well-formed."
