#!/usr/bin/env bash
# tests/release/vmtune-unit-test.sh
#
# Host unit + fuzz test for .shell/reforge-vmtune.sh (no qemu, no root). Exercises
# the VM-tuning helper against a scratch VM_SYS_ROOT (a temp dir standing in for
# /proc/sys/vm):
#
#   - sourcing the script has NO side effects (creates/writes nothing)
#   - vm_set writes the value to an existing, writable knob
#   - vm_set is a no-op (returns 0) when the knob is absent or unwritable
#   - reforge_vmtune sets all six tuned knobs to their documented values
#   - ZRAM_SWAPPINESS overrides the swappiness target
#   - FUZZ: random knob names / values never crash, always return 0, and never
#     create a knob that did not already exist (the best-effort, only-if-present
#     contract — so a typo can never spam /proc/sys/vm)
#
# Exit 0 = PASS, 1 = FAIL.
# shellcheck disable=SC1090,SC2015,SC2034  # source path is fixed; &&/|| asserts + vars consumed by the sourced helper are intentional
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VMTUNE_SH="${REPO_ROOT}/br-external/board/reforge/rootfs-overlay/.shell/reforge-vmtune.sh"

FAILS=0
pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILS=$((FAILS + 1)); }

[ -f "${VMTUNE_SH}" ] || { echo "[FAIL] reforge-vmtune.sh not found at ${VMTUNE_SH}"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# Expected tuned values (must track reforge_vmtune).
EXPECT_KNOBS="page-cluster=0 swappiness=100 vfs_cache_pressure=50 watermark_scale_factor=40 dirty_ratio=10 dirty_background_ratio=5"

mk_knobs() {  # create the six knob files (pre-seeded with a sentinel) under $1
    local root="$1"
    mkdir -p "${root}"
    for kv in ${EXPECT_KNOBS}; do printf 'SENTINEL\n' > "${root}/${kv%%=*}"; done
}

# --- 1. sourcing has no side effects ----------------------------------------
EMPTY="${WORK}/empty"; mkdir -p "${EMPTY}"
( VM_SYS_ROOT="${EMPTY}"; . "${VMTUNE_SH}" )  # subshell: just source
if [ -z "$(ls -A "${EMPTY}")" ]; then pass "sourcing has no side effects"; else fail "sourcing wrote into VM_SYS_ROOT"; fi

# --- 2. vm_set writes an existing knob --------------------------------------
R2="${WORK}/r2"; mkdir -p "${R2}"; printf 'x\n' > "${R2}/swappiness"
( VM_SYS_ROOT="${R2}"; . "${VMTUNE_SH}"; vm_set swappiness 100 )
[ "$(cat "${R2}/swappiness")" = "100" ] && pass "vm_set writes existing knob" || fail "vm_set did not write the knob"

# --- 3. vm_set no-op for absent knob (returns 0, creates nothing) ------------
R3="${WORK}/r3"; mkdir -p "${R3}"
rc=0; ( VM_SYS_ROOT="${R3}"; . "${VMTUNE_SH}"; vm_set does_not_exist 7 ) || rc=$?
if [ "${rc}" -eq 0 ] && [ ! -e "${R3}/does_not_exist" ]; then pass "vm_set no-op for absent knob"; else fail "vm_set mishandled an absent knob (rc=${rc})"; fi

# --- 4. reforge_vmtune sets all six knobs to the documented values ----------
R4="${WORK}/r4"; mk_knobs "${R4}"
( VM_SYS_ROOT="${R4}"; . "${VMTUNE_SH}"; reforge_vmtune )
ok=1
for kv in ${EXPECT_KNOBS}; do
    got="$(cat "${R4}/${kv%%=*}" 2>/dev/null)"
    [ "${got}" = "${kv#*=}" ] || { fail "reforge_vmtune ${kv%%=*}=${got} (want ${kv#*=})"; ok=0; }
done
[ "${ok}" -eq 1 ] && pass "reforge_vmtune sets all six knobs correctly"

# --- 5. ZRAM_SWAPPINESS override --------------------------------------------
R5="${WORK}/r5"; mk_knobs "${R5}"
( VM_SYS_ROOT="${R5}"; ZRAM_SWAPPINESS=80; . "${VMTUNE_SH}"; reforge_vmtune )
[ "$(cat "${R5}/swappiness")" = "80" ] && pass "ZRAM_SWAPPINESS overrides swappiness" || fail "ZRAM_SWAPPINESS override ignored"

# --- 6. FUZZ: random knobs/values never crash, never create a knob ----------
RF="${WORK}/rf"; mkdir -p "${RF}"
fuzz_fail=0
for i in $(seq 1 300); do
    # random knob name (may contain dots, dashes, slashes, dotdot) + random value
    knob="$(head -c 12 /dev/urandom | tr -dc 'a-zA-Z0-9._/-' | head -c 8)"
    [ -n "${knob}" ] || knob="k${i}"
    val="$(head -c 6 /dev/urandom | tr -dc 'a-zA-Z0-9 ._-' | head -c 5)"
    rc=0
    ( VM_SYS_ROOT="${RF}"; . "${VMTUNE_SH}"; vm_set "${knob}" "${val}" ) >/dev/null 2>&1 || rc=$?
    [ "${rc}" -eq 0 ] || { fuzz_fail=1; break; }
done
created="$(find "${RF}" -mindepth 1 2>/dev/null | wc -l)"
if [ "${fuzz_fail}" -eq 0 ] && [ "${created}" -eq 0 ]; then
    pass "fuzz: 300 random vm_set calls returned 0 and created no knobs"
else
    fail "fuzz: nonzero return or a knob was created (fail=${fuzz_fail}, created=${created})"
fi

echo "----------------------------------------"
if [ "${FAILS}" -eq 0 ]; then echo "vmtune-unit-test: ALL PASS"; exit 0; fi
echo "vmtune-unit-test: ${FAILS} FAILURE(S)"; exit 1
