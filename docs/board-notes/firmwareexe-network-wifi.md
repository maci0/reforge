# firmwareExe — network / WiFi subsystem

A thin Qt GUI over `system()`/`popen()` shell-outs to BusyBox + Realtek userland. Engine =
`WIFINAMESPACE::Wifi` (`common/Wifi.cpp`); Settings pages = `Network*`/`Guider*` widgets.

## Station (client) WiFi
- Supplicant config regenerated: `echo "ctrl_interface=DIR=/var/run/wpa_supplicant" > /etc/wpa_supplicant.conf;
  echo "update_config=1" >>`.
- Bring-up: `ifconfig wlan0 up; killall wpa_supplicant; wpa_supplicant -d -Dnl80211 -iwlan0
  -c/etc/wpa_supplicant.conf -B; wpa_cli -a /bin/wifi_reconnect -i wlan0`.
- **Scan via iwlist** (`iwlist wlan0 scan`), parsed by regex (`ESSID:"..."`, `Signal level=`,
  `Authentication Suites`, `802.1X`) → `list<wifi_ap_t>` sorted by dbm.
- **Connect via wpa_cli** network blocks: `add_network`, `set_network N ssid "%s"`,
  `key_mgmt NONE` (open) / `psk "%s"` (WPA-PSK) / `key_mgmt WPA-EAP` + `identity`/`eap`/`phase2`
  (enterprise), `select_network`/`enable_network`, `save_config`. Then `udhcpc -i wlan0`.
- Monitor thread `Wifi_Monite`; signals `evt_wificonnect_success`/`_failed`/`evt_wifidisconnect`.
  4-bar signal icons. `wifiAutoConnect` reconnects last at boot. Config `wifiStationStatus`.

## SoftAP (hotspot)
- `/etc/rtl_hostapd_2G.conf` rebuilt: `sed -i '/ssid=/d'` … then `echo ssid=%s >>`,
  **`echo wpa_passphrase='%s' >>`** (cleartext), `wpa=2`, `wpa_key_mgmt=WPA-PSK`, `wpa_pairwise=CCMP`.
  Fixed **WPA2-PSK/CCMP, 2.4 GHz**.
- Bring-up: `killall wpa_supplicant; ifconfig wlan0 192.168.0.240; mkdir -p /var/lib/misc/;
  touch …/udhcpd.leases; udhcpd -I 192.168.0.240; hostapd -B /etc/rtl_hostapd_2G.conf`.
- SSID/PSK read back: `cat /etc/rtl_hostapd_2G.conf | grep ssid= | head -1`. Default SSID from
  `Adventurer5M Pro`; default PSK seen `12345678`. Config `wifiHotspotStatus`.

## Ethernet
- Link: `cat /sys/class/net/eth0/carrier`. MAC from `/etc/MAC` → `ifconfig eth0 hw ether`.
  DHCP `udhcpc -i eth0 -p /var/run/udhcpc.pid`. Reset: `killall udhcpc; ifconfig eth0 down/up;
  ipaddr flush dev eth0`. Config `ethernetStatus`.

## Static IP
`ifconfig <if> <ip> netmask <mask>; route add default gw <gw>; echo nameserver <dns> > /etc/resolv.conf`.
Config keys `configIp/Netmask/Gateway/Dns`, `isManual`, `isUdhcpc`.

## Other
- **Realtek 2.4 GHz USB WiFi** (`rtl_hostapd`, nl80211, `wlan0`, rtl8189/8821-class). Module load is
  in init scripts, not this binary.
- Connectivity probe `ping -c 5 8.8.8.8` (regex `(% packet loss)`). NTP `/opt/ntpclient -s -h
  pool.ntp.org -p 123` after connect.
- **LAN-only mode** (`NetworkMode`): disables cloud/MQTT, generates a Printer ID (`createPrintId`,
  `Config::LanModeCode`).

## Security
1. **Cleartext AP passphrase** in `/etc/rtl_hostapd_2G.conf` (world-readable, `echo wpa_passphrase='%s'`).
2. **Cleartext STA secrets** on the `wpa_cli set_network … psk "%s"` command line (visible in
   `/proc/<pid>/cmdline`/`ps`) + saved to `/etc/wpa_supplicant.conf`.
3. **Shell injection**: SSID/PSK from the touchscreen are interpolated into `system()`/`popen()`
   format strings (`echo ssid=%s`, `set_network N ssid "%s"`) with no escaping → metacharacter
   breakout.
4. Weak default `12345678`; predictable AP SSID + fixed subnet `192.168.0.240`.
5. `/bin/wifi_reconnect` runs as root on every (dis)association event.
