# AD5M Pro — stock Klipper hardware config

The complete printer.cfg / pin map for the AD5M Pro. **Cross-validated against three sources** (pin
map + all mechanical/electrical values are IDENTICAL across them — see "Config differences" below):
1. **Stock firmwareExe 5.1.4** — recovered verbatim from embedded config fragments in
   `/opt/PROGRAM/software/5.1.4/firmwareExe` (not stripped).
2. **Stock factory 3.1.3** — `printer.cfg`/`printer.base.cfg` from the ff5m 1.2.0 factory image
   (`vendor/stock-printer-cfg/`).
3. **forge-x live** — the on-unit `/opt/config/printer.cfg` (forge-x restructures it; values same).

Live on-device paths: `/opt/config/printer.cfg`, `/opt/config/printer.base.cfg`
(`[include printer.base.cfg]`), `/opt/config/levelPrint.cfg`. Needed to author a from-scratch
ReForge `printer.cfg`. **MCU firmware versions (v11/v13, N32G455) + the stock-vs-mod config diff:**
[`../2026-06-02-ad5m-mcu-firmware-and-config.md`](../2026-06-02-ad5m-mcu-firmware-and-config.md).

## Dual-MCU topology
Two MCUs, both **230400 baud**, `restart_method: command`:

| MCU | serial | alias | role |
|---|---|---|---|
| `[mcu]` (main) | `/dev/ttyS5` | `ttyboard` | XYZ steppers, bed heater, fans, buttons, level/probe servo, weight/TVOC sensors, Z endstop |
| `[mcu eboard]` (toolhead) | `/dev/ttyS1` | `ttyeboard` | extruder stepper, hotend heater+thermistor, X/Y endstops, ADXL345, part/heatbreak fans |

Klipper started by `/opt/klipper/start.sh &`; API socket `/tmp/printer` (+ `/tmp/uds`).

## `eboard` toolhead pin map
| Pin | Drives |
|---|---|
| `eboard:PB14` / `!eboard:PB15` / `!eboard:PB12` | extruder step / dir / enable |
| `eboard:PA8` | extruder `heater_pin` (hotend) |
| `eboard:PA0` | extruder `sensor_pin` (hotend thermistor) |
| `eboard:PB10` | extruder TMC2209 `uart_pin` |
| `!eboard:PA15` / `!eboard:PB11` | stepper_x / stepper_y `endstop_pin` |
| `eboard:PB4` | `[heater_fan heat_fan]` (heatbreak fan) |
| `eboard:PB5` | `[fan_generic fanM106]` (part-cooling fan) |
| `eboard:PA4/PA5/PA7/PA6` | ADXL345 cs / sclk / mosi / miso (software SPI) |

## Main MCU pin map
| Pin | Drives |
|---|---|
| `PC1`/`PC0`/`!PA1` | stepper_x step/dir/enable |
| `PA3`/`PA2`/`!PA6` | stepper_y step/dir/enable |
| `PC4`/`PA7`/`!PB1` | stepper_z step/dir/enable |
| `PB15` | stepper_z `endstop_pin` (Z endstop on main MCU) |
| `PC2`/`PA4`/`PC5` | TMC2209 uart X/Y/Z |
| `PB9` / `PC3` | heater_bed heater / sensor |
| `!PB4` | `[probe]` pin (inverted) — note: distinct from eboard:PB4 |
| `PA8` | `[led chamber_led]` white_pin |
| `PC6`/`PC7` | `[fan_generic chamber_fan]` pin/enable (hardware_pwm) |
| `PB7` / `PB8` / `PB6` | pcb_fan / internal_fan / external_fan |
| `!PC15` | `[gcode_button btn_power]` (press_gcode M105) |
| `PC14` / `PG1` | `[output_pin power_off]` / `clear_power_off` |
| `PG2`/`PG3`/`PG4` / `PD10` | `[output_pin level_h1/h2/h3]` / `level_clear` (assisted bed level) |
| `!PE0` | `[gcode_button check_level_pin]` |
| `!PB14` / `PE1` | `[filament_switch_sensor e0_sensor]` / `e1_sensor` (e1 unused, single extruder) |
| `PC9` | `[servo my_servo]` (probe deploy) |
| `PD5`+`PD6/7/8` | `weightValue` MAX31856 + sw SPI |
| `PD4`+`PE3/4/5` | `tvocValue` MAX31865 + sw SPI |

## Key section values (verbatim)
- **[printer]** corexy; `max_velocity 600`, `max_accel 20000`, `max_accel_to_decel 5000`,
  `max_z_velocity 25`, `max_z_accel 500`, `square_corner_velocity 25`.
- **[stepper_x]/[stepper_y]** `rotation_distance 40`, `microsteps 16`, `position_endstop 110`,
  `position_max 125`, `position_min -125`, `homing_speed 50`. **[stepper_z]** `rotation_distance 8`,
  `position_endstop 220`, `position_max 230`, `position_min -10`, `homing_speed 20`.
- **[extruder]** `rotation_distance 4.7`, `microsteps 16`, `nozzle_diameter 0.400`,
  `filament_diameter 1.750`, `sensor_type Generic 3950`, pid `Kp 20.109 Ki 1.943 Kd 52.031`,
  `min_temp -100 max_temp 350`, `min_extrude_temp 100`, `pressure_advance 0.035`,
  `pressure_advance_smooth_time 0.040`, `max_extrude_only_distance 1500`, `max_extrude_cross_section 1000`.
- **[heater_bed]** `Generic 3950`, `pullup_resistor 4700`, pid `Kp 32.79 Ki 4.970 Kd 54.118`,
  `max_temp 130`.
- **TMC2209**: X/Y `run_current 0.9`, Z `0.6/0.6`, extruder `0.8/0.8`, `sense_resistor 0.10`, interpolate.
- **[input_shaper]** `mzv` X `47.4` / Y `46.2`.
- **[bed_mesh]** `speed 300`, `horizontal_move_z 5`, `mesh_min -105,-105`, `mesh_max 105,105`,
  `probe_count 5,5`, `algorithm bicubic`, `bicubic_tension 0.2`.
- **[probe]** `pin !PB4`, `z_offset -0.25`, `speed 5`, `samples 3`.
- **[adxl345]** eboard SPI, `rate 800`. **[resonance_tester]** `5–100 Hz`, point `0,0,100`.
- **[servo my_servo]** angles 0–180, pulse 0.0005–0.0025, **`initial_angle`: 90 (factory 3.1.3) /
  115 (firmwareExe 5.1.4 + forge-x live)** — the one value that changed between fw versions.
- Misc: `[idle_timeout] timeout 600`, `[pause_resume] recover_velocity 50`,
  `[gcode_arcs] resolution 1.0`, `[virtual_sdcard] path /data/`, `[display_status]`,
  `[pid_calibrate]`, `[exclude_object]`.
- **Macros**: `[gcode_macro M900]` (K-factor→`SET_PRESSURE_ADVANCE`), `[gcode_macro M106]`/`M107`
  (fan index 101/2 → `chamber_fan`, else `fanM106`).

## Named sensors / objects
- `temperature_sensor weightValue` = **MAX31856** on `PD5`, `gcode_id W` — repurposed thermocouple
  amp as a load/"weight" channel (NOT a real temp).
- `temperature_sensor tvocValue` = **MAX31865** on `PD4`, `gcode_id V` — repurposed RTD amp as
  air-quality channel.
- `filament_switch_sensor e0_sensor` (`!PB14`, `pause_on_runout False`) — queried via
  `QUERY_FILAMENT_SENSOR SENSOR=e0_sensor`.
- Fans: `fanM106` (part, eboard:PB5), `heat_fan` (heatbreak, eboard:PB4, heater_temp 50),
  `chamber_fan` (PC6/PC7 hw_pwm), `pcb_fan` (PB7), `internal_fan` (PB8), `external_fan` (PB6).
- `led chamber_led` white_pin PA8.

## Config differences across versions
Pin map + every mechanical/electrical value (steppers, currents, PID, shaper, mesh, probe,
sensors, fans, build volume) is **identical** across factory 3.1.3, firmwareExe 5.1.4, and the
forge-x live config. The only differences are version bumps and forge-x's restructuring:

| Item | Factory **3.1.3** (ff5m 1.2.0) | firmwareExe **5.1.4** | **forge-x live** (on unit) |
|---|---|---|---|
| servo `initial_angle` | `90` | `115` | `115` |
| `[heater_bed]` location | in `printer.base.cfg` | in `printer.base.cfg` | moved into `printer.cfg` |
| chamber LED | `[led chamber_led]` white_pin PA8, hw_pwm False | `[led chamber_led]` | renamed `[led chamber_light]`, `+ cycle_time: 0.002` |
| `[fan_generic pcb_fan]` (PB7) | present | present | **removed** |
| extruder `[extruder]` PID | active (`control: pid …`) | active | **commented out** (deferred to `SAVE_CONFIG`) |
| `[input_shaper]` | active (mzv 47.4/46.2) | active | **commented out** (deferred to `SAVE_CONFIG`) |
| extra sections | — | — | `[skew_correction]`, `[include ./mod/config/stock.cfg]`, `[include ./mod_data/user.cfg]` (DEFERRED_INCLUDES), auto `SAVE_CONFIG` mesh data |

**forge-x restructuring (live config):** PID + shaper values are removed from the static cfg and
left to Klipper's `SAVE_CONFIG` autosave / a separate `mod_data/user.cfg` include, so per-machine
calibration persists independently of the base config. `heater_bed` + the chamber LED are lifted
into `printer.cfg`; `pcb_fan` is dropped; `chamber_led`→`chamber_light` (+ `cycle_time` for PWM
smoothing). Whitespace is normalized (trailing spaces trimmed). The pin assignments are untouched.

Canonical factory copies are committed at `vendor/stock-printer-cfg/` (factory 3.1.3).

## ReForge notes
- A from-scratch config must instantiate **both** `[mcu]` (`/dev/ttyS5`) and `[mcu eboard]`
  (`/dev/ttyS1`) at 230400, and keep the **endstop/MCU split**: X/Y endstops on eboard, Z endstop
  (`PB15`) + probe (`!PB4`) on main — else homing fails.
- Build volume per kinematics = **125×125×230** (the UI "220×220×220" string is marketing, not the
  cfg limits). CoreXY, single 0.4 mm direct extruder.
- `weightValue`/`tvocValue` are FlashForge repurposing SPI temp amps as generic data channels —
  drop/rename freely in a clean config.
- PID + shaper + pressure-advance values above are usable stock defaults (re-tune per machine).
