# `firmwareExe` — full reverse-engineering of the AD5M Pro stock UI app

Reverse-engineered from the on-device binary (pulled to `/tmp/firmwareExe`) with the
`arm-linux-gnueabi` toolchain (`readelf -sW`, `c++filt`, `objdump -d`, `strings`). Every symbol,
address, and string below was verified against the binary. This is the **overview**; deep-dive
references:
- [`gdb-firmwareexe-injection.md`](gdb-firmwareexe-injection.md) — gdb method-injection cookbook.
- [`ad5m-pro-klipper-hardware-config.md`](../ad5m-pro-klipper-hardware-config.md) — full pin map / printer.cfg.
- [`firmwareexe-orcaserver-lan-api.md`](firmwareexe-orcaserver-lan-api.md) — LAN HTTP API (:8898).
- [`firmwareexe-ota-update.md`](firmwareexe-ota-update.md) — OTA path (**MD5-only, unsigned**).
- [`firmwareexe-cloud-command-surface.md`](firmwareexe-cloud-command-surface.md) — remote-control surface.
- [`firmwareexe-lan-protocol-and-crypto.md`](firmwareexe-lan-protocol-and-crypto.md) — TCP 8899, discovery, keys.
- [`firmwareexe-local-print-api.md`](firmwareexe-local-print-api.md) — Klippy socket `/tmp/uds` (ETX-framed) + print g-code.
- [`firmwareexe-cloud-rest-and-oss.md`](firmwareexe-cloud-rest-and-oss.md) — cloud REST catalog + OSS upload.
- [`firmwareexe-filesystem-and-system.md`](firmwareexe-filesystem-and-system.md) — ffsdk, filesystem map, USB, PWM, display.
- [`firmwareexe-network-wifi.md`](firmwareexe-network-wifi.md) — wifi/eth/AP/static via shell-outs.
- [`firmwareexe-ui-classes.md`](firmwareexe-ui-classes.md) — Keyboard/Language/Guider/dialogs/QR.

## 0. What it is

- **Path:** `/opt/PROGRAM/software/5.1.4/firmwareExe`. **Install root:** `/opt/Guider3Plus/`
  (RPATH `/opt/Guider3Plus/qt4.8.6/lib`). Internal codenames **Guider3Plus / AD4 / Guider**.
- **Type:** ELF 32-bit ARM EABI5, dynamically linked, **NOT stripped** (full Itanium-mangled C++
  symbols + DWARF `debug_info`). 25,801 FUNC + 8,322 OBJECT symbols. Built Linaro GCC 4.9.4,
  `-mtune=cortex-a9`, Qt **4.8.6**.
- **Firmware version string:** `5.1.4 20260514`. **Model:** `Flashforge Adventurer 5M Pro`
  (config `/opt/config/Adventurer5M.json`, device tag `(AD5MP;`).
- **The whole UI is a single QT4 app.** Because it's not stripped and exposes static singleton
  pointers, forge-x drives it from shell via **gdb method-injection** (see the gdb doc).

**Linked libs (DT_NEEDED):** Qt4 (Core/Gui/Network), libcurl, OpenSSL 1.0.0, boost 1.58,
FFmpeg 58 (avcodec/avformat/avutil/swscale/swresample/postproc/avfilter/avdevice) + **libx264.148**,
`libssioclient_arm` (socket.io), **`libnim`/`libnim_chatroom`** (NetEase IM/Yunxin), `libts`
(touchscreen). Statically compiled in: **Aliyun OSS C++ SDK**, Eclipse **Paho MQTT C 1.3.13**,
**librtmp**, qrencode 4.0.2.

## 1. Architecture

```
                         firmwareExe (Qt4 UI, single process)
  ┌───────────────┬───────────────┬────────────────┬───────────────────────────┐
  │  UI / screens │   Camera/media│  Printer ctrl  │      Cloud / network        │
  │  MainWindow   │  CameraFacade │  SerialObject  │  AppClient FlashClient      │
  │  Settings     │   →CameraCtrl │   →ClientAPI   │  PolarClient MqttManager    │
  │  *Dialog      │    →InputCam  │    (/tmp/uds)  │  NimManager OrcaServer      │
  │  MoreInfo     │    →RTMPCtrl  │   →Serial      │  ServerListener AlibabaOSS  │
  │  Config(JSON) │    →OutputHttp│    (ttyS1/S5)  │                             │
  └───────┬───────┴──────┬────────┴───────┬────────┴──────────────┬─────────────┘
          │              │                │                       │
   Adventurer5M.json  /dev/video0    Klippy API JSON-RPC     FlashForge cloud,
   /opt/config/*    (MJPEG→x264→RTMP) over /tmp/uds +        Alibaba OSS, NetEase
                    mjpg_streamer:8080  raw serial→eboard     IM, PolarCloud, MQTT
```

- **Motion/heat/print** → Klipper **Klippy API server JSON-RPC over the Unix socket `/tmp/uds`**
  (NOT Moonraker; `7125` is absent from the binary). Auxiliary **`eboard` MCU** on `/dev/ttyS1`/
  `/dev/ttyS5` @ 230400 (Marlin-style) for weight/TVOC/boot checks.
- **Camera** is USB-MJPEG; the in-process path decodes MJPEG and re-encodes H.264 in **software
  (libx264)** for cloud RTMP. The Allwinner VE hardware encoder is **not used** (no `VideoEnc*`/
  `cedar`/`venc` imports anywhere — confirms `lab/venc-scratch` findings).
- **Cloud** = FlashForge (api.voxelshare.com / sz3dp.com), Alibaba OSS (file storage), NetEase IM
  (realtime), PolarCloud (optional), MQTT-over-WSS (realtime control).

## 2. gdb control surface (singletons + callable methods)

Each screen/object is a lazy global singleton: a static `inst<Class>` pointer set on first
construction (null until opened — always null-check). Pass it as the C++ `this`. Pattern:
`gdb -batch -ex "set auto-solib-add off" -ex "attach $pid" -ex "call (RET) MANGLED(INST_PTR,args)" -ex detach -ex quit`.

**Key instance pointers** (`readelf` OBJECT symbols):

| Mangled | Demangled |
|---|---|
| `_ZN10MainWindow14instMainWindowE` | `MainWindow::instMainWindow` |
| `_ZN8Settings12instSettingsE` | `Settings::instSettings` |
| `_ZN6Config17m_singletonConfigE` / `_ZN6Config11getInstanceEv` | `Config` (prefer `getInstance()`) |
| `_ZN12CancelDialog16instCancelDialogE` | `CancelDialog::instCancelDialog` |
| `_ZN19CompletePrintDialog23instCompletePrintDialogE` | `CompletePrintDialog::...` |
| `_ZN5ffsdk9SingletonI12CameraFacadeE10m_instanceE` (`0x64ffa8`) | `ffsdk::Singleton<CameraFacade>::m_instance` |
| `_ZN16UpdateMainDialog20instUpdateMainDialogE`, `_ZN11FlashConfig15instFlashConfigE` (`0x650518`), `MqttManager::getInstance()` (`0x65078c`) | … |

Many more `inst*`/singletons exist: `Home`, `Print`, `MachineInfo`, `MoreInfo`, `Keyboard`,
`Language`, `ShowFileList`, `Filament`/`Load`/`Unload`/`Change`/`Select`, `SetParameter`,
`Network*`, `License`, `Scanner`, `LcdProtect`, `ShowCameraPicture`/`PlayCameraVideo`, the full
`*Dialog` set, `Guider*` wizard screens.

**Useful callable methods:**

| Mangled symbol | Demangled | Effect |
|---|---|---|
| `_ZN10MainWindow11closeCameraEv` | `MainWindow::closeCamera()` | **camera OFF** (releases /dev/video0) |
| `_ZN10MainWindow10openCameraEv` | `MainWindow::openCamera()` | camera ON |
| `_ZN10MainWindow19on_settings_clickedEv` | `MainWindow::on_settings_clicked()` | open Settings (constructs instSettings) |
| `_ZN10MainWindow15on_home_clickedEv` | `MainWindow::on_home_clicked()` | back to home |
| `_ZN8Settings7saveCfgEv` | `Settings::saveCfg()` | **save config + restart Klipper** (factory path) |
| `_ZN6Config13writeToConfigEv` | `Config::writeToConfig()` | flush JSON config to disk |
| `_ZN12CancelDialog13setStateClearEv` | `CancelDialog::setStateClear()` | dismiss cancel dialog |
| `_ZN10MainWindow10doPowerOffEv` | `MainWindow::doPowerOff()` | **power off (dangerous)** |
| `_ZN12CameraFacade11closeCameraEv` | `CameraFacade::closeCamera()` | full camera teardown (closes V4L2 fd) |

This is exactly what forge-x's `restart_klipper.sh` (`on_settings_clicked`→`saveCfg`→
`on_home_clicked`) and `close_dialogs.sh` (`*Dialog::setStateClear`/`on_close_clicked`) do.

**`MoreInfo` is a hidden engineering/G-code console** (`instMoreInfo`): raw G-code keypad
(`on_send_clicked`, G/M/T/X/Y/Z/S/E/F pads), live config get/put, per-axis jog start/stop, direct
fan/heater control (`on_*Fan_clicked`, `on_nozzle_*`, `on_bed_*`), PID (`doPidStart`), input-shaper
(`doShaperCalibrateX/Y`), **emergency stop `on_M112_clicked`**. No safety gating — do not invoke
blind. Also `MainWindow::testPrint()` (factory test, `/opt/config/test.gx`) and debug mem
instrumentation (`doDebugMemInfo`).

## 3. Config subsystem

- Singleton `Config::getInstance()`; backing file **`/opt/config/Adventurer5M.json`** (path from
  `getConfigFile()`); load/save `readFromConfig()`/`writeToConfig()`. Sub-trees: General, Network,
  Camera, Filament, Log, WebConsole, FlashCloud, PolarCloud, PrinterosCloud.
- Pattern `T get<Name>()` / `set<Name>(T)`; every setter persists to JSON. Notable settings:
  `CameraStatus`/`CameraVideoStatus`/`CameraDelay`, `LedStatus`/`FanStatus`/`FanSpeed`/`AirStatus`,
  `Filament*`, `zProbeOffset`/`LevelPrintPointZ`/`LeftExtruder*Offset`, `Network*`, `Wifi*`,
  `FlashCloud*`/`PolarCloud*`/`WebConsole*`, `PrinterName`/`PrinterSerialNumber`/`PrinterLanguage`,
  `Brightness`, `BuzzerStatus`, `RecoverStatus`.
- **Camera on/off gotcha:** `MainWindow::doSetCameraStatus(bool)` calls `Config::setCameraStatus`
  and **no-ops when the flag already equals the target**. A panel-started live preview does not set
  that flag, so `doSetCameraStatus(0)` does nothing — call `closeCamera()`/`CameraFacade::closeCamera()`
  directly (verified: status read 0 while video0 held; `closeCamera()` released it).

## 4. Camera / media pipeline

`CameraFacade (singleton) → CameraControl → { InputCamera (V4L2 capture), OutputHttp (HTTP thread),
RTMPControl (encode+send) }`. Two consumers of `/dev/video0`:

1. **`mjpg_streamer`** (external, shelled out) — LAN preview/snapshots:
   `/opt/mjpg-streamer/bin/mjpg_streamer -i "input_uvc.so -r 1280x720 -f 30" -o "output_file.so -f /data/camera -d 3000 -s 2" -o "output_http.so -w /opt/mjpg-streamer/www --port 8080" &`.
   Teardown `killall mjpg_streamer`.
2. **In-process V4L2** (`InputCamera`, MJPEG fourcc `'MJPG'` set in `setCameraFrameFormat`) →
   libavcodec **decode** → libswscale → **libx264 software encode** (`RTMPControl::X264Init/Encode`,
   **640×480, preset ultrafast, tune zerolatency**) → **librtmp** push to
   `rtmp://livepush.flashforge.com/`. A hardcoded test URL `rtmp://115.231.29.49:2045/Adventurer5M/SNMOMC9900796`
   is also present.

**H.264 is software (CPU), confirmed:** 9 x264 imports, all called only from `RTMPControl`;
libavcodec is decode-only (`avcodec_send_packet`/`receive_frame`); **zero** Allwinner VE encoder
symbols. Snapshots/timelapse: JPEGs in `/data/camera/{jpeg,jpeg-video,video,cloud}`, MP4 via
mencoder (`-ovc lavc -lavcopts vcodec=mpeg4`), cloud image `/data/camera/cloud/cloud.jpg` uploaded
via Alibaba OSS. Camera-off chain: `MainWindow::closeCamera` → `CameraFacade::closeCamera` →
`CameraControl::closeCamera` → `OutputHttp::stopHttpServerPthread` + `InputCamera::stopCamera`
(→`closeCameraDevice` = `close()` on the fd).

## 5. Printer control (Klipper + serial)

`SerialObject` (singleton) has two transports:

- **Primary — Klippy API server JSON-RPC over AF_UNIX `/tmp/uds`** (`ClientAPI`, select-driven).
  Messages: `objects/query` (id **98888888** — subscribes virtual_sdcard/print_stats/extruder/
  heater_bed/toolhead/gcode_move/filament_switch_sensor e0_sensor/temperature_sensor weightValue&
  tvocValue/gcode_button btn_power), `gcode/subscribe_output` (key **99999999**), `gcode/script`
  (injects G-code), `gcode/restart`, `gcode/firmware_restart`. **Not Moonraker.**
- **Secondary — raw serial `Serial` on `/dev/ttyS1`/`ttyS5` @ 230400** to the **`eboard` MCU**
  (Marlin `ok`/`T:`/`B:` parsing) for weight/TVOC/air board + boot checks.

**Print lifecycle** (`Print` + `SerialObject`): states `None/Heating/Play/Pause/Paused/Resuming/
Stop/Complete`. virtual_sdcard via `M21`/`M23 /file`/`M24`/`M25`/`M26 S<off>`/`M27`; pause =
`M25`+`SAVE_GCODE_STATE NAME=PAUSE_state`, resume = `RESTORE_GCODE_STATE NAME=PAUSE_state MOVE=1`+
`M24`+`CLEAR_PAUSE`, cancel = `CANCEL_PRINT`. Power-loss recovery via `/opt/config/PowerOff` +
`M26 S<seek>`. Live adjust: `SET_GCODE_OFFSET Z=`, `M220 S`, fan `SET_FAN_SPEED`. **Config save
issues `SAVE_CONFIG` → Klipper restart** (this is why forge-x's restart goes through `saveCfg()`).

**Leveling/calibration** (`GuiderLevelPrint`, `MoreInfo`): `BED_MESH_CALIBRATE/CLEAR/MAP`,
`PROBE_CALIBRATE`, `Z_OFFSET_APPLY_PROBE`, `SHAPER_CALIBRATE`, `PID_CALIBRATE`. Build vol ~125×125×230,
single 0.4 mm extruder, shaper default mzv/47.4. **Files** under `/data/` (`3mf/`, `queue`,
`uploadThumbnail`); USB at `/media`. Filament load/unload = `M104`/`M109` + `G1 E…` feed/retract.

## 6. Cloud / network / telemetry

| Client | Transport | To | Purpose |
|---|---|---|---|
| AppClient | HTTPS+NIM+MQTT | api.voxelshare.com / cloud.sz3dp.com | register, status, log upload, remote commands |
| FlashClient | HTTPS+RTMP | FlashForge + live*.flashforge.com | FlashCloud jobs + camera live |
| PolarClient | socket.io/TLS | printer2.polar3d.com | PolarCloud (opt-in; serial+PIN auth, rsapub.pem) |
| MqttManager | MQTT/WSS (Paho) | cloud-provided broker `:8083/mqtt` | realtime cmd/status; creds from `/api/v2/external/truck/device/mqtt/config` |
| NimManager | NetEase IM SDK | NetEase (Yunxin) cloud | realtime IM/"team" push (token from cloud) |
| OrcaServer | httplib HTTP | LAN **:8898** | OrcaSlicer/LAN API (`/uploadGcode`,`/printGcode`,`/printer/status`,…) |
| ServerListener | TCP + UDP mcast `225.0.0.9` | LAN | discovery + legacy LAN protocol |
| AlibabaCloud::OSS | HTTPS | Aliyun OSS bucket | object storage (gcode/thumbs/logs/timelapse), STS creds from `/oss_access` |

**Endpoints:** `cloud.sz3dp.com`, `api.voxelshare.com`, `api.fdmcloud.flashforge.com`,
`hz.sz3dp.com:11002`, `update.sz3dp.com:10443`/`update.cn.sz3dp.com:10443`,
`update.voxelshare.com/api/updates/...`, `printer2.polar3d.com`. Ports: MJPEG 8080, OrcaServer 8898,
MQTT-WSS 8083, RTMP 1935/2045, multicast 225.0.0.9, AP gateway 192.168.0.240, misc :11177.
Connectivity probe pings `8.8.8.8`; NTP `pool.ntp.org`.

**Telemetry leaving the device (cloud enabled):** device id/serial/MAC, continuous **status
uploads**, gcode+**thumbnails** to Alibaba OSS, **timelapse/delay video**, full **diagnostic logs**
(`/data/logFiles/*`), device events to FlashForge; **camera RTMP** to `livepush.flashforge.com`;
realtime IM through **NetEase (China-based)**; optional PolarCloud. MQTT is a **remote-control
surface** (print/pause/cancel/power/temp/fan/light/camera). For ReForge: killing AppClient/
FlashClient/PolarClient/MqttManager/NimManager removes off-LAN exfil; OrcaServer(:8898) +
ServerListener(225.0.0.9) + mjpg_streamer(:8080) keep LAN-only control.

## 7. Operational footprint (shell-outs)

All via `/bin/sh -c`. Camera (above) + Klipper `/opt/klipper/start.sh &`; config sync
`cp /media/printer.cfg /opt/config/...` (both ways); Wi-Fi `wpa_supplicant`/`hostapd`/`udhcpc`/
`udhcpd`/`ifconfig wlan0 192.168.0.240`, AP creds echo'd into `/etc/rtl_hostapd_2G.conf`; logs
`dmesg > /data/logFiles/...`, `core_pattern → /data/logFiles/firmwareExe.core`, `drop_caches`;
display/GPIO via `/sys/class/gpio/gpio203` + `dispdbg setbl`; packaging `tar -xvf` (updates),
`zip -r -P'…'`; signing `openssl dgst -sign`. NTP `/opt/ntpclient`. Notable:
**`mv /usr/sbin/telnetd /usr/sbin/myBin`** (telnetd ships, renamed).

## 8. Security findings (relevant to ReForge)

1. **Embedded RSA private key** (2048-bit PEM) baked into the binary, plus a `ws.cloud.flashforge.com`
   TLS leaf cert. Same across all units.
2. **Hardcoded zip password `FFP0286&*%root`** (log/data archive encryption) — static across units.
3. **`curl -k`** (TLS verification disabled) on an `authToken:`-bearing POST → MITM risk.
4. **Hardcoded internal/dev hosts left in production:** `10.33.11.172:32112`, `10.33.23.222` update
   servers; fixed RTMP `115.231.29.49:2045` with an embedded serial token.
5. **`telnetd` present** (renamed `myBin`).
6. **Wi-Fi passphrases in cleartext** via shell echo into `/etc/rtl_hostapd_2G.conf`.
7. On-disk signing keypair `/opt/key.priv`/`/opt/key.pub` (`create-rsa.sh`), pubkey `/usr/share/public.pem`.
8. Third-party data routing through **NetEase IM (China)** + **Alibaba OSS** beyond FlashForge.

Added by the deep-dives (see linked docs):
9. **OTA is MD5-only — NO firmware signature.** `system("tar -xvf")` + in-package `system(".../run.sh")`
   as root → a tampered/MITM'd package = arbitrary root code-exec. Dev HTTP update server
   (`http://10.33.11.172:32112`) shipped. (The embedded RSA private key is a **default qrc blob used
   for Polar Cloud challenge signing**, not firmware — correcting item 1's framing.)
10. **Unauthenticated LAN raw-TCP protocol on :8899** (`ServerListener`): take-control (M601),
    arbitrary gcode upload+print (M28/M23), identity leak (M115). **Unauthenticated UDP discovery**
    (225.0.0.9:8899 / bcast 19000) broadcasts serial/MAC/model/IP/cloud-bind status in cleartext.
11. **Cloud command path (MQTT) is plaintext `ws://:8083/mqtt`, no TLS, no per-command auth** — any
    broker/MITM can drive heaters/motion/power. LAN HTTP API (:8898) is the only path with an access
    check (weak serial+code).
12. **Shell-interpolated crypto** (`echo -n '<challenge>' | openssl dgst -sign`, `curl -F 'X-Amz-Signature=..'`)
    with cloud-supplied fields → command-injection surface.
13. **Hardcoded HMAC secrets in the binary** for cloud log-upload signing (`A7dK9xP2LmQ4sT8Z`,
    `s9Kf3Lx2Pq8Vn4TzA1mR6YwB`, const `model_log_upload`) → forgeable `/api/v3/model/log/upload`.
14. **Default UI credentials in config**: `admin` / `ff123456` (`Adventurer5M.json` userID/userPass).
15. **Cleartext + shell-injectable wifi**: STA/AP creds passed on `wpa_cli`/`echo` command lines and
    stored plaintext; touchscreen SSID/PSK interpolated unescaped into `system()`.

(No secret values reproduced here — presence + location only.)

## 9. Class inventory (by size)

Top app classes by method count: `MainWindow` (250), `Config` (162), `AppClient` (156),
`Print` (134), `SerialObject` (131), `MoreInfo` (101 — the engineering console), `Settings` (101),
`MachineInfo` (99), `ffupserver` (85, update server), `PolarClient` (72), `ServerListener` (67),
`OrcaServer` (60), `ShowFileList` (60), `WIFINAMESPACE` (58), `FlashClient` (46), `Keyboard` (46),
`MqttManager` (41), `InputCamera` (38), `ShowCameraPicture` (36), `UpdateManager` (35),
`NimManager` (35), `GuiderWifi` (35), `NetworkWifi`/`Language`/`GuiderLevelPrint` (33),
`UnloadFilament` (26). Library namespaces: `AlibabaCloud` (2933, OSS SDK), `boost` (729),
`Json` (370), `mqtt` (358), `httplib` (92), `ffsdk` (137, the FlashForge support layer).
