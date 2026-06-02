#!/usr/bin/env bash
# tests/release/netup-unit-test.sh
#
# Host unit + fuzz test for packaging/live/net-up.sh (no qemu, no root). Drives
# reforge_live_netup against mocked ip/wpa_supplicant/udhcpc/pgrep on PATH and a
# fake /sys + wpa.conf, asserting the best-effort/idempotent contract:
#
#   - already-up (ip reports inet)      -> no-op, does NOT start wpa_supplicant
#   - no interface (/sys entry absent)  -> no-op, no wpa_supplicant
#   - no creds (conf unreadable)        -> brings the link up but does NOT join
#   - happy path (iface + creds, IP appears) -> starts wpa_supplicant + udhcpc, returns 0
#   - never blocks (returns 0 even when no IP ever appears, WAIT capped)
#   - FUZZ: random iface/conf inputs never crash and always return 0
#
# Exit 0 = PASS, 1 = FAIL.
# shellcheck disable=SC1090,SC2015  # NETUP path is fixed; &&/|| asserts are intentional
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NETUP="${REPO_ROOT}/packaging/live/net-up.sh"

FAILS=0
pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILS=$((FAILS + 1)); }
[ -f "${NETUP}" ] || { echo "[FAIL] net-up.sh not found at ${NETUP}"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# --- build a mock command dir on PATH ---------------------------------------
# ip: prints 'inet' for an iface iff a flag file exists (HAS_IP). Records calls.
# wpa_supplicant/udhcpc/pgrep: record invocation; pgrep returns "not running".
make_mocks() {
    local bin="$1"; mkdir -p "${bin}"
    cat > "${bin}/ip" <<EOF
#!/bin/sh
case "\$*" in
  *"addr show"*) [ -f "${WORK}/HAS_IP" ] && echo "    inet 192.168.0.158/24" ; exit 0 ;;
  *"link set"*)  echo "ip link set \$*" >> "${WORK}/calls" ; exit 0 ;;
  *"-o addr show"*) [ -f "${WORK}/HAS_IP" ] && echo "inet 192.168.0.158" ; exit 0 ;;
esac
exit 0
EOF
    cat > "${bin}/wpa_supplicant" <<EOF
#!/bin/sh
echo "wpa_supplicant \$*" >> "${WORK}/calls"
: > "${WORK}/WPA_STARTED"
# wpa associates but does NOT assign an IP — that's DHCP's job (below).
exit 0
EOF
    cat > "${bin}/udhcpc" <<EOF
#!/bin/sh
echo "udhcpc \$*" >> "${WORK}/calls"
: > "${WORK}/DHCP_RAN"
: > "${WORK}/HAS_IP"     # the lease assigns the address
exit 0
EOF
    cat > "${bin}/pgrep" <<'EOF'
#!/bin/sh
exit 1
EOF
    # wpa_cli: record the kick/diag subcommands; emit plausible status/scan output.
    cat > "${bin}/wpa_cli" <<EOF
#!/bin/sh
echo "wpa_cli \$*" >> "${WORK}/calls"
case "\$*" in
  *scan_results*) echo "bssid / freq / signal / flags / ssid"; echo "40:ae:30:fd:a0:e3	5240	-70	[WPA2-PSK-CCMP][ESS]	bacon" ;;
  *status*)       echo "wpa_state=COMPLETED"; echo "ssid=bacon"; echo "freq=5240" ;;
esac
exit 0
EOF
    chmod +x "${bin}"/*
}

BIN="${WORK}/bin"; make_mocks "${BIN}"
SYS="${WORK}/sys"; mkdir -p "${SYS}"
CONF="${WORK}/wpa.conf"; printf 'network={ ssid="x" psk="y" }\n' > "${CONF}"

# run reforge_live_netup in a clean subshell with mocks + overrides
run_netup() {  # extra args are VAR=val overrides (applied after the defaults)
    ( rm -f "${WORK}/calls" "${WORK}/WPA_STARTED" "${WORK}/DHCP_RAN"
      PATH="${BIN}:${PATH}" env \
        REFORGE_LIVE_NET_SYS="${SYS}" REFORGE_LIVE_WPA_CONF="${CONF}" \
        REFORGE_LIVE_WPA_EFF="${WORK}/eff.conf" \
        REFORGE_LIVE_WIFI_IFACE=wlan0 REFORGE_LIVE_NET_WAIT="${WAIT:-2}" \
        REFORGE_LIVE_IF_WAIT="${IFWAIT:-0}" REFORGE_LIVE_KICK_WAIT=0 \
        "$@" \
        sh -c '. "'"${NETUP}"'"; reforge_live_netup' )
}

# --- 1. already up -> no-op (no wpa) ----------------------------------------
: > "${WORK}/HAS_IP"; mkdir -p "${SYS}/wlan0"
run_netup; rc=$?
if [ "${rc}" -eq 0 ] && [ ! -f "${WORK}/WPA_STARTED" ]; then pass "already-up: no-op, no wpa_supplicant"; else fail "already-up mishandled (rc=${rc}, wpa=$( [ -f "${WORK}/WPA_STARTED" ] && echo yes))"; fi

# --- 2. no interface -> no-op -----------------------------------------------
rm -f "${WORK}/HAS_IP"; rm -rf "${SYS}/wlan0"
run_netup; rc=$?
if [ "${rc}" -eq 0 ] && [ ! -f "${WORK}/WPA_STARTED" ]; then pass "no-interface: no-op, no wpa_supplicant"; else fail "no-interface mishandled (rc=${rc})"; fi

# --- 3. no creds -> bring link up but don't join ----------------------------
rm -f "${WORK}/HAS_IP"; mkdir -p "${SYS}/wlan0"
BADCONF="${WORK}/nope.conf"
run_netup REFORGE_LIVE_WPA_CONF="${BADCONF}"; rc=$?
if [ "${rc}" -eq 0 ] && [ ! -f "${WORK}/WPA_STARTED" ]; then pass "no-creds: no join, returns 0"; else fail "no-creds mishandled (rc=${rc})"; fi

# --- 4. happy path -> wpa_supplicant + udhcpc, returns 0 --------------------
rm -f "${WORK}/HAS_IP"; mkdir -p "${SYS}/wlan0"
run_netup; rc=$?
if [ "${rc}" -eq 0 ] && [ -f "${WORK}/WPA_STARTED" ] && [ -f "${WORK}/DHCP_RAN" ] \
   && ! grep -q 'udhcpc_wlan0' "${WORK}/calls"; then
    pass "happy path: associated + DHCP (no procd-wrapper as -s), returns 0"
else
    fail "happy path failed (rc=${rc}, wpa=$( [ -f "${WORK}/WPA_STARTED" ] && echo y), dhcp=$( [ -f "${WORK}/DHCP_RAN" ] && echo y))"
fi

# --- 4a. happy path also kicks the supplicant (enable_network + reassociate) -
rm -f "${WORK}/HAS_IP"; mkdir -p "${SYS}/wlan0"
run_netup; rc=$?
if [ "${rc}" -eq 0 ] && grep -q "wpa_cli.*enable_network all" "${WORK}/calls" && grep -q "wpa_cli.*reassociate" "${WORK}/calls"; then
    pass "kick: enable_network + reassociate issued after wpa start"
else
    fail "kick missing (calls=$(grep wpa_cli "${WORK}/calls" 2>/dev/null | tr '\n' ';'))"
fi

# --- 4b. disabled=1 network -> uses an enabled tmpfs copy -------------------
# Stock confs carry `disabled=1`; net-up must strip it into a tmpfs copy and point
# wpa_supplicant at that copy (the original on eMMC stays untouched).
DCONF="${WORK}/disabled.conf"
printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\nnetwork={\n\tssid="x"\n\tpsk="y"\n\tdisabled=1\n}\n' > "${DCONF}"
rm -f "${WORK}/HAS_IP" "${WORK}/eff.conf"; mkdir -p "${SYS}/wlan0"
run_netup REFORGE_LIVE_WPA_CONF="${DCONF}"; rc=$?
if [ "${rc}" -eq 0 ] && [ -f "${WORK}/eff.conf" ] \
   && ! grep -qiE '^[[:space:]]*disabled=1' "${WORK}/eff.conf" \
   && grep -q 'ssid="x"' "${WORK}/eff.conf" \
   && grep -qF "${WORK}/eff.conf" "${WORK}/calls" \
   && grep -qiE '^[[:space:]]*disabled=1' "${DCONF}"; then
    pass "disabled=1: enabled tmpfs copy made, supplicant uses it, original untouched"
else
    fail "disabled=1 handling wrong (rc=${rc}, eff=$( [ -f "${WORK}/eff.conf" ] && echo y), calls=$(cat "${WORK}/calls" 2>/dev/null))"
fi

# --- 4c. already-enabled conf -> no copy, original path used ----------------
rm -f "${WORK}/HAS_IP" "${WORK}/eff.conf"; mkdir -p "${SYS}/wlan0"
run_netup; rc=$?   # CONF has no disabled flag
if [ "${rc}" -eq 0 ] && [ ! -f "${WORK}/eff.conf" ] && grep -qF "${CONF}" "${WORK}/calls"; then
    pass "enabled conf: no rewrite, supplicant uses original path"
else
    fail "enabled-conf passthrough wrong (eff-exists=$( [ -f "${WORK}/eff.conf" ] && echo y), calls=$(cat "${WORK}/calls" 2>/dev/null))"
fi

# --- 4d. _wpa_effective_conf unit (direct) ----------------------------------
# disabled stripped; enabled passthrough; unreadable src -> echoes src unchanged.
EFFOUT="$( sh -c '. "'"${NETUP}"'"; REFORGE_LIVE_WPA_EFF="'"${WORK}/u_eff.conf"'" _wpa_effective_conf "'"${DCONF}"'"' )"
ENOUT="$(  sh -c '. "'"${NETUP}"'"; REFORGE_LIVE_WPA_EFF="'"${WORK}/u_eff2.conf"'" _wpa_effective_conf "'"${CONF}"'"' )"
MISS="$(   sh -c '. "'"${NETUP}"'"; REFORGE_LIVE_WPA_EFF="'"${WORK}/u_eff3.conf"'" _wpa_effective_conf "'"${WORK}/absent.conf"'"' )"
if [ "${EFFOUT}" = "${WORK}/u_eff.conf" ] && ! grep -qiE 'disabled=1' "${EFFOUT}" \
   && [ "${ENOUT}" = "${CONF}" ] && [ "${MISS}" = "${WORK}/absent.conf" ]; then
    pass "_wpa_effective_conf: strips disabled, passes through enabled + missing"
else
    fail "_wpa_effective_conf wrong (eff='${EFFOUT}', en='${ENOUT}', miss='${MISS}')"
fi

# --- 5. never blocks when no IP ever appears --------------------------------
# Override udhcpc to a no-op that does NOT assign an IP (simulate DHCP never landing).
cat > "${BIN}/udhcpc" <<EOF
#!/bin/sh
echo "udhcpc \$*" >> "${WORK}/calls"; : > "${WORK}/DHCP_RAN"; exit 0
EOF
chmod +x "${BIN}/udhcpc"
rm -f "${WORK}/HAS_IP"; mkdir -p "${SYS}/wlan0"
t0=$(date +%s); WAIT=2 run_netup; rc=$?; t1=$(date +%s)
if [ "${rc}" -eq 0 ] && [ "$((t1 - t0))" -le 6 ]; then pass "no-IP: returns 0 within the WAIT cap ($((t1-t0))s)"; else fail "no-IP did not return promptly (rc=${rc}, $((t1-t0))s)"; fi
# On the no-IP path net-up must dump diagnostics (wpa status + scan count) via wpa_cli.
if grep -q "wpa_cli.*status" "${WORK}/calls" && grep -q "wpa_cli.*scan_results" "${WORK}/calls"; then
    pass "no-IP: dumps wpa status + scan_results diagnostics"
else
    fail "no-IP: missing diagnostics (calls=$(grep wpa_cli "${WORK}/calls" 2>/dev/null | tr '\n' ';'))"
fi
make_mocks "${BIN}"  # restore the associating mock

# --- 6. FUZZ ----------------------------------------------------------------
fuzz_fail=0
for i in $(seq 1 150); do
    rand_if="$(head -c 8 /dev/urandom | tr -dc 'a-z0-9' | head -c 5)"; [ -n "${rand_if}" ] || rand_if="if${i}"
    rand_conf="${WORK}/$(head -c 6 /dev/urandom | tr -dc 'a-z' | head -c 4).conf"
    # sometimes the conf exists; vary enabled vs disabled=1 so the rewrite path is fuzzed
    case $((i % 3)) in
      0) printf 'network={\n\tssid="z"\n\tpsk="w"\n\tdisabled=1\n}\n' > "${rand_conf}" ;;
      1) printf 'network={ ssid="z" psk="w" }\n' > "${rand_conf}" ;;
    esac
    [ $((i % 2)) -eq 0 ] && mkdir -p "${SYS}/${rand_if}"
    WAIT=0 run_netup REFORGE_LIVE_WIFI_IFACE="${rand_if}" REFORGE_LIVE_WPA_CONF="${rand_conf}" \
        REFORGE_LIVE_WPA_EFF="${WORK}/fz_eff_${i}.conf" >/dev/null 2>&1 || { fuzz_fail=1; break; }
done
[ "${fuzz_fail}" -eq 0 ] && pass "fuzz: 150 random iface/conf calls returned 0, no crash" || fail "fuzz: a call returned non-zero/crashed"

echo "----------------------------------------"
if [ "${FAILS}" -eq 0 ]; then echo "netup-unit-test: ALL PASS"; exit 0; fi
echo "netup-unit-test: ${FAILS} FAILURE(S)"; exit 1
