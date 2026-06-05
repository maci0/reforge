#!/usr/bin/env bash
# tests/release/lkg-unit-test.sh
#
# Task 4 host unit test for reforge-lkg.sh (no qemu, no root).  Exercises the
# trial / last-known-good helpers against a scratch DATA root:
#
#   - is_trial TRUE  when mod(v2) != lkg(v1)
#   - is_trial FALSE when lkg is ABSENT (fresh device / first-boot guard, S4)
#   - is_trial FALSE when versions match
#   - lkg_counter_get/inc/reset semantics
#   - lkg_restore swaps mod <- lkg (and stashes mod.bad), resets counter
#   - lkg_promote equalizes versions + resets counter
#   - counter writes are ATOMIC (no leftover *.tmp.* partial files)
#   - sourcing the script has NO side effects (creates no dirs/files)
#
# Exit 0 = PASS, 1 = FAIL.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LKG_SH="${REPO_ROOT}/br-external/board/reforge/rootfs-overlay/.shell/reforge-lkg.sh"

FAILS=0
pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILS=$((FAILS + 1)); }

if [ ! -f "${LKG_SH}" ]; then
    echo "[FAIL] reforge-lkg.sh not found at ${LKG_SH}"
    exit 1
fi

# sh -n syntax check
sh -n "${LKG_SH}" && pass "reforge-lkg.sh: sh -n clean" || fail "reforge-lkg.sh: sh -n"

# ---------------------------------------------------------------------------
# Helper to build a scratch DATA with a mod (ver $1) and optionally lkg (ver $2).
# Echoes the DATA root.
# ---------------------------------------------------------------------------
make_data() {
    _d="$(mktemp -d /tmp/reforge-lkg-XXXXXX)"
    mkdir -p "${_d}/.mod/.reforge/mod"
    _write_ri "${_d}/.mod/.reforge/mod" "$1"
    if [ -n "${2:-}" ]; then
        mkdir -p "${_d}/.mod/.reforge/lkg"
        _write_ri "${_d}/.mod/.reforge/lkg" "$2"
    fi
    echo "${_d}"
}
_write_ri() {
    cat > "$1/release_info.json" <<EOF
{
  "project_name": "reforge",
  "project_owner": "maci0",
  "version": "$2",
  "asset_name": "reforge.zip"
}
EOF
}

# Run a snippet with reforge-lkg.sh sourced against a given DATA root.
# Usage: run_lkg <DATA> <shell-snippet>
run_lkg() {
    REFORGE_DATA_ROOT="$1" sh -c ". '${LKG_SH}'; $2"
}

# ===========================================================================
# 0. Sourcing has NO side effects (no state dir / counter created on source).
# ===========================================================================
D="$(make_data 2.0.0 1.0.0)"
run_lkg "${D}" ':'
if [ -e "${D}/.mod/.reforge/state" ]; then
    fail "sourcing reforge-lkg.sh created state dir (side effect)"
else
    pass "sourcing reforge-lkg.sh has no side effects"
fi
rm -rf "${D}"

# ===========================================================================
# 1. is_trial TRUE when mod(v2) != lkg(v1)
# ===========================================================================
D="$(make_data 2.0.0 1.0.0)"
if run_lkg "${D}" 'is_trial'; then
    pass "is_trial TRUE when mod != lkg version"
else
    fail "is_trial should be TRUE when mod(2.0.0) != lkg(1.0.0)"
fi

# mod_version reads the right value
MV="$(run_lkg "${D}" 'mod_version "$MOD"')"
[ "${MV}" = "2.0.0" ] && pass "mod_version reads version (2.0.0)" \
    || fail "mod_version returned '${MV}' (expected 2.0.0)"
rm -rf "${D}"

# ===========================================================================
# 2. is_trial FALSE when lkg is ABSENT (fresh-device first-boot guard, S4)
# ===========================================================================
D="$(make_data 2.0.0 "")"   # no lkg
if run_lkg "${D}" 'is_trial'; then
    fail "is_trial should be FALSE when lkg is absent (fresh device)"
else
    pass "is_trial FALSE when lkg absent (fresh-device guard)"
fi
# And a fresh boot must NOT increment any counter implicitly.
[ ! -e "${D}/.mod/.reforge/state/trial.count" ] \
    && pass "no counter created on fresh (no-lkg) boot" \
    || fail "counter created on fresh boot"
rm -rf "${D}"

# ===========================================================================
# 3. is_trial FALSE when versions match
# ===========================================================================
D="$(make_data 1.0.0 1.0.0)"
if run_lkg "${D}" 'is_trial'; then
    fail "is_trial should be FALSE when versions match"
else
    pass "is_trial FALSE when mod version == lkg version"
fi
rm -rf "${D}"

# ===========================================================================
# 4. Counter get/inc/reset
# ===========================================================================
D="$(make_data 2.0.0 1.0.0)"
C0="$(run_lkg "${D}" 'lkg_counter_get')"
[ "${C0}" = "0" ] && pass "counter defaults to 0" || fail "counter default '${C0}' != 0"

run_lkg "${D}" 'lkg_counter_inc'
run_lkg "${D}" 'lkg_counter_inc'
run_lkg "${D}" 'lkg_counter_inc'
C3="$(run_lkg "${D}" 'lkg_counter_get')"
[ "${C3}" = "3" ] && pass "counter inc x3 => 3" || fail "counter after 3 incs = '${C3}' (expected 3)"

run_lkg "${D}" 'lkg_counter_reset'
CR="$(run_lkg "${D}" 'lkg_counter_get')"
[ "${CR}" = "0" ] && pass "counter reset => 0" || fail "counter after reset = '${CR}' (expected 0)"

# ---- atomicity: no leftover temp files after writes ----
if ls "${D}/.mod/.reforge/state/"*.tmp.* >/dev/null 2>&1; then
    fail "atomic-write left a partial temp file in state dir"
else
    pass "atomic-write left no partial temp files"
fi
# The counter file contains exactly the value, nothing partial.
RAW="$(cat "${D}/.mod/.reforge/state/trial.count")"
[ "${RAW}" = "0" ] && pass "counter file holds exact value (no garbage)" \
    || fail "counter file holds '${RAW}'"
rm -rf "${D}"

# ===========================================================================
# 5. Trial cycle: inc x3 then lkg_restore swaps mod <- lkg and resets counter
# ===========================================================================
D="$(make_data 2.0.0 1.0.0)"
run_lkg "${D}" 'lkg_counter_inc; lkg_counter_inc; lkg_counter_inc'
[ "$(run_lkg "${D}" 'lkg_counter_get')" = "3" ] \
    && pass "pre-restore counter = 3" || fail "pre-restore counter != 3"

run_lkg "${D}" 'lkg_restore'
# After restore, mod's version must equal the OLD lkg (1.0.0).
MVR="$(run_lkg "${D}" 'mod_version "$MOD"')"
[ "${MVR}" = "1.0.0" ] && pass "lkg_restore: mod now == lkg (1.0.0)" \
    || fail "after restore mod version = '${MVR}' (expected 1.0.0)"
# Bad mod stashed aside.
[ -d "${D}/.mod/.reforge/mod.bad" ] && pass "lkg_restore stashed mod.bad" \
    || fail "lkg_restore did not create mod.bad"
[ "$(cat "${D}/.mod/.reforge/mod.bad/release_info.json" | grep -o '2.0.0')" = "2.0.0" ] \
    && pass "mod.bad holds the failed (2.0.0) mod" || fail "mod.bad content wrong"
# Counter reset.
[ "$(run_lkg "${D}" 'lkg_counter_get')" = "0" ] \
    && pass "lkg_restore reset counter to 0" || fail "lkg_restore did not reset counter"
# After restore it is no longer a trial (versions now equal).
if run_lkg "${D}" 'is_trial'; then
    fail "after restore is_trial should be FALSE"
else
    pass "after restore is_trial FALSE (versions equal)"
fi
rm -rf "${D}"

# ===========================================================================
# 6. lkg_promote equalizes versions + resets counter
# ===========================================================================
D="$(make_data 2.0.0 1.0.0)"
run_lkg "${D}" 'lkg_counter_inc'   # pretend we were mid-trial
run_lkg "${D}" 'lkg_promote'
# lkg version must now equal mod (2.0.0).
LV="$(run_lkg "${D}" 'mod_version "$LKG"')"
[ "${LV}" = "2.0.0" ] && pass "lkg_promote: lkg now == mod (2.0.0)" \
    || fail "after promote lkg version = '${LV}' (expected 2.0.0)"
# Counter reset.
[ "$(run_lkg "${D}" 'lkg_counter_get')" = "0" ] \
    && pass "lkg_promote reset counter to 0" || fail "lkg_promote did not reset counter"
# No partial lkg.new left behind.
[ ! -e "${D}/.mod/.reforge/lkg.new" ] && pass "lkg_promote left no partial lkg.new" \
    || fail "lkg_promote left a partial lkg.new"
# Now no longer a trial.
if run_lkg "${D}" 'is_trial'; then
    fail "after promote is_trial should be FALSE"
else
    pass "after promote is_trial FALSE (versions equal)"
fi
rm -rf "${D}"

echo ""
if [ "${FAILS}" -eq 0 ]; then
    echo "PASS: reforge-lkg trial/LKG helpers verified"
    exit 0
else
    echo "FAIL: ${FAILS} assertion(s) failed"
    exit 1
fi
