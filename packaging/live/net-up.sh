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

reforge_live_netup() {
    _if="${REFORGE_LIVE_WIFI_IFACE:-wlan0}"
    _sys="${REFORGE_LIVE_NET_SYS:-/sys/class/net}"
    _conf="${REFORGE_LIVE_WPA_CONF:-/etc/wpa_supplicant.conf}"
    _ifwait="${REFORGE_LIVE_IF_WAIT:-15}"
    _wait="${REFORGE_LIVE_NET_WAIT:-25}"

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
        _nlog "starting wpa_supplicant (-Dnl80211 -c ${_conf})"
        wpa_supplicant -B -Dnl80211 -i "$_if" -c "$_conf" 2>/dev/null || _nlog "wpa_supplicant start returned non-zero"
    fi

    # Wait for an IP, (re)kicking DHCP periodically — the first udhcpc can fire before
    # the supplicant has associated, so a single attempt may miss the lease.
    _i=0
    while [ "${_i}" -lt "${_wait}" ]; do
        if _net_has_ip "$_if"; then _nlog "got IP: $(ip -o addr show "$_if" 2>/dev/null | grep -o 'inet [0-9.]*')"; return 0; fi
        if [ $((_i % 5)) -eq 0 ]; then
            if [ -x /etc/wifi/udhcpc_wlan0 ]; then
                udhcpc -i "$_if" -s /etc/wifi/udhcpc_wlan0 -b -q -t 3 2>/dev/null
            else
                udhcpc -i "$_if" -b -q -t 3 2>/dev/null
            fi
        fi
        sleep 1
        _i=$((_i + 1))
    done
    _nlog "no IP after ${_wait}s — giving up (GuppyScreen/local still works)"
    return 0
}
