# firmwareExe — ffsdk support layer, filesystem map, USB, display/GPIO

The `ffsdk` support layer, the complete filesystem the app touches, USB hotplug, fan/PWM, and
display/backlight control.

## ffsdk support layer
- **`ffsdk::FileManager`** — path-bound file ops backing ShowFileList/OrcaServer/print pipeline:
  `entryList(vector<FileInfo>&, …, exts)` (extension-filtered dir list), `asyncEntryList`,
  `copy(src,dst,progressCb)` / `asyncCopy`, `remove`/`removeDir`/`mkdir`/`rename`/`exists`,
  `makeFileInfo(stat)`. **Copy verifies dual MD5** (`srcFileMd5Str` vs `dstFileMd5Str` → `copy file
  fail, md5 not same`), aborts on `copy fail , usb remove`. Print exts: `.gcode`, `.3mf`, `.gx`.
- **`ffsdk::Utils`** — `system(string)` (all shell-outs), `killall(string)` (udhcpc/hostapd/udhcpd/
  wpa_supplicant/wpa_cli/mjpg_streamer), `createThread`/`isThreadExists`, string helpers
  (`split`/`trim`/`startWith`/`endWith` via Boost.Regex). Siblings: `ffsdk::Zip` (minizip),
  `ffsdk::NetworkServer`/`Socket` (CRC32-framed TCP), `ffsdk::Mutex`, `ffsdk::Singleton<T>`.

## USB hotplug (`HotPlug`)
- Netlink-uevent monitor thread `hotPlugMonitor`; parses `(add|remove)@.+/block/sd[a-z]/(sd[a-z][0-9]+)`.
  `dev_action_t ∈ {add, remove}`. Emits `usbNotifyEvent(dev, action, mountDir)`.
- Mount: free fns `mountDev`/`unmountDev` — `/dev/sdaN` → **`/media`**, VFAT/exFAT opts
  **`codepage=936,iocharset=utf8`** (GBK+UTF-8), checks `/proc/mounts`. Failure → `slot_mountfailed`
  → `MainWindow::sig_usbUnmount` → UI `slot_usbRemove`.
- Imported files → **`/data/3mf/usb`** (+ `/thum`). Browse via `ShowFileList::flashUDiskFileList`.
- Same infra: camera hotplug (`cameraNotifyEvent`, probes `/dev/video0`), ethernet
  (`checkEthHotPlug`, `cat /sys/class/net/eth0/carrier`).

## Fans / PWM
- `FanRunInfo` (Singleton) tracks runtime in `/opt/config/Adventurer5M.json`: `printerTotalTime`,
  `powerTime`, `protectTotalTime`, `filamentCumulative`, `filterAir`/`keepTime`/`fanSpeed`/`fanSwitch`
  — air-filter life vs accumulated fan time.
- **Raw PWM** 4 chips: `/sys/class/pwm/pwmchip{0..3}/` → `export` then `pwm{6,1,2,3}/{enable,period,
  duty_cycle}`.
- **Actuation via Klipper** g-code (not direct sysfs): `SET_FAN_SPEED FAN=<pcb_fan|chamber_fan|
  internal_fan|external_fan|fanM106> SPEED=<v>`.

## Display / backlight / GPIO
- **Backlight brightness** (Allwinner dispdbg, needs `mount -t debugfs none /sys/kernel/debug`):
  `echo lcd0 > .../dispdbg/name; echo setbl > .../command; echo <0..255> > .../param; echo 1 > .../start`.
  Persisted as `brightNess` (`Config::get/setBrightness`).
- **Panel power** GPIO203: `echo 203 > /sys/class/gpio/export; echo out > gpio203/direction;
  echo 0/1 > gpio203/value`.
- Chamber/extruder LED: `Config::get/setExtruderLight` → `SET_LED LED=chamber_led WHITE=0/1`.

## Complete filesystem map
**/data** (mutable): `3mf/{model,temp,thum,usb,usb/thum}`, `queue`, `camera/{,jpeg,jpeg-video,video,
cloud}` (+ `cloud/cloud.jpg`), `uploadThumbnail`, `logFiles/` (+ `firmwareExe.core`, `dmesg.*.log`,
`meminfo.*.log`), `Adventurer5M-…-log.zip`, `*.bmp` (M662/updateFile), `Cube-PLA-Test.gcode`.
**/opt**: `PROGRAM/{,control,software/}` (install+OTA), `config/Adventurer5M.json` (main config),
`config/{printer.cfg,printer.base.cfg,levelPrint.cfg,PowerOff,test.gx}`, `klipper/start.sh`,
`mjpg-streamer/`, `qt-4.8.6/`/`Guider3Plus/qt4.8.6/`, `key.priv`/`key.pub`/`cacert.pem`, `ntpclient`,
`mencoder`, `freecach.sh`.
**/etc**: `MAC`, `resolv.conf`, `rtl_hostapd_2G.conf`, `wpa_supplicant.conf`.
**/tmp**: `printer`, `uds` (Klippy socket). **/var**: `run/udhcpc.pid`, `run/wpa_supplicant`,
`lib/misc/udhcpd.leases`. **/media**: USB mount root.
**/proc /sys**: `sys/kernel/core_pattern` (→ firmwareExe.core), `vm/drop_caches`, `meminfo`,
`mounts`, `pwm`, `gpio203`, `net/eth0/carrier`, `kernel/debug/dispdbg/*`.
**/dev**: `ttyS5`/`ttyS1` (MCU), `tty*board`, `video0`, `input/event*`, `sda`/`sdaN`.

## Security notes
- **Default credentials in config**: user `admin`, pass `ff123456` (`userID`/`userPass` in
  `Adventurer5M.json`).
- Log-export zip password hardcoded: `FFP0286&*%root`.
- `core_pattern` → `/data/logFiles/firmwareExe.core` (crash dumps may contain secrets, uploaded with logs).
