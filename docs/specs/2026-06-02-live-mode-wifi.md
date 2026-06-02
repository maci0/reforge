# Live mode WiFi — bring up the network before the launcher blocks

**Goal:** give ReForge LIVE mode LAN access (Moonraker / Mainsail / SSH reachable),
without breaking the brick-safe invariant (zero eMMC writes).

## Background — why live mode has no network

The hardware trial (2026-06-02, see `docs/live-mode.md`) booted ReForge live from USB
fine — GuppyScreen on the panel — but the printer was **off the network**: ping/ARP
failed, `:80/:7125/:22` all closed. GuppyScreen works because it talks to Moonraker
over the local unix socket; nothing reaches the LAN.

Cause: the stock `auto_run.sh` runs our launcher early, and our launcher **blocks
forever** (`while true; do sleep 3600; done`) so stock never installs/launches its UI.
But the stock **WiFi bring-up runs *later*** in the stock boot, *after* the auto_run
hook — so by blocking there we skip it. ReForge's own S-chain
(cloudblock→zram→klipper→moonraker→httpd→guppy) never configures WiFi either.

## The stock WiFi setup (probed on the live AD5M Pro `kunos`)

- **Driver:** `8821cu` (the USB WiFi dongle), loaded early in boot (well before
  auto_run) — already present when the launcher runs.
- **Supplicant:** `wpa_supplicant -B -Dnl80211 -iwlan0 -c /etc/wpa_supplicant.conf`
  (+ `wpa_cli -a /bin/wifi_reconnect -i wlan0` for reconnect).
- **Credentials:** `/etc/wpa_supplicant.conf` on the eMMC (SSID/PSK the user already
  configured). Also `/etc/wifi/{udhcpc_wlan0,wpa_supplicant*.conf,hostapd.conf}`.
- **DHCP:** udhcpc on wlan0 (`/etc/wifi/udhcpc_wlan0` default script), gateway
  `192.168.0.1`, lease `192.168.0.158`.

The launcher runs in the **stock rootfs, pre-chroot**, so all of the above — the
driver, the `wpa_supplicant`/`udhcpc`/`wpa_cli` binaries, and the eMMC
`/etc/wpa_supplicant.conf` — are directly reachable. Reusing them means **no
credential re-entry** and the user's existing WiFi "just works".

## Design

Add a **best-effort, idempotent** network bring-up to the launcher
(`packaging/live/flashforge_init.sh`), **before** it sets up the chroot and blocks.
Factor it into a small helper, `packaging/live/net-up.sh`, sourced/run by the launcher,
so it is unit-testable.

```
reforge_live_netup() {
    IFACE=${REFORGE_LIVE_WIFI_IFACE:-wlan0}
    # 1. already up? (stock got there first, or a prior call) -> done, no-op
    ip addr show "$IFACE" 2>/dev/null | grep -q 'inet ' && return 0
    # 2. driver present? (8821cu loads early; don't insmod — it's the stock's,
    #    vermagic-matched, and already there). If $IFACE is absent, bail (no WiFi hw).
    [ -e "/sys/class/net/$IFACE" ] || return 0
    ip link set "$IFACE" up 2>/dev/null
    # 3. supplicant with the STOCK creds (read-only; runtime state -> /var/run tmpfs).
    CONF=${REFORGE_LIVE_WPA_CONF:-/etc/wpa_supplicant.conf}
    [ -r "$CONF" ] || return 0          # no creds -> can't join; leave it
    pgrep -f "wpa_supplicant.*$IFACE" >/dev/null \
        || wpa_supplicant -B -Dnl80211 -i "$IFACE" -c "$CONF" 2>/dev/null
    # 4. DHCP (prefer the stock per-iface script if present, else plain udhcpc).
    if [ -x /etc/wifi/udhcpc_wlan0 ]; then
        udhcpc -i "$IFACE" -s /etc/wifi/udhcpc_wlan0 -b -q 2>/dev/null
    else
        udhcpc -i "$IFACE" -b -q 2>/dev/null
    fi
    # 5. wait briefly for an IP, but NEVER block the live boot on it.
    i=0; while [ $i -lt 20 ]; do
        ip addr show "$IFACE" 2>/dev/null | grep -q 'inet ' && break
        sleep 1; i=$((i+1))
    done
}
```

Launcher hook (after the F2FS mount, before the chroot/block):

```
log "bringing up the network (best-effort) ..."
reforge_live_netup || true
log "net: $(ip -o addr show 2>/dev/null | grep -o 'inet [0-9.]*' | tr '\n' ' ')"
```

### Properties

- **Brick-safe:** reads `/etc/wpa_supplicant.conf` (eMMC, read-only); `wpa_supplicant`/
  `udhcpc` write only to `/var/run` / `/tmp` (tmpfs). **No eMMC writes** — invariant holds.
- **Idempotent / best-effort:** no-op if the interface is already up; bails cleanly if
  there's no WiFi hardware, no driver, or no creds. WiFi failure never blocks the live
  boot — GuppyScreen + local Moonraker still come up.
- **Zero credential entry:** reuses the user's existing stock WiFi config.
- **Runs pre-chroot:** wlan0 lives in the host net namespace; the chroot shares it, so
  Moonraker/httpd inside the chroot bind on the live interface automatically.

### Order in the launcher

Bring the network up **before** `chroot … /mod/start.sh`, so Moonraker/Mainsail are on
the LAN as soon as the stack starts. The DHCP wait is capped (≤20 s) and non-fatal.

## Alternatives considered

- **Call the stock's own WiFi init script directly.** More faithful, but the stock
  network bring-up is tangled into its boot sequence (no clean standalone entry point
  found), and invoking it risks pulling in unrelated stock init. The minimal
  reimplementation above uses the same binaries + the same `/etc/wpa_supplicant.conf`,
  so behaviour matches without the coupling. (If a clean stock `wifi_up`-style script is
  later identified, prefer calling it.)
- **Ethernet.** The AD5M Pro is WiFi-only (USB `8821cu`). `reforge_live_netup` keys off
  `$IFACE` and no-ops if absent, so a future wired model degrades cleanly.
- **Static IP.** Rejected — DHCP + the stock creds means it joins the user's network as
  the same host with no config.

## Testing

- **Unit (host, no qemu):** `tests/release/` test for `net-up.sh` with mocked `ip` /
  `wpa_supplicant` / `udhcpc` on `PATH` and a fake `REFORGE_LIVE_WPA_CONF`: asserts
  no-op when already-up, bail when no iface/creds, and the correct command sequence
  otherwise. Plus a fuzz pass (random iface/conf inputs never error, never block).
- **qemu:** can't exercise real WiFi (the virt rig has no 802.11), but `make qemu-live`
  must still pass (the bring-up no-ops with no `wlan0`, proving it never breaks the boot
  or the zero-eMMC-write gate).
- **Hardware:** the real proof — after the fix, `tools/release/verify-live-trial.sh live`
  reaches Moonraker `:7125` + Mainsail `:80`, and SSH (if ReForge ships a key) works.
  This also unblocks reading `klippy.log` to diagnose the host↔MCU Klipper-version issue.

## Risks / caveats

- Depends on the user having valid stock WiFi creds in `/etc/wpa_supplicant.conf`. No
  creds → no network (logged, non-fatal).
- The `8821cu` driver must already be loaded (it is, early in boot). If a future unit
  ships a different WiFi chip, the driver assumption changes (the iface check still
  degrades cleanly).
- WiFi join adds a few seconds to the live boot (capped); GuppyScreen comes up regardless.

## See also

- `docs/live-mode.md` — live mode + the hardware-trial findings this fixes.
- `packaging/live/flashforge_init.sh` — the launcher this hooks into.
