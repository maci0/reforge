# firmwareExe — OrcaServer LAN HTTP API (port 8898)

The in-process cpp-httplib server (`common`/`httplib/orcaServer.cpp`) the stock app exposes for
OrcaSlicer / LAN clients. Binds **port 8898** in `OrcaServer::doOrcaServer()` (`0x1b47b9`, port
literal `0x22c2` at `0x1b4d88`; started by `MainWindow::doStartOrcaServer`). A complete reference
for building a **cloud-free local controller**.

## Routes (all POST)
| Path | Handler | Auth | Purpose |
|---|---|---|---|
| `/checkCode` | `request_check_code` (`0x1b5ae9`) | inline | handshake: verify SN+access code |
| `/detail` | `request_detail` (`0x1ba4ed`) | `check_sn_access` | full live telemetry (key `detail`) |
| `/product` | `request_product` (`0x1b802d`) | `check_sn_access` | control-capability flags (key `product`) |
| `/control` | `request_control` (`0x1b62f9`) | `check_sn_access` | **universal command endpoint** |
| `/gcodeList` | `request_gcode_list` (`0x1b9721`) | `check_sn_access` | list `/data` `.g/.gx/.gcode/.3mf` (key `gcodeList`) |
| `/gcodeThumb` | `request_gcode_thumb` (`0x1bdcb5`) | `check_sn_access` | thumbnail of a named file (key `imageData`) |
| `/printGcode` | `request_print_gcode` (`0x1bc145`) | `check_sn_access` | start a print of a `/data` file |
| `/getThum` | `request_get_thum` (`0x1b89bd`) | inline | thumbnail of currently-printing file (raw bmp) |
| `/uploadGcode` | `request_upload_gcode` (`0x1bc935`) | inline | multipart gcode upload → `/data/` |
| `/notifyWanBind` | `request_notifyWanBind` (`0x1b9fbd`) | SN only | cloud-bind notify |

(`/printer/register` and `/printer/status` are **outbound** CloudClient calls to FlashCloud, NOT
served LAN routes.)

## Response envelope
JSON via `Json::FastWriter`: keys `code`, `message`, and a payload key (`data`/`detail`/`product`/…).
Success `message="Success"`. Content-Type literal is the misspelled `appliation/json`. Errors:
`Lan mode error`, `SN is different`, `Access code is different`, `Parameters is error`,
`Printer is Busy.`, `File does not exist.`, `page not found`.

## Auth — `OrcaServer::check_sn_access` (`0x1b5275`)
1. Requires **LAN mode enabled** (`Config::getLanModeStatus`; toggle `OrcaServer::setLanMode`) else
   `Lan mode error`.
2. Body parsed as JSON under key **`jsonData`**.
3. Validates `serialNumber` == device serial → else `SN is different`.
4. Validates `checkCode` == `Config::getLanModeCode()` (the LAN access code) → else
   `Access code is different`.

**Weak shared-secret auth**: serial number (also broadcast in cleartext via multicast / M115) + a
static access code in the JSON body. No TLS, no session token, no nonce/HMAC. Anyone who knows the
SN + access code has full control.

## `/control` command table
Body: `{ "payload": { "cmd": "<name>", "args": {...} } }`. Commands → Qt signals → SerialObject:
| cmd | args | action |
|---|---|---|
| `lightControl_cmd` | `status` | chamber LED on/off |
| `circulateCtl_cmd` | `status{internal,external}` | filter fans |
| `temperatureCtl_cmd` | `platform,rightNozzle,leftNozzle,chamber` | set temps |
| `printerCtl_cmd` | `zAxisCompensation,speed,chamberFan,coolingFan` | live print adjust |
| `jobCtl_cmd` | `jobID,action` | pause/resume/cancel |
| `delayClose_cmd` | `automaticShutdown,shutdownAfterTime` | power-off / scheduled |
| `reName_cmd` | `name` | rename printer |
| `calibration_cmd` | `levelingDetection,vibrationCompensation` | leveling/shaper |
| `streamCtrl_cmd` | — | camera on/off |
| `userProfile_cmd` | `avatar,name` | bound-user profile |
| `stateCtrl_cmd` | — | printer state control |

## Key routes detail
- **/detail** returns: nozzle/plat/chamber temps + targets, fan/door/light status, `autoShutdown`,
  `tvoc`, `cumulativePrintTime`, `cumulativeFilament`, `remainingDiskSpace`, register codes,
  `errorCode`, `status`, `cameraStreamUrl` = `http://<ip>:8080/?action=stream`, and current-job
  fields (file name/thumb, progress, layers, speed, filament estimates).
- **/gcodeList** lists `/data` filtered to `.g/.gx/.gcode/.3mf`.
- **/gcodeThumb** body `fileName` → `/data/3mf/thum/<name>.png` or `/data/<name>.bmp`.
- **/printGcode** body `fileName` + `levelingBeforePrint` → `sig_cloudstartprint`.
- **/uploadGcode** multipart, file field **`gcodeFile`**, fields `serialNumber,checkCode,fileSize,
  printNow,levelingBeforePrint`; writes to `/data/<name>` then `echo 3 > /proc/sys/vm/drop_caches`;
  if `printNow` starts the print.

## Building a cloud-free local controller
- Base `http://<ip>:8898`, all POST + JSON (multipart for upload). Camera MJPEG at
  `http://<ip>:8080/?action=stream`.
- Enable **LAN mode** on the printer, note the **access code** (`Config::getLanModeCode`).
- Send `serialNumber` + `checkCode` in the body (gated routes expect them under `jsonData`).
  Verify with `/checkCode` first.
- Control via `/control`; start prints `/printGcode`; files `/gcodeList`/`/gcodeThumb`/`/uploadGcode`;
  poll `/detail`.
