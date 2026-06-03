# firmwareExe — local printer control API (Klippy socket + eboard)

How the stock app talks to the printer locally, so ReForge can build a clean client. The app is a
**Klippy API-server client over the Unix socket `/tmp/uds`** (`serial/clientAPI.cpp` class
`ClientAPI`, wrapped by `SerialObject`). NOT Moonraker. A second `Serial` class owns the eboard MCU
UART for boot/heartbeat/load-cell only.

## Socket framing — ETX (`0x03`)-terminated JSON (Klipper api_server protocol)
- `ClientAPI::startOpen()` (`0x13aba1`): `socket(AF_UNIX,SOCK_STREAM,0)`, O_NONBLOCK,
  `connect()` to `sun_path="/tmp/uds"` (110-byte sockaddr_un), retry w/ `sleep(1)`/`select()`.
- **Every message — sent and received — is one JSON object terminated by a single `0x03` byte.**
  Send = `json + b"\x03"`. Receive = accumulate, split on `0x03` (`clientRecv` `0x13ada5` uses
  `find/rfind((char)0x03)`), parse each chunk.

## Request JSON-RPC strings (verbatim)
- **gcode/script** (`SerialObject::sendGcodeCmd` `0xa8199`):
  `{"id":<N>,"method":"gcode/script","params":{"script":"<GCODE>"}}` + `\x03`. `<N>` = incrementing
  decimal counter; match it on the reply for ack.
- **objects/query** (fixed id): `{"id": 98888888, "method": "objects/query", "params":{"objects":{…}}}` + `\x03`.
- **gcode/subscribe_output**: `{"id":<N>,"method":"gcode/subscribe_output","params":{"response_template":{"key": 99999999}}}` + `\x03`.
- **gcode/restart** and **gcode/firmware_restart** — soft / full MCU reset.

## id scheme
- `98888888` → objects/query result (state snapshot/subscription).
- `99999999` → echoed `response_template` key on every async console line.
- incrementing `<N>` → per gcode/script ack.
Dispatch: `doQueryResponse` (`0xac255`, id 98888888), `doApiResponse` (`0xad239`, console lines —
substring-matches `B:`/`T0:`/`action:paused`/`action:cancel`/`Done printing file`/`probe at`/…),
`doDelayCmd` (`0xa961d`).

## objects/query subscription set (the full state model)
| object | fields | use |
|---|---|---|
| `virtual_sdcard` | is_active, progress, file_position, file_size | print active, %, recovery position |
| `pause_resume` | is_paused | pause state |
| `fan_generic fanM106` / `fan_generic chamber_fan` | speed | part / chamber fan |
| `print_stats` | filament_used, state | FSM state |
| `toolhead` | homed_axes | homing |
| `gcode_move` | gcode_position, speed, absolute_extrude | live pos/feed/extrude-mode |
| `webhooks` | state | Klippy ready/shutdown |
| `filament_switch_sensor e0_sensor` | filament_detected | runout |
| `extruder` / `heater_bed` | temperature, target | temps |
| `temperature_sensor weightValue` | temperature | **bed load-cell** (abused temp sensor) |
| `temperature_sensor tvocValue` | temperature | **air-quality TVOC** |
| `gcode_button btn_power` | state | power button |

(Weight/TVOC come **through Klippy**, not the app's own UART.)

## Print g-code sequences (all via gcode/script)
- **start**: `M23 /data/<file>` → `M24`. (`M21` init, `M27` progress, `M220 S<pct>` speed.)
- **pause**: `M25` → `SAVE_GCODE_STATE NAME=PAUSE_state` → park `G1 X108 Y108 F3000`.
- **resume**: restore heaters → `SET_IDLE_TIMEOUT TIMEOUT=600` → `RESTORE_GCODE_STATE NAME=PAUSE_state MOVE=1` → `M24`/`RESUME`.
- **cancel**: `CANCEL_PRINT` → `M220 S100` → `G1 X100 Y100 F12000` → `SDCARD_RESET_FILE` → `SET_GCODE_OFFSET Z=0 MOVE=1`.
- **recovery (power-loss)**: read saved `file_position`, re-home, restore Z `SET_GCODE_OFFSET Z=<n> MOVE=1`,
  extrude mode `M82`/`M83`, speed `M220 S<n>`, prime `G92 E…`+`G1 … F300/F900`.
- **live**: Z `SET_GCODE_OFFSET Z=<mm> MOVE=1`, chamber fan `SET_FAN_SPEED FAN=chamber_fan SPEED=<0..1>`.

## .gx / .3mf parsing
- `.gx` = FlashForge binary `GXFileHeader` + embedded gcode (`SerialObject::seekNumOfRowsOfFile`
  `0xad87d`); layer count scans `;layer:`/`;LAYER_CHANGE`; thumbnail between markers
  **`thumbnail begin` … `thumbnail end`** → `/data/*.bmp`.
- `.3mf` plate metadata XML-ish (`<plate>`, `key="gcode_file"`, `key="thumbnail_file"`); thumbs to
  `/data/3mf/thum/<name>.png`.

## eboard `Serial` (secondary)
`/dev/ttyS1` + `/dev/ttyS5` @ **230400** (`Serial::open` `0xa16d9`, `cfsetispeed B230400`). Marlin
`ok`/`T:`/`B:` line protocol (`recvWaitOk` `0xa2e55` scans `"ok"`). Used for boot detect
(`No detected eboard mcu.`), host heartbeat, and the bed-level load cell. **Klippy owns the UART in
normal operation** — don't reimplement it.

## ReForge recipe (talk to the printer locally)
1. `connect(AF_UNIX, "/tmp/uds")`, non-blocking + `select()`, retry while Klippy starts.
2. Frame: send `json+\x03`; recv accumulate + split on `\x03`.
3. Subscribe state once: `objects/query` (or `objects/subscribe`) with the table above.
4. Console: `gcode/subscribe_output` key `99999999`; parse `B:`/`T0:`/`action:*`/`Done printing file`.
5. Send gcode: `gcode/script` with monotonic `<N>`, match reply id (reserve 98888888/99999999).
6. Print control = the sequences above. Soft reset `gcode/restart`; MCU `gcode/firmware_restart`.
7. All sensors (incl. weight/TVOC) come via objects/query — don't touch `/dev/ttyS1|S5`.

Symbols: `ClientAPI::{startOpen 0x13aba1, clientRecv 0x13ada5, clientSend 0x13a801}`,
`SerialObject::{clientOpen 0xa6c71, sendGcodeCmd 0xa8199, doQueryResponse 0xac255,
doApiResponse 0xad239, seekNumOfRowsOfFile 0xad87d}`.
