# firmwareExe — UI / i18n / misc classes

The remaining UI subsystems (Qt 4.8.6 `QDialog`/`QWidget` singletons, `instXxx` static members,
`:/res/...` qrc resources). App version `5.1.4 20260514`.

## Keyboard (`UI/keyboard.cpp`)
On-screen keyboard, the single chokepoint for all text/PIN/password/temp entry. Three layouts
(`displayMode`): letter (caps via `CapKeyCode`/`LowerKeyCode`/`SpecialCode`), number/decimal,
symbols. Password show/hide. Commits via `on_pushButton_Enter_clicked` → signal `sendData(QString)`.

## Language / i18n (`dialog/language.cpp`)
12 languages: english, chinese-cn, chinese-tra, german, french(`btnFrence`), russian, spanish,
turkish, italiano, japanese, korean, portuguese. `confirmLanguage(Language_Type)`. **Translations
are qrc resources `:/res/language/firmware_<lang>.qm`** loaded via `initTranslator()` (no on-disk
override). Persisted as `printerLanguage` (`Config::get/setPrinterLanguage`); `chooseLanguage` re-runs
at boot. ReForge: add a lang = inject `firmware_<code>.qm` into qrc + extend `Language_Type`.

## Scanner (`UI/scanner.cpp`)
**USB barcode/HID-scanner** input handler (not QR/network). Enumerates `/sys/class/input/event*/
device/name`, finds device named **`Barcode Reader`**, opens `/dev/input/event<N>`, reads evdev
`EV_KEY` scancodes → `init_keymap()` → assembles `scanStr` → signal `sig_showScanStr`. No length
bound — feeds whatever the HID scanner types into app fields.

## WeightAdjust (`dialog/weightAdjust.cpp`)
Manual load-cell calibration — the bed force sensor read as Klipper `temperature_sensor weightValue`
(MAX31856), shown via `getWeightValue()`. Jog Z (`goMove`/`on_moveUp/Down`), three-point pins
`SET_PIN PIN=level_h2/h3 VALUE=1/0`. Persists `extruderCalibrationValue`/`nozzleTempDifferentValue`.

## License (`UI/license.cpp`)
`showLicenses()` loads `:/res/icon/info/licenses.txt` (Qt/LGPL, paho-MQTT, boost, Klipper GPLv3) into
a read-only viewer. **Gates nothing** — no EULA-acceptance flag, purely informational.

## Parameter dialogs
- **SetTempDialog** (`SetTempType`) — numeric keypad + steppers + `on_stop_clicked`; target =
  extruder/heater_bed/chamber; signal `sig_sendValue(int)`.
- **CustomTemp** — user custom temp preset (same keypad).
- **SetParameter** — slim +/- stepper (e.g. fanSpeed).
- **SetFanDialog** — `SET_FAN_SPEED FAN=chamber_fan/pcb_fan/internal_fan/level_pin SPEED=…`,
  model cooling `M106 S255 T0`.

## Guider first-run wizard
First-boot (`isFirstLogin` → `showGuiderStart`): **GuiderStart → GuiderQrencode → GuiderFilament →
GuiderLevelPrint → GuiderPrintState → GuiderComplete**, each `on_drop_clicked` to skip.
- GuiderLevelPrint (heavy): `homeFirst`, `doAutoCalibration`/`doAutoCalibrationMesh` (bed mesh),
  `doZCalibrationShowUI`, input-shaper test (`doStartShaper`, `doRecommendX/Y` resonance freqs),
  then `saveCfg`/`startSavePrinter`.
- GuiderPrintState runs `/data/Cube-PLA-Test.gcode` validation print.

## QrencodeApp / GuiderQrencode (`UI/qrencodeApp.cpp`)
Cloud-binding QR. `createQrencode()` builds JSON `{sn, name, version="5.1.4 20260514",
modelName="Adventurer 5M Pro"}` → **`rsaEncrypt`** (`:/res/icon/main/rsapub.pem` / `/usr/share/public.pem`,
`RSA_public_encrypt` PKCS#1v1.5) → base64 → QR. For Flash Studio / VoxelShare account binding.
`invertAndAddFive` obfuscation in the handshake. Unbind → `/firmware/unregister`. The QR leaks
SN/name/version/model to anyone with the matching private key.

## ExtruderTypeInfo (`dialog/extruderTypeInfo.cpp`)
Nozzle diameter select: **0.25 / 0.4 / 0.6 / 0.8 mm** → `confirmTypeInfo` → config `extruderType`
(default `0.4-300`) + Klipper `nozzle_diameter:` + per-nozzle TMC currents.

## Other
- **DrawWidget** (`dialog/drawWidget.cpp`) — Klipper **exclude_object** UI: render object map, tap to
  cancel (`EXCLUDE_OBJECT NAME=<…>`, config `[exclude_object]`).
- **ShowBigPicture** — full-screen gcode thumbnail viewer + export-to-USB + delete.
- **MakeImg** — extracts the gcode `; thumbnail begin/end` image for previews.

## Cross-cutting
- Default creds `admin`/`ff123456` in config (`userID`/`userPass`).
- All UI ultimately drives Klipper via the single `objects/query` subscription + gcode macros
  (`SET_PIN`, `SET_FAN_SPEED`, `M106`, `EXCLUDE_OBJECT`).
