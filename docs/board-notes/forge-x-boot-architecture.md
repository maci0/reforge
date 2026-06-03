# forge-x boot architecture (the mod overlay on the stock AD5M)

How the DrA1ex/ff5m (forge-x) mod boots on top of the stock firmware. Reverse-engineered from the
live unit's `/opt/config/mod/.shell/` scripts. Relevant to ReForge (which builds on/around this).

## The two layers
- **Stock firmware** = buildroot Linux on the Allwinner T113 + the QT UI `firmwareExe` + Klipper
  (`/opt/klipper`) + the eboard MCU. UI = touchscreen (firmwareExe).
- **forge-x mod** = an overlay that adds **Moonraker** (:7125) + **Mainsail** web UI + optional
  **guppyscreen**, plus the `z*` CLI tooling — running Klipper/Moonraker/web inside a **buildroot
  chroot** at `/data/.mod/.forge-x` (`$MOD`), while keeping or replacing the stock firmwareExe UI.

## Storage / chroot
- `/dev/mmcblk0p7` → `/data` (data partition; `mount_data_partition` fsck's + mounts it).
- `$MOD = /data/.mod/.forge-x` — a full buildroot rootfs. `init_chroot` rbind-mounts `proc`/`sys`/
  `dev`/`run`/`tmp` into it; `dispose_chroot` unmounts. Klipper/Moonraker/guppy run via
  `chroot "$MOD" /opt/config/mod/.root/start.sh`.
- Key paths (`common.sh`): `SCRIPTS=/opt/config/mod/.shell`, `CMDS=$SCRIPTS/commands`,
  `MOD_DATA=/opt/config/mod_data`, `VAR_PATH=$MOD_DATA/variables.cfg`, `CFG_SCRIPT=zconf.sh`.

## init.d boot order
Stock: `S01syslogd S02klogd S10udev S20urandom S30dbus S40network S50postgresql S50telnet
S80dnsmasq`. Mod (symlinks into `.shell/`): **`S00init` → `S55boot` → `S60dropbear` → `S98camera`
→ `S98zssh` → `S99root`** (+ `K99root` on shutdown).

## S00init — mod init + boot-mode gate
1. `handle_special_boot_mode` → `boot/init_boot_flag.sh apply`: scans USB + `/opt/config/mod/` for
   special flags:
   - **`Adventurer5M*.tgz`** on USB → `FIRMWARE_IMAGE` (stock reflash).
   - `flashforge_init.sh` → `FIRMWARE_SCRIPT`.
   - flag files `SKIP_MOD`, `SKIP_MOD_SOFT`, `REMOVE_MOD`, `REMOVE_MOD_SOFT`, `klipper_mod_skip`,
     `klipper_mod_remove`.
2. **Failsafe / LKG gate** (`handle_boot_options`):
   - `BOOT_FLAG_SKIP` present → emergency log, `touch /tmp/SKIP_MOD_SOFT`, load stock.
   - `BOOT_FLAG_FAILURE` present → "skipped due to boot failure", `touch /tmp/SKIP_MOD_HARD`, load
     stock. **This is the trial/last-known-good safety**: a failed boot sets the failure flag →
     next boot reverts to stock; a clean boot clears it (`rm -f BOOT_FAILURE_F` in S99root).
3. Else: paint splash (`xzcat load.img.xz > /dev/fb0`) and continue the mod boot.

## SKIP_MOD modes
- `/tmp/SKIP_MOD` (manual), `SKIP_MOD_SOFT` (BOOT_FLAG_SKIP), `SKIP_MOD_HARD` (BOOT_FLAG_FAILURE).
  When any is set, `S98camera`/`S98zssh`/`S99root`/`S55boot` bail early → pure stock firmware.
  `S55boot`'s `skip_mod()` also reverts the display config to STOCK so the stock UI works.

## S55boot → boot.sh — network + tweaks
- Ensures `S00init` symlink exists.
- **WiFi** (`wifi_init`): if `/etc/wpa_supplicant.conf` exists and `wlan0` absent →
  `insmod /lib/modules/8821cu.ko` (**Realtek RTL8821CU USB WiFi**) + `modprobe 8821cu`; then
  `wifi_connect.sh` (×5 retry); on success start the `wifi_reconnect.sh` daemon via
  `wpa_cli -B -a`. Sets `MOD_CUSTOM_BOOT=1`.
- **Ethernet** (`ethernet_init`): `ip link set eth0 up && udhcpc eth0`.
- **`suppress_slicer_nag`**: patches `/opt/config/Adventurer5M*.json` `"CheckAppFrist": true → false`
  (disables the stock slicer-upgrade nag — this is the NAG disable).
- Display config via `zdisplay.sh`. Captures IP → `/tmp/net_ip`. `fstrim /root` + `/data`.

## S99root — start the buildroot env
- Bails on SKIP_MOD.
- On first custom boot with `display=GUPPY`: draw mod splash, **`kill -9 $PPID`** ("Goodbye
  Flashforge" — kills the stock firmwareExe UI), optional MIDI boot sound.
  With `display=STOCK` (this unit), firmwareExe is **kept** and the mod runs alongside it.
- DB bootstrap: if no `moonraker-sql.db`, run chroot start/stop, `migrate_db.sh`, `restore_ota.sh`.
- **`chroot "$MOD" /opt/config/mod/.root/start.sh`** runs the service stack.
- Clears `BOOT_FAILURE_F`, sets `NOT_FIRST_LAUNCH_F` (clean-boot = LKG promote).

## The chroot service stack (`.root/start.sh`)
- `S45ntpd` (time).
- **`S65moonraker`** (Moonraker, **:7125**) unless `disable_moonraker=1`; waits for
  `curl localhost:7125`.
- **`S70httpd`** (web/Mainsail) unless `disable_web=1`. Patches Mainsail `release_info.json`
  `project_owner → DrA1ex`, `version → v2.13.2` (the mod's OTA/update-manager identity).
- If `display=GUPPY`: `S35tslib` + **`S80guppyscreen`** (the LVGL touch UI replacing firmwareExe).
- Klipper itself is the stock `/opt/klipper` (started by the stock path / firmwareExe in STOCK mode).

## Config toggles (`variables.cfg`, via `zconf.sh`)
`display` (STOCK | GUPPY), `disable_moonraker`, `disable_web`, `use_swap` (OFF/MMC/USB/ZRAM),
`zram_algo`, `sound` + `midi_on`, `camera`, plus the print/tuning flags.

## The `z*` CLI tooling (`.shell/commands/`)
`zconf` (read/write variables.cfg), `zmoon` (Moonraker API requests, e.g. `restart_klipper`),
`zfs` (filesystem ops), `zdisplay` (STOCK↔GUPPY switch), `zbackup` (config backup/restore),
`zcheck` (file checksum verify), `zversion` (version compat), `zinit` (stock-fw init), `zchanges`
(apply variables.cfg changes), `zmem` (memory print), `zhttp` (web-UI tweaks), `zshaper`/
`ztune_klipper` (tuning), `zsend`/`zprint`/`zclear`. `ff_run.sh` = an env-file loader
(`%(var)s`/`%var%` substitution) used to launch services with their env.

## ReForge relevance
- The failsafe LKG (BOOT_FLAG_FAILURE → SKIP_MOD_HARD → stock) is the model for ReForge's
  trial/rollback OTA safety.
- The chroot-overlay model (mod rootfs at `/data/.mod/...`, stock kept underneath) is how a
  privacy-respecting mod coexists with the stock UI without reflashing.
- Disabling the cloud actors (see firmwareExe cloud docs) + `disable_moonraker`/`disable_web`
  toggles define the network exposure.
- WiFi = RTL8821CU (`8821cu.ko`); the nag-disable + display switch are pure config patches.
