#!/bin/sh
# net-up.sh — best-effort WiFi bring-up for ReForge LIVE mode.
#
# Sourced by the live launcher (flashforge_init.sh) BEFORE it chroots and blocks. In
# live mode the launcher blocks the stock auto_run, so the stock WiFi init (which runs
# later in the stock boot) never happens and the box has no LAN. This reuses the
# stock's driver + /etc/wpa_supplicant.conf credentials + wpa_supplicant/udhcpc to
# join the user's network — read-only on eMMC, runtime state to tmpfs, so the
# zero-eMMC-write invariant holds and nothing is re-configured.
#
# Best-effort + idempotent: no-op if already up / no interface / no creds; never blocks
# the live boot (every wait is capped). It runs EARLY (at auto_run time), so the WiFi
# driver may still be binding — it waits for the interface to appear, then for the
# supplicant to associate, then DHCP (retried). Overridable knobs (defaults are
# production; the unit test points them at fakes):
#   REFORGE_LIVE_WIFI_IFACE  (wlan0)
#   REFORGE_LIVE_WPA_CONF    (/etc/wpa_supplicant.conf)
#   REFORGE_LIVE_NET_SYS     (/sys/class/net)
#   REFORGE_LIVE_IF_WAIT     (15)   seconds to wait for the interface to appear
#   REFORGE_LIVE_NET_WAIT    (25)   seconds to wait for an IP (0 = don't wait)
#   REFORGE_LIVE_NET_LOG     (unset) append a step log here (the launcher sets the USB log)

_net_has_ip() { ip addr show "$1" 2>/dev/null | grep -q 'inet '; }
_nlog() { [ -n "${REFORGE_LIVE_NET_LOG:-}" ] && echo "[net-up] $*" >> "${REFORGE_LIVE_NET_LOG}" 2>/dev/null; return 0; }

# Stock stores the WiFi network in /etc/wpa_supplicant.conf with `disabled=1` — it
# never auto-associates; stock's wlan-connect.sh enables it at runtime via wpa_cli
# (add_network/set_network/enable_network). Since the static conf already holds a
# valid ssid+psk, the one thing blocking `wpa_supplicant -c <conf>` from joining is
# that disable flag. Echo a tmpfs copy of the conf with every `disabled=1` line
# stripped (network defaults to enabled) so a plain supplicant joins. The original
# on eMMC is never rewritten — the copy lives in tmpfs — so the zero-write invariant
# holds. If the conf has no disable flag (or can't be copied) the original path is
# echoed unchanged, so this is a safe no-op for already-enabled configs.
_wpa_effective_conf() {  # <src-conf> -> echoes path to a conf whose network is enabled
    _src="$1"
    _eff="${REFORGE_LIVE_WPA_EFF:-/tmp/reforge-wpa.conf}"
    grep -qiE '^[[:space:]]*disabled=1[[:space:]]*$' "$_src" 2>/dev/null || { echo "$_src"; return 0; }
    if grep -viE '^[[:space:]]*disabled=1[[:space:]]*$' "$_src" > "$_eff" 2>/dev/null; then
        echo "$_eff"
    else
        echo "$_src"
    fi
}

# Locate wpa_cli (stock ships it at /usr/sbin). Echoes the binary or nothing.
_wpa_cli_bin() { command -v wpa_cli 2>/dev/null || { [ -x /usr/sbin/wpa_cli ] && echo /usr/sbin/wpa_cli; } || true; }

reforge_live_netup() {
    _if="${REFORGE_LIVE_WIFI_IFACE:-wlan0}"
    _sys="${REFORGE_LIVE_NET_SYS:-/sys/class/net}"
    _conf="${REFORGE_LIVE_WPA_CONF:-/etc/wpa_supplicant.conf}"
    _ifwait="${REFORGE_LIVE_IF_WAIT:-15}"
    _wait="${REFORGE_LIVE_NET_WAIT:-45}"   # 5GHz first-scan + association can be slow on a cold driver

    if _net_has_ip "$_if"; then _nlog "${_if} already has an IP"; return 0; fi

    # The driver may still be binding (we run before the stock WiFi init) — wait for
    # the interface node to appear.
    _w=0
    while [ ! -e "${_sys}/${_if}" ] && [ "${_w}" -lt "${_ifwait}" ]; do sleep 1; _w=$((_w + 1)); done
    if [ ! -e "${_sys}/${_if}" ]; then _nlog "no ${_if} after ${_w}s (no WiFi hw/driver) — skip"; return 0; fi
    _nlog "${_if} present after ${_w}s; bringing up"
    ip link set "$_if" up 2>/dev/null

    if [ ! -r "$_conf" ]; then _nlog "no creds at ${_conf} — can't join"; return 0; fi

    if pgrep -f "wpa_supplicant.*${_if}" >/dev/null 2>&1; then
        _nlog "wpa_supplicant already running for ${_if}"
    else
        _econf="$(_wpa_effective_conf "$_conf")"
        [ "$_econf" != "$_conf" ] && _nlog "network was disabled=1 in ${_conf}; using enabled copy ${_econf}"
        _nlog "starting wpa_supplicant (-Dnl80211 -c ${_econf})"
        wpa_supplicant -B -Dnl80211 -i "$_if" -c "$_econf" 2>/dev/null || _nlog "wpa_supplicant start returned non-zero"
    fi

    # Kick the supplicant: enable every configured network and force a (re)association
    # + scan. wpa_supplicant -B sometimes settles into DISCONNECTED if its first scan
    # ran before the cold driver finished bringing the radio up — an explicit
    # enable_network/reassociate restarts the scan/associate cycle (this is what stock's
    # wlan-connect.sh leans on). Best-effort: skipped cleanly if wpa_cli is absent.
    _wc="$(_wpa_cli_bin)"
    if [ -n "${_wc}" ]; then
        sleep "${REFORGE_LIVE_KICK_WAIT:-2}"
        "${_wc}" -i "$_if" enable_network all >/dev/null 2>&1 || true
        "${_wc}" -i "$_if" reassociate     >/dev/null 2>&1 || true
    fi

    # Wait for an IP, (re)kicking DHCP periodically — the first udhcpc can fire before
    # the supplicant has associated, so a single attempt may miss the lease.
    _i=0
    while [ "${_i}" -lt "${_wait}" ]; do
        if _net_has_ip "$_if"; then _nlog "got IP: $(ip addr show "$_if" 2>/dev/null | grep -o 'inet [0-9.]*' | head -1)"; return 0; fi
        if [ $((_i % 5)) -eq 0 ]; then
            # Plain busybox udhcpc + its default lease-applying script — exactly how a
            # normal boot brings wlan0 up (forge-x runs bare `udhcpc -i wlan0`).
            # IMPORTANT: never pass -s /etc/wifi/udhcpc_wlan0 — that file is an OpenWrt
            # procd *service wrapper* that `killall`s udhcpc, NOT a udhcpc event handler;
            # using it as -s makes udhcpc kill itself on the `bound` event so the lease
            # is never applied (associated, but no IP). -n: give up a try instead of
            # blocking; -q: exit once the lease is bound (default.script set the IP).
            _uds=""; [ -f /usr/share/udhcpc/default.script ] && _uds="-s /usr/share/udhcpc/default.script"
            # shellcheck disable=SC2086
            udhcpc -i "$_if" ${_uds} -n -q -t 4 -T 2 2>/dev/null
        fi
        sleep 1
        _i=$((_i + 1))
    done
    # No IP. Dump why (does the supplicant exist? did it associate? did it see any APs?)
    # to the step log so a pulled stick explains the failure with no network needed.
    if [ -n "${_wc}" ]; then
        _nlog "wpa: $("${_wc}" -i "$_if" status 2>/dev/null | grep -iE 'wpa_state|^ssid|freq|bssid' | tr '\n' ' ')"
        _nlog "scan: $("${_wc}" -i "$_if" scan_results 2>/dev/null | grep -cE '^([0-9a-f]{2}:){5}') AP(s) visible"
    fi
    _nlog "no IP after ${_wait}s — giving up (GuppyScreen/local still works)"
    return 0
}
