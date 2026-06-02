# AD5M vs AD5M Pro — stock firmware delta

READ-ONLY research note. No repo source modified. Proprietary blobs referenced by
path + sha256, never copied into tracked locations.

**TL;DR:** The base Adventurer 5M and the 5M Pro run **the same firmware codebase on the
same SoC (Allwinner T113-S3), the same dual-MCU board (mainboard + `eboard`), the same
Klipper `printer.base.cfg`, and the same `firmwareExe` family**. The two models are *not*
separated by distinct hardware-config files or a Pro-only MCU. They differ by:

1. a **build-time model identity** baked into `firmwareExe` (the literal
   `Machine Type: Flashforge Adventurer 5M` vs `… Adventurer 5M Pro`, plus a Pro/base UI skin),
2. an **OTA channel gate** (`MACHINE` + USB `PID`) in `flashforge_init.sh`, and
3. **runtime feature flags in the per-machine JSON** (`/opt/config/Adventurer5M.json`) that
   enable/disable the camera, air filter, external fan, dual filament sensors, etc.

All the "Pro-sounding" hardware objects (chamber fan, `adxl345` input-shaping accel,
`weightValue` MAX31856 load cell, `tvocValue` MAX31865 air-quality sensor, dual filament
sensors, chamber LED) are present in **both** models' configs and binaries; they are gated
on/off at runtime, not by model. One ReForge image can serve both. → see §5.

---

## Evidence sources (by path + hash)

| role | artifact | provenance |
|---|---|---|
| **base 5M** rootfs (pristine stock, 3.1.3) | `tools/recovery/archive/Adventurer5M-factory.tar.xz` (sha256 `06375d…632e1`) | community dump (ghzserg) |
| base 5M `firmwareExe` (3.1.3) | inside ↑ at `opt/PROGRAM/software/3.1.3/firmwareExe` — sha256 `53ef28ff…bf9a4` | — |
| **Pro** app overlay 3.1.3 / 5.0.3 / 5.1.2 / 5.1.4 | `fw-analysis/pro-<ver>.tgz` → `software-<ver>.tar.xz` | FF-official OTA (re-hosted) |
| Pro `firmwareExe` 3.1.3 | `fw-analysis/sw-3.1.3/firmwareExe` — sha256 `473c0aa2…266c76` | — |
| Pro `firmwareExe` 5.1.2 | `fw-analysis/sw-5.1.2/firmwareExe` — sha256 `ce817fc5…34cf081` | — |
| Pro base rootfs (forge-x-modified golden) | `tests/qemu-harness/build/stock-clean-rootfs.ext4` | local golden (debugfs) |
| ReForge overlay cfg | `br-external/board/reforge/rootfs-overlay/etc/reforge/printer.base.cfg` | repo |

**Caveat on the Pro `printer.base.cfg`:** the only locally-available Pro *base rootfs* is the
**forge-x-modified** `stock-clean-rootfs.ext4` — its `printer.cfg` carries
`[include ./mod/config/stock.cfg]` and `[include ./mod_data/user.cfg]`, so its
`printer.base.cfg` has been edited by forge-x (heater_bed relocated into `printer.cfg`,
`[controller_fan driver_fan]` added, `chamber_led`/`pcb_fan` removed from base, servo
`initial_angle` 90→115). The FF OTA `software-*.tar.xz` overlays carry **no** printer cfg /
model JSON at all (verified: they contain only `firmwareExe`, `client/`, `network/`, scripts)
— those live in the factory-programmed base rootfs. So the **apples-to-apples model delta**
below is taken from the **pristine base-5M factory cfg** + the **same-version (3.1.3)
firmwareExe string diff**, not from the forge-x-touched Pro ext4.

---

## 1. Hardware / firmware deltas

The pristine **base-5M** `opt/config/printer.base.cfg` already contains the full hardware
suite. There is **no separate "Pro" base.cfg** in any locally-available pristine artifact; the
same object set appears in the forge-x Pro golden and in the ReForge overlay. Objects present
in the base 5M stock cfg:

| capability | klipper object / pins (base-5M stock) | Pro-only? |
|---|---|---|
| Build volume | `position_max: 125` X/Y, Z `position_max: 230`; `bed_mesh` mesh ±105; `corexy` | **No** — identical 220×220×220 class on both |
| Hotend | `[extruder] max_temp: 350`, `rotation_distance: 4.7`, `tmc2209 extruder run_current 0.8` (in `printer.cfg`) | **No** — same 300 °C-class hotend, same `extruderType "0.4-300"` JSON |
| Chamber fan | `[fan_generic chamber_fan] pin:PC6 hardware_pwm:True enable_pin:PC7` | **No** — present in base cfg |
| Chamber heater | only a `verify_heater`/error string `chamber_heater not heating…` in binary; **no `[heater_chamber]` block** in either cfg | n/a — **neither model has an actively-heated chamber**; "chamber" = passive enclosure + fan + circulation |
| Internal/external fan (circulation/filter) | `[fan_generic internal_fan] pin:PB8`, `[fan_generic external_fan] pin:PB6` | **No** — both have the pins; runtime-gated by JSON `internalFan`/`externalFan`/`filterAir` |
| ADXL345 (input shaping) | `[adxl345] cs_pin: eboard:PA4` (+ sw SPI on eboard), `[resonance_tester]` | **No** — on `eboard` for both models |
| Load cell (weight) | `[temperature_sensor weightValue] sensor_type: MAX31856 sensor_pin: PD5 … gcode_id: W` | **No** — present in base cfg (used for the strain-gauge bed-touch probe / `load_cell_tare`) |
| Air-quality / TVOC | `[temperature_sensor tvocValue] sensor_type: MAX31865 sensor_pin: PD4 … gcode_id: V` | **No** — present in base cfg too |
| Filament runout | `[filament_switch_sensor e0_sensor] switch_pin: !PB14` + `[filament_switch_sensor e1_sensor] switch_pin: PE1` (dual) | **No** — both have both sensors; JSON gates each (`leftFilamentDetect`/`rightFilamentDetect`) |
| Probe / auto-level | `[probe] pin: !PB4`, three `output_pin level_h1..h3` (PG2/3/4), `[servo my_servo] pin:PC9` | **No** — identical |
| Camera | `getCameraExist == true` + `mjpg-streamer` in both binaries | **No binary gate** — runtime JSON `cameraInfo.cameraStatus` |
| Power button / soft power-off | `[gcode_button btn_power] pin:!PC15`, `[output_pin power_off] PC14`, `clear_power_off PG1` | **No** — identical |

**Net:** no Klipper object is *exclusive* to the Pro at the config level. The Pro's
marketing differentiators (camera, internal/external filtration fans, IP-cam streaming) are
**the same hardware pins gated by JSON flags**. The accelerometer, load cell, dual filament
sensors and chamber fan are on **both** boards.

---

## 2. MCU / Klipper config

**Both models are dual-MCU** — this is the most important structural finding, and the
`eboard` is **NOT** Pro-only:

```
[mcu eboard]      # toolhead/extruder board
serial: /dev/ttyS1
baud: 230400
[mcu]             # mainboard
serial: /dev/ttyS5
baud: 230400
```

The extruder, its TMC2209, the toolhead ADXL345, the heat-break fan, and the part-cooling
fan all hang off `eboard:` pins (`step_pin: eboard:PB14`, `adxl345 cs_pin: eboard:PA4`,
`heater_fan pin: eboard:PB4`, `fan_generic fanM106 pin: eboard:PB5`), identically on base 5M
and Pro. Mainboard carries the XY/Z steppers, bed, chamber/internal/external fans, probe,
servo, load cell (MAX31856 on PD5–PD8) and TVOC (MAX31865 on PD4/PE3–PE5).

Stepper currents (TMC2209, `sense_resistor:0.10`) — identical across models:
`stepper_x`/`stepper_y` `run_current: 0.9`, `stepper_z` `run_current/hold 0.6`,
`extruder` `run_current/hold 0.8`. Endstops: X `!eboard:PA15`, Y `!eboard:PB11`, Z `PB15`.

**No Pro-only MCU object exists.** The MCU firmware shipped in the OTA `control-*.tar.xz`
(`Mainboard.bin` + `Eboard.hex`) is the **same version `control-2.2.3`** across every Pro OTA
(3.1.3 → 5.1.4), and matches what the base-5M base rootfs expects.

---

## 3. Software / version differences

### One multi-model binary, build-time model identity

`firmwareExe` is a single Qt/C++ app that contains **both** models compiled in. Proof — same
version (3.1.3), base-5M vs Pro, string diff:

* base-5M binary literal: `Machine Type: Flashforge Adventurer 5M`; Pro binary literal:
  `Machine Type: Flashforge Adventurer 5M Pro`. Each build hard-codes exactly one.
* **but** the base-5M binary still contains the Pro UI assets (`morePro.png`, `bedPro.png`,
  `extruderPro.png`, `homeInfoPro.png`) and the Pro binary contains the base assets
  (`changeFilament.png`, `ad5m.png`). The widget objects `widgetADM` and `widgetADMPRO`
  exist in both. So the UI skin is selected from a model flag, with both skins present.
* Pro-only strings at 3.1.3 are essentially: the `Adventurer5Mpro` / `Adventurer 5M Pro`
  machine literals, the extra Pro icon variants (`changeFilamentPro.png`, `loadStepPro.png`,
  `ad5mpro.png`, `ADMPro.png`), and a fan-icon set. **No Pro-only hardware/driver code.**
* Config-file path is the **same** for both: the binary opens
  `/opt/config/Adventurer5M.json` (class `GetConfigFile` / `getConfigFile()`) regardless of
  model — there is *no* `Adventurer5MPro.json` path in either binary.

The total raw string delta (~960 lines each way at 3.1.3) is dominated by compiler/RTTI
artifacts and UI asset naming, not feature code; camera, polar-cloud, flash-cloud, chamber
fan, `weightValue`, `tvocValue` strings are **byte-identical present in both**.

### Version maps (Pro OTA line; `fw-analysis/pro-*.tgz`)

| OTA | software | library | kernel | control (MCU fw) |
|---|---|---|---|---|
| 3.1.3 | 3.1.3 | 2.3.0 | 2.1.6 | 2.2.3 |
| 5.0.3 | 5.0.3 | 2.5.0 | 2.1.6 | 2.2.3 |
| 5.1.2 | 5.1.2 | 2.5.0 | 2.1.6 | 2.2.3 |
| 5.1.4 | 5.1.4 | 2.5.0 | 2.1.6 | 2.2.3 |

Kernel (`2.1.6`) and MCU control fw (`2.2.3`) are pinned across the whole 3.x→5.x range;
only `software`/`library` advance. The base 5M factory tar is on the `3.1.3` software line
(same `software-3.1.3` app + `control-2.2.3` MCU fw).

### OTA channel gate (the real model separation point)

`flashforge_init.sh` inside each Pro OTA hard-codes the channel identity and refuses a
mismatched package:

```sh
MACHINE=Adventurer5MPro
PID=0024
...
if [ "$1" != "${MACHINE}" ] || [ "$2" != "${PID}" ]; then
    echo "Firmware does not match machine type."; exit 1
fi
SSID_NAME="Adventurer5M Pro"
```

So the **Pro OTA is gated to `Adventurer5MPro` / USB-PID `0024`**. The base 5M uses a
different USB-PID identity (the binaries' log-zip password is `FFP0286`, i.e. product 0286,
on both; the OTA `MACHINE`/`PID` pair is the authoritative model gate). The check is skipped
when `/opt/screwflag` (factory/jig flag) exists. **Practical consequence:** you cannot flash a
base-5M OTA onto a Pro or vice-versa through the stock path — the installer enforces the
`MACHINE`+`PID` match even though the underlying binary supports both.

---

## 4. Cloud / feature flags

All cloud/connectivity features are **identical code in both binaries**, gated by the
per-machine JSON (`/opt/config/Adventurer5M.json`), not by model:

* `cameraInfo.cameraStatus` (mjpg-streamer / `getCameraExist`), `cameraVideo`
* `flashcloud.flashCloudStatus` + `flashCloudServerUrl: https://cloud.sz3dp.com`
* `polarcloud.polarCloudStatus` (+ `connectedPolarCloud`/`polarCloudStart` in both binaries)
* `network.*` (wifi station/hotspot, ethernet), `webConsole` (default `admin`/`ff123456`)
* `general.filterAir`, `internalFan`, `externalFan`, `leftFilamentDetect`,
  `rightFilamentDetect`, `lcdProtect`, `ledStatus`, `buzzerStatus`

Cloud endpoints (`update.flashforge.com`, `cloud.sz3dp.com`, `api.fdmcloud.flashforge.com`,
RTMP `rtmp://115.231.29.49:2045/Adventurer5M/<serial>`) appear in both. There is **no
Pro-exclusive cloud/camera capability** — the Pro simply ships with the camera physically
populated and `cameraStatus:true` by default, while the base 5M ships camera-absent
(`cameraStatus:false`). The three bundled JSON templates illustrate the defaults:
`Adventurer5M.json` (the live one), `guider3Ultra.json` (`filterAir:true`, name
"Adventurer 5 M"), `ad5m.json` (name "Guider 3 Ultra") — these are FF's internal
machine-profile templates, all sharing the same schema.

---

## 5. Implication for ReForge

**One ReForge image can serve both models.** The repo already does this: a single
`br-external/board/reforge/rootfs-overlay/etc/reforge/printer.base.cfg` carries the full
object set (`[mcu]` + `[mcu eboard]`, `chamber_fan`, `internal_fan`, `external_fan`,
`adxl345` on eboard, `weightValue`/MAX31856 load cell, `tvoc`/MAX31865, `e0_sensor`/
`e1_sensor`, `corexy`) — i.e. the same superset both stock models use.

What ReForge must keep in mind:

1. **No per-model klipper fork needed.** Pins, currents, kinematics, dual-MCU layout, and
   sensor wiring are identical. ReForge's single `printer.base.cfg` is correct for both. (Its
   tighter `position_max: 110.1` / `homing_speed: 25` / `second_homing_speed` values are a
   ReForge tuning choice, not a model split.)

2. **Feature presence is per-unit, not per-model.** Camera, filtration fans, and the second
   (`e1`) filament sensor may be physically absent on a given base-5M unit. ReForge should
   treat these as **soft/optional** (mirror the stock JSON-flag behaviour: don't hard-fail if
   the camera or `e1_sensor` is unpopulated), rather than branching on "Pro vs base."

3. **There is no actively-heated chamber on either model** — only a passive enclosure + the
   `chamber_fan`/circulation fans. Don't expose a `[heater_chamber]`.

4. **Installer / OTA identity.** If ReForge ever rides the stock OTA path or emits a
   stock-compatible package, it must honour the `MACHINE`+`PID` gate
   (`Adventurer5MPro`/`0024` for the Pro; the base 5M uses its own pair). ReForge's own
   installer (`packaging/flashforge_init.sh`) replaces this flow, so for a ReForge-native
   install the gate is moot — but cross-model artifacts must still target the right
   `MACHINE`/`PID` if interacting with stock recovery.

5. **Build-volume / hotend deltas: none.** Both are ~220×220×220, 300 °C-class single hotend,
   CoreXY. No volume or thermal config change between models.

**Bottom line for ReForge:** ship **one image + one `printer.base.cfg`** for both AD5M and
AD5M Pro; make camera and the optional fans/second-runout-sensor runtime-optional; do not
assume a heated chamber; only the OTA/recovery `MACHINE`/`PID` identity needs to be
model-correct when touching the stock update path.
