#!/bin/sh
# net-up.sh — best-effort WiFi bring-up for ReForge LIVE mode.
#
# Sourced by the live launcher (flashforge_init.sh) BEFORE it chroots and blocks. In
# live mode the launcher blocks the stock auto_run, so the stock WiFi init (which runs
# later in the stock boot) never happens and the box has no LAN. This reuses the
# stock's already-loaded driver + /etc/wpa_supplicant.conf credentials +
# wpa_supplicant/udhcpc to join the user's network — read-only on eMMC, runtime state
# to tmpfs, so the zero-eMMC-write invariant holds and nothing is re-configured.
#
# Best-effort + idempotent: no-op if already up / no interface / no creds; never blocks
# the live boot (GuppyScreen + local Moonraker come up regardless). Overridable knobs
# (defaults are production; the unit test points them at fakes):
#   REFORGE_LIVE_WIFI_IFACE  (wlan0)
#   REFORGE_LIVE_WPA_CONF    (/etc/wpa_supplicant.conf)
#   REFORGE_LIVE_NET_SYS     (/sys/class/net)
#   REFORGE_LIVE_NET_WAIT    (20)   seconds to wait for an IP (0 = don't wait)

# _net_has_ip <iface> — true if the interface currently has an IPv4 address.
_net_has_ip() {
    ip addr show "$1" 2>/dev/null | grep -q 'inet '
}

reforge_live_netup() {
    _if="${REFORGE_LIVE_WIFI_IFACE:-wlan0}"
    _sys="${REFORGE_LIVE_NET_SYS:-/sys/class/net}"
    _conf="${REFORGE_LIVE_WPA_CONF:-/etc/wpa_supplicant.conf}"
    _wait="${REFORGE_LIVE_NET_WAIT:-20}"

    _net_has_ip "$_if" && return 0                 # already up (stock got there first?)
    [ -e "${_sys}/${_if}" ] || return 0            # no WiFi interface/driver -> nothing to do
    ip link set "$_if" up 2>/dev/null
    [ -r "$_conf" ] || return 0                    # no creds -> can't join; leave it

    # Associate (skip if a supplicant is already running for this interface).
    if ! pgrep -f "wpa_supplicant.*${_if}" >/dev/null 2>&1; then
        wpa_supplicant -B -Dnl80211 -i "$_if" -c "$_conf" 2>/dev/null
    fi
    # DHCP — prefer the stock per-interface script if present.
    if [ -x /etc/wifi/udhcpc_wlan0 ]; then
        udhcpc -i "$_if" -s /etc/wifi/udhcpc_wlan0 -b -q 2>/dev/null
    else
        udhcpc -i "$_if" -b -q 2>/dev/null
    fi

    # Wait briefly for a lease, but NEVER block the live boot on it.
    _i=0
    while [ "$_i" -lt "$_wait" ]; do
        _net_has_ip "$_if" && return 0
        sleep 1
        _i=$((_i + 1))
    done
    return 0
}
