# firmwareExe — cloud remote-control command surface (security analysis)

The full cloud/app → printer command surface. Two parallel transports — **MQTT** (`MqttManager`)
and **NetEase NIM IM** (`NimManager`) — both funnel app commands into `AppClient`/`Print`/
`FlashClient`, which resolve to Klipper g-code. **The entire surface is unsigned and the MQTT link
is plaintext.**

## MQTT transport
- Broker config fetched over HTTPS from `https://api.voxelshare.com/api/v2/external/truck/device/mqtt/config`
  (auth = device SN + AuthToken; request carries `clientId: device_<SN>`). Response JSON: `mqttName`
  (user), `mqttPassword`, `gTopic` (broadcast), `pTopic` (device topic).
- **Connection URL = `ws://<host>:8083/mqtt` — plaintext MQTT-over-WebSocket.** `buildConnectOptions`
  (`0x3a6b1`) sets only user/password/clean-session/version — **never `set_ssl`/`set_trust_store`**.
  The `wss://`/`mqtts://` strings in the binary belong to the bundled paho lib and are unused.
- `subscribeTopics` (`0x3c729`) subscribes the two **server-provided** topics — whoever controls the
  config endpoint or broker controls the namespace.
- `handleRecvMsg` (`0x3da41`): JSON dispatch on `eventType` / `private_notice_message` /
  `system_notice_message` / `deviceUpdateDetail_cmd`. **Only inbound check = a `deviceID`
  self-message filter** (loop prevention, not security).

## NIM transport
`NimManager` (`nimLogin` w/ appKey+imAccount+imToken). `receiveMessage` (`0x222221`) →
`dealSubscribeMsg` → `doNimSubscribeCB`; P2P + team messages deliver the same `*_cmd` envelope into
the same `AppClient` handlers. Routes through **NetEase (China) IM cloud**.

## Command set (JSON `*_cmd` keys → action)
| cmd key | handler | printer action |
|---|---|---|
| `newJob_cmd` / `newLocalJob_cmd` | `AppClient::doNewjob` (`0x1a020d`) | download + start print (`M23 /file`) |
| `jobCtl_cmd` (`action`) | `AppClient::doPrintAction`→`Print::doAppPrintAction` (`0x12d03d`) | pause `M25`+`SAVE_GCODE_STATE`, resume `RESTORE_GCODE_STATE`, cancel `CANCEL_PRINT` |
| `temperatureCtl_cmd` | `doPrintSetControl` (`0x1a111d`) | `M104`/`M140` set/clear temps |
| `circulateCtl_cmd` | `emitCircleFanControl` | `M106`/`M107`/`SET_FAN_SPEED FAN=chamber_fan…` |
| `printerCtl_cmd`/`stateCtrl_cmd` | `doStateControl` (`0x1a0ea1`) | state ctrl (`*CtrlState` flags) |
| `lightControl_cmd` | `doLightControl` (`0x1a16d1`) | `SET_LED LED=chamber_led WHITE=0/1` |
| `streamCtrl_cmd` | `doCameraControl` (`0x1a19d9`) | camera/video stream on/off |
| `delayClose_cmd` | `doPowerOff` (`0x1a1551`) | **power off / scheduled shutdown** |
| `reName_cmd` | `doReName` (`0x1a1935`) | rename (+ may rotate AuthToken) |
| `calibration_cmd` | `doCalibration` (`0x1a1819`) | **auto-level/mesh/shaper** — homes `G28`, moves `G1` |
| `userProfile_cmd` | `doChangeUserInfo` | bound-user profile/avatar |
| `deviceUnregister_cmd` | `doRemoveFromServer`/`doExistOut` | **unbind from cloud account** |
| `upload_log_cmd` | `createUploadLogPthread` | force log upload (info disclosure) |
| `deviceUpdateDetail_cmd` | `emitUpdateDetail` | refresh device detail |

Plus OSS file-management: remote gcode/thumbnail **list/upload/delete** (`AppClient::ossInfo`,
`ossSendLocalFileList`, `ossRemoveLocalFileList`, `device/thumbnail/delete`).
`FlashClient::doCmdPause/Resume/Cancel` (`0xf22bd`/`0xf2ef9`/`0xf3391`) mirror the job controls.

## Authentication / authorization
- Device→cloud auth exists only at **registration/connection** (`/printer/register` → `AuthToken` →
  fetch MQTT/NIM creds).
- **No per-command auth on the MQTT/NIM path.** Dispatch is on the unsigned `*_cmd` key; only the
  cosmetic `deviceID` self-filter. No signature/nonce/timestamp/HMAC.
- **Transport is the only gate and it's weak**: plaintext `ws://…:8083/mqtt`, no TLS, no server-cert
  validation; broker auth = static user/pass from the config endpoint.
- (The **LAN** OrcaServer HTTP path *does* check SN+access code — see the OrcaServer doc — but that's
  local, not cloud.)

## Threat model
- A malicious/compromised broker, or a **LAN/WAN MITM on the cleartext `ws://:8083`** link, can
  inject **any** command above with no further auth → full device control incl. heaters/motion/power.
- Broker-credential compromise = total takeover.
- **Dangerous remotely-reachable, unauthenticated commands:** heaters (`temperatureCtl_cmd`→`M104`/
  `M140`, no bounds), motion (`calibration_cmd`→`G28`/`G1`; `newJob_cmd`→arbitrary gcode), power
  (`delayClose_cmd`), print integrity (`jobCtl_cmd` cancel; arbitrary gcode), takeover/DoS
  (`deviceUnregister_cmd`, `reName_cmd`), info disclosure (`upload_log_cmd`, `streamCtrl_cmd`).

**Bottom line:** heaters, motion, power, calibration, and deregistration are all dispatched on an
unsigned JSON `cmd` key over a cleartext non-TLS MQTT-over-WebSocket link with no per-command auth.
For ReForge: disabling the cloud actors (AppClient/FlashClient/PolarClient/MqttManager/NimManager)
removes this entire remote surface; LAN control (OrcaServer 8898 + the SN/access-code gate) can stay.
