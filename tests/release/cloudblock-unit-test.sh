#!/usr/bin/env bash
# tests/release/cloudblock-unit-test.sh
#
# Host unit + fuzz test for S00cloudblock (no qemu, no root). Exercises the
# block_cloud rework ported from DrA1ex/ff5m PR #65:
#
#   - BLOCK_CLOUD default ON (no config) adds every host once, marker-tagged
#   - re-running is idempotent (no duplicate marked entries)
#   - BLOCK_CLOUD=0 removes ONLY our marked entries; user-added 127.0.0.1 lines
#     and unrelated lines (localhost) survive
#   - BLOCK_CLOUD=1 again re-adds, user entries still intact
#   - a user pre-block of one of our hosts (no marker) is not double-inserted
#     (awk literal field match sees the existing line)
#   - FUZZ: random starting /etc/hosts + random enable/disable sequences keep
#     the invariants (user lines never lost, marked hosts unique, disable clears
#     all markers, enable covers all hosts)
#
# The script hardcodes /etc/hosts and /config/screen.conf; the test rewrites
# those to a scratch dir with sed (no production code change needed).
#
# Exit 0 = PASS, 1 = FAIL.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${REPO_ROOT}/br-external/board/reforge/rootfs-overlay/etc/init.d/S00cloudblock"

FAILS=0
pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILS=$((FAILS + 1)); }

[ -f "${SRC}" ] || { echo "[FAIL] S00cloudblock not found at ${SRC}"; exit 1; }

# Number of hosts the script blocks (parsed from the BLOCKED_HOSTS heredoc body,
# so the test never hardcodes the count).
NHOSTS="$(awk '/^BLOCKED_HOSTS="/{f=1;next} /^"/{f=0} f && NF{c++} END{print c}' "${SRC}")"
HOSTS_LIST="$(awk '/^BLOCKED_HOSTS="/{f=1;next} /^"/{f=0} f && NF{print $1}' "${SRC}")"
[ "${NHOSTS}" -gt 0 ] 2>/dev/null && pass "parsed ${NHOSTS} blocked hosts from script" \
    || { fail "could not parse BLOCKED_HOSTS"; echo "FAIL"; exit 1; }

# Build a scratch-pathed copy of the script: CONF -> $W/screen.conf, /etc/hosts -> $W/hosts.
make_cb() {  # $1 = workdir -> prints path to runnable script
    W="$1"
    sed "s#CONF=/config/screen.conf#CONF=${W}/screen.conf#; s#/etc/hosts#${W}/hosts#g" \
        "${SRC}" > "${W}/cb.sh"
    chmod +x "${W}/cb.sh"
    echo "${W}/cb.sh"
}
set_toggle() { # $1 workdir, $2 value ("" = remove config)
    if [ -z "$2" ]; then rm -f "$1/screen.conf"; else printf 'BLOCK_CLOUD=%s\n' "$2" > "$1/screen.conf"; fi
}
# grep -c prints "0" AND exits 1 on no match, so a `|| echo 0` would double it;
# capture and default instead.
marked_count() { local c; c="$(grep -c '# block_cloud' "$1/hosts" 2>/dev/null)"; echo "${c:-0}"; }
host_lines()   { local c; c="$(grep -cE "[[:space:]]$2([[:space:]]|\$)" "$1/hosts" 2>/dev/null)"; echo "${c:-0}"; }

# --- deterministic checks ---------------------------------------------------
W="$(mktemp -d)"; CB="$(make_cb "${W}")"
printf '127.0.0.1 localhost\n::1 localhost\n' > "${W}/hosts"

set_toggle "${W}" ""           # no config -> default ON
"${CB}" start >/dev/null
[ "$(marked_count "${W}")" -eq "${NHOSTS}" ] && pass "default ON added ${NHOSTS} marked entries" \
    || fail "default ON: marked=$(marked_count "${W}") expected ${NHOSTS}"

"${CB}" start >/dev/null        # idempotent
[ "$(marked_count "${W}")" -eq "${NHOSTS}" ] && pass "re-run idempotent (still ${NHOSTS})" \
    || fail "re-run not idempotent: marked=$(marked_count "${W}")"

printf '127.0.0.1 my-own-tracker.example\n' >> "${W}/hosts"   # user entry, no marker
set_toggle "${W}" 0
"${CB}" start >/dev/null
[ "$(marked_count "${W}")" -eq 0 ] && pass "BLOCK_CLOUD=0 removed all marked entries" \
    || fail "disable left $(marked_count "${W}") marked entries"
[ "$(host_lines "${W}" my-own-tracker.example)" -eq 1 ] && pass "user entry survived disable" \
    || fail "user entry lost on disable"
[ "$(grep -c localhost "${W}/hosts")" -eq 2 ] && pass "localhost lines untouched" \
    || fail "localhost lines disturbed"

set_toggle "${W}" 1
"${CB}" start >/dev/null
[ "$(marked_count "${W}")" -eq "${NHOSTS}" ] && pass "re-enable re-added ${NHOSTS}" \
    || fail "re-enable: marked=$(marked_count "${W}")"
[ "$(host_lines "${W}" my-own-tracker.example)" -eq 1 ] && pass "user entry intact after re-enable" \
    || fail "user entry lost on re-enable"

# user pre-blocked one of OUR hosts WITHOUT a marker -> no triple line
FIRST_HOST="$(printf '%s\n' ${HOSTS_LIST} | head -n1)"
printf '127.0.0.1 %s\n' "${FIRST_HOST}" >> "${W}/hosts"
"${CB}" start >/dev/null
[ "$(host_lines "${W}" "${FIRST_HOST}")" -eq 2 ] && pass "no double-insert when user pre-blocked ${FIRST_HOST}" \
    || fail "${FIRST_HOST} has $(host_lines "${W}" "${FIRST_HOST}") lines (expected 2: ours+user)"
rm -rf "${W}"

# --- fuzz -------------------------------------------------------------------
# Random starting hosts + random toggle sequences; the mod must NEVER drop a
# user line, never duplicate a marked host, fully clear markers when disabled,
# and cover every host when enabled.
FUZZ_N="${FUZZ_N:-200}"
fuzz_fails=0
i=0
while [ "${i}" -lt "${FUZZ_N}" ]; do
    i=$((i + 1))
    W="$(mktemp -d)"; CB="$(make_cb "${W}")"
    : > "${W}/hosts"
    # seed with a random number of unique user lines (marker-free)
    users=""
    nu=$(( RANDOM % 4 ))
    j=0
    while [ "${j}" -lt "${nu}" ]; do
        j=$((j + 1))
        u="user${i}_${j}.example"
        users="${users} ${u}"
        printf '127.0.0.1 %s\n' "${u}" >> "${W}/hosts"
    done
    # maybe a user pre-block of a real host (unmarked) + always localhost
    printf '127.0.0.1 localhost\n' >> "${W}/hosts"
    if [ $(( RANDOM % 2 )) -eq 0 ]; then
        printf '127.0.0.1 %s\n' "${FIRST_HOST}" >> "${W}/hosts"
    fi
    # random toggle sequence of length 1..5
    seqlen=$(( RANDOM % 5 + 1 ))
    last=1
    k=0
    while [ "${k}" -lt "${seqlen}" ]; do
        k=$((k + 1))
        last=$(( RANDOM % 2 ))
        set_toggle "${W}" "${last}"
        "${CB}" start >/dev/null 2>&1
    done
    # invariant 1: every seeded user line still present exactly once
    for u in ${users}; do
        [ "$(host_lines "${W}" "${u}")" -eq 1 ] || { fuzz_fails=$((fuzz_fails+1)); echo "  fuzz#${i}: user ${u} lost"; break; }
    done
    # invariant 2: no host is marked more than once
    dupe="$(grep '# block_cloud' "${W}/hosts" | awk '{print $2}' | sort | uniq -d)"
    [ -z "${dupe}" ] || { fuzz_fails=$((fuzz_fails+1)); echo "  fuzz#${i}: duplicate marked host ${dupe}"; }
    # invariant 3: final state matches last toggle.
    m="$(marked_count "${W}")"
    if [ "${last}" -eq 1 ]; then
        # enabled: every host COVERED by >=1 line (ours marked, or a user's
        # pre-existing unmarked block we correctly didn't duplicate — so the
        # marked count may be < NHOSTS, which is fine; coverage is the invariant).
        for h in ${HOSTS_LIST}; do
            [ "$(host_lines "${W}" "${h}")" -ge 1 ] || { fuzz_fails=$((fuzz_fails+1)); echo "  fuzz#${i}: host ${h} not covered when enabled"; break; }
        done
    else
        # disabled: none of OUR markers remain (user pre-blocks may persist).
        [ "${m}" -eq 0 ] || { fuzz_fails=$((fuzz_fails+1)); echo "  fuzz#${i}: disabled but marked=${m}"; }
    fi
    rm -rf "${W}"
done
[ "${fuzz_fails}" -eq 0 ] && pass "fuzz: ${FUZZ_N} random hosts/toggle sequences held all invariants" \
    || fail "fuzz: ${fuzz_fails} invariant violation(s) across ${FUZZ_N} runs"

echo ""
if [ "${FAILS}" -eq 0 ]; then
    echo "PASS: S00cloudblock block_cloud toggle + marker logic verified"
    exit 0
else
    echo "FAIL: ${FAILS} assertion(s) failed"
    exit 1
fi
