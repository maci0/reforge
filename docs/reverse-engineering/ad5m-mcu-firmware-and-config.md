# AD5M MCU firmware (v11 / v13) & config baselines

**Date:** 2026-06-02 (revised 2026-06-04: stock-config source corrected to the
3.1.3 OTA tar root; verified against 5.0.3 / 5.1.2 / 5.1.4 OTAs which dropped it)
**Status:** reference — informs ReForge's printer config + the v11↔v13 switch design.
**See also:** [`ad5m-pro-klipper-hardware-config.md`](ad5m-pro-klipper-hardware-config.md)
— the complete MCU pin map / printer.cfg section values (cross-validated 3 sources).

This documents (1) what the "v11" / "v13" MCU firmware versions are and how the two
reference mods (xblax, ZMod) handle them, (2) the authoritative **stock** AD5M Klipper
config — pulled directly from the stock **3.1.3 OTA tarball** and cross-validated
against the eMMC dump — and (3) a parameter-level diff of stock vs xblax (v13) vs
ZMod (v11) vs ReForge — so ReForge's config can be put on a correct, deliberate
footing instead of the hybrid it inherited.

Sources (in order of authority for the stock config):
1. **The stock 3.1.3 OTA tarball** (`pro-3.1.3.tgz`, FlashForge production image) —
   ships `printer.cfg` + `printer.base.cfg` at the **tarball root**, alongside
   `software-3.1.3.tar.xz` / `control-2.2.3.tar.xz` / `kernel-2.1.6.tar.xz` /
   `library-2.3.0.tar.xz`. This is the **authoritative stock AD5M MCU config** —
   no eMMC dump required. (See §2 below for how to pull it.)
2. The full factory rootfs `tools/recovery/archive/Adventurer5M-factory.tar.xz`
   (`opt/config/printer.cfg` + `printer.cfg.tmp` + `printer.base.cfg`) — agrees
   byte-for-byte with (1).
3. The golden eMMC dump `tools/recovery/golden.img.gz` (`p6:/opt/config/`) —
   agrees with (1) and (2).
4. The local pristine snapshot at `reference/ad5m-factory-config/` (extracted
   from (2)) — also byte-identical to (1).
5. On-device forge-x config at `192.168.0.158:/opt/config` (the same stock config,
   restructured + recalibrated — see §5).
6. Upstream repos `xblax/flashforge_ad5m_klipper_mod` + `ghzserg/zmod`
   (cloned 2026-06-02) + Klipper `docs/Config_Changes.md` @ `v0.13.0`.

The **later** stock OTAs **dropped** the root-level `printer.cfg`/`printer.base.cfg` —
they only ship the executable + library + control bundles, expecting the config
already on the device's eMMC. Verified by `tar -tf` across every Pro OTA we hold
(2026-06-04):

| OTA | Ships `printer.cfg` at tar root? | Inside `software-*`/`library-*`/`control-*`? |
|---|---|---|
| `pro-3.1.3.tgz` | **yes** (`./printer.cfg` + `./printer.base.cfg`) | n/a (already at root) |
| `pro-5.0.3.tgz` | no | no |
| `pro-5.1.2.tgz` / `ff-pro-5.1.2-factory.tgz` | no | no |
| `pro-5.1.4.tgz` | no | no |

So 3.1.3 is the **only** OTA that carries the config standalone — the
canonical pull-from-tarball source. From 5.0.3 onward the Klipper config has
to come from the eMMC dump or from this 3.1.3 baseline.

---

## 1. MCU firmware versions: v11 vs v13

- The AD5M has **two STM32-class MCUs**, both **Nationstech N32G455** (a GD32/STM32-F4
  work-alike — not a stock Klipper target, which is why the mods reverse-engineered the
  port): `mcu` = mainboard (`/dev/ttyS5`), `eboard` = toolhead (`/dev/ttyS1`), both 230400.
- "**v11 / v12 / v13**" are upstream **Klipper MCU protocol/firmware versions** (`0.11`,
  `0.12`, `0.13`). Native (stock FlashForge) firmware:
  - **FF5M / FF5M Pro → Klipper 11**
  - **AD5X → Klipper 12**
  - **Klipper 13** is what the mods can flash.
- The stock MCU firmware reports build `?-20230317_182329-ubuntu20-virtual-machine` — that
  string **identifies native v11/v12**. Our device reports exactly this ⇒ **the AD5M Pro is
  on native v11.**
- **The protocol skew that bit us:** `query_adxl345` parameter list changed between
  Klipper v0.10 and v0.11 — a `clock=%u` parameter was inserted before `rest_ticks=%u`:
  - v0.10 MCU: `query_adxl345 oid=%c rest_ticks=%u`
  - v0.11+ host/MCU: `query_adxl345 oid=%c clock=%u rest_ticks=%u`
  - **Corrected 2026-06-04** (see `docs/research/2026-06-04-klipper-v0.11-fork-deltas.md`
    §3 for the source-level verification): an earlier version of this note had v0.11 and
    v0.13 on opposite sides of the change. They are not — the `clock=%u rest_ticks=%u`
    format has been the protocol since v0.11.0 (verified in both upstream Klipper3d/klipper
    v0.11.0 `klippy/extras/adxl345.py` and `src/sensor_adxl345.c`, and identical in the
    FlashForge AD5M fork). A v0.13 host against a v0.11 MCU does **not** mismatch on
    `query_adxl345`.
  - Whatever "Command format mismatch" was historically observed against the AD5M
    MCU likely came from running a v0.10-era host (or a fork carrying an old
    sensor_adxl345 cmd registration). Everything else (steppers, heaters, thermocouples,
    both MCUs' 105 commands) matches fine across the v0.11→v0.13 boundary.

### Where the stock MCU firmware lives (we hold it)
The stock OTA `control-2.2.3.tar.xz` ships the **MCU firmware binaries + the N32G455
flasher**:
- `Mainboard-20230831.bin`, `Eboard-20231012.hex` (the v11 MCU firmware; the `2023083x`/
  `2023101x` filename dates are OTA *packaging* dates — the Klipper build string baked into
  the running firmware is `20230317`, which is what identifies it as native v11)
- `NationsCommand`, `IAPCommand`, `mcu.img` (the N32G455 IAP flash tooling)

So we have the v11 binaries and the flash mechanism in-hand. v13 binaries come from
xblax/ZMod and flash via the same IAP path.

### How the two mods handle the version
| | **xblax** (`flashforge_ad5m_klipper_mod`) | **ZMod** (`ghzserg/zmod`) |
|---|---|---|
| MCU firmware | **Auto-flashed to v0.13** at install (auto-downgraded to stock on uninstall / dual-boot) | **Native v11** (FF5M/Pro) / v12 (AD5X) by default |
| Host Klipper | v0.13 (`v0.13.0-285`) | matched to native v11 by default; v13 **opt-in** |
| Switch mechanism | none — transparent, always v13 | `UPDATE_MCU [FORCE=11/12/13]`; runtime flag `klipper13=1` in `mod_data/variables.cfg` |
| Per-version printer.cfg | single v13 config | **single config for both** — only the MCU firmware + host Klipper binary swap; revert = delete `klipper13=1` + power-cycle |
| Risk posture | "fully removable", auto MCU downgrade | explicit warnings; `FIX_UPDATE_MCU`, `FIX_KLIPPER`, USB native re-flash |

**Coupling rule (ZMod):** if on Klipper 13 you must run `UPDATE_MCU` before updating stock
firmware or removing the mod, else the MCU is left on 13 while the host expects native →
mismatch.

---

## 2. Where the stock printer config actually is

**The authoritative source is the stock 3.1.3 OTA tarball.** `pro-3.1.3.tgz`
ships `printer.cfg` + `printer.base.cfg` at the **root** of the outer tar
(alongside `boot.img`, `flashforge_init.sh`, `software-3.1.3.tar.xz`,
`control-2.2.3.tar.xz`, `kernel-2.1.6.tar.xz`, `library-2.3.0.tar.xz`). Pull it
standalone with no eMMC reader / no `dd`:

```sh
tar -xf pro-3.1.3.tgz ./printer.cfg ./printer.base.cfg
```

Verified byte-identical against (a) the eMMC dump at `p6:/opt/config/` and
(b) the full rootfs at `tools/recovery/archive/Adventurer5M-factory.tar.xz`
`opt/config/{printer,printer.base}.cfg`. The committed pristine snapshot at
`reference/ad5m-factory-config/` is also byte-identical to the 3.1.3 OTA copy
(verified `2026-06-04`).

**Why 3.1.3 specifically:** FlashForge **dropped** the root-level `printer.cfg`
in every later OTA — verified by `tar -tf` on `pro-5.0.3.tgz`, `pro-5.1.2.tgz`,
`ff-pro-5.1.2-factory.tgz`, and `pro-5.1.4.tgz`: **none of them** contain a
`printer.cfg` or `printer.base.cfg`, at the tar root or inside any of the inner
`software-*` / `library-*` / `control-*.tar.xz` bundles. Those packages ship
only `firmwareExe` + libs + control (MCU binaries) and expect the config already
on the eMMC. 3.1.3 is therefore the **only** self-contained tarball that carries
the printer config standalone, and the canonical recoverable-without-an-eMMC-reader
stock baseline.

`ff-pro-unbrick.tgz:img/factory-config.raw` is a **proprietary per-unit
calibration blob** (not Klipper) — not what we want here.

**Config structure on device:** `printer.cfg` = `[include printer.base.cfg]` +
`[include ./mod/config/stock.cfg]` + `[heater_bed]`/`[extruder]` overrides +
`[include ./mod_data/user.cfg]` + a `SAVE_CONFIG` block (calibrated PID / bed_mesh /
input_shaper). The big hardware definition lives in `printer.base.cfg`.

Note: on-disk `printer.cfg` is the v11 native variant; the 3.1.3 tar root also
carries `printer.cfg.tmp` (intermediate SAVE_CONFIG temp file). The tarball does
not include the USB-serial variant `printer111.cfg` — that lives only in the
factory rootfs (`reference/ad5m-factory-config/printer111.cfg`).

---

## 3. The loadcell / TVOC implementation — the crux for ReForge

This is where the two mods **diverge**, and where ReForge took the wrong fork:

- **Stock (v11) and ZMod** read the load-cell and air sensors as **standard Klipper
  sensor types** that vanilla Klipper supports out of the box, plus three leveling H-pins:
  ```
  [temperature_sensor weightValue]   # the load cell amplifier
  sensor_type: MAX31856
  sensor_pin: PD5
  spi_software_sclk_pin: PD6
  spi_software_mosi_pin: PD7
  spi_software_miso_pin: PD8
  gcode_id: W
  [temperature_sensor tvocValue]
  sensor_type: MAX31865
  sensor_pin: PD4
  spi_software_sclk_pin: PE3
  spi_software_mosi_pin: PE4
  spi_software_miso_pin: PE5
  gcode_id: V
  [output_pin level_h1] / [level_h2] / [level_h3] / [level_clear]
  [probe]
  pin: !PB4
  z_offset: -0.25
  ```
- **xblax (v13)** instead uses **custom out-of-tree Klipper modules**:
  ```
  [flashforge_loadcell]
  mcu: mcu
  [temperature_sensor Load_Cell]
  sensor_type: flashforge_loadcell
  [flashforge_tvoc]
  mcu: mcu
  [temperature_sensor TVOC_Value]
  sensor_type: flashforge_tvoc
  ```

**ReForge's `printer.base.cfg` inherited the xblax form** (`flashforge_loadcell` /
`flashforge_tvoc`), which vanilla Klipper lacks → the "Unknown temperature sensor" error we
hit, which we worked around by **stripping** the sections. The correct fix is to **base
ReForge's config on the stock / ZMod form** (`MAX31856` + `MAX31865` + `[adxl345]` +
`[probe] pin:!PB4`) — all vanilla-supported — so the loadcell Z-probe, TVOC readout, and
bed-mesh come back **without any custom module**, against the native v11 MCU.

> The Z-probe is a plain `[probe] pin: !PB4` in **all three** (stock, xblax, ZMod). The
> "probe = the loadcell, dead without the module" assumption in the earlier strip was wrong:
> `!PB4` is the loadcell comparator's digital trigger and works as a standard probe pin; it
> only needed `z_offset` (stock: `-0.25`), which the FlashForge fork defaulted.

---

## 4. Authoritative stock AD5M config (3.1.3 OTA, cross-validated)

Verbatim key values (`printer.base.cfg` unless noted; `printer.cfg` = the override layer).
Extracted from `pro-3.1.3.tgz` (root-level `printer.cfg` + `printer.base.cfg`) and
cross-checked against the eMMC dump (`p6:/opt/config/`) and the factory rootfs
(`Adventurer5M-factory.tar.xz:opt/config/`) — all three byte-identical.

| Section | Stock value |
|---|---|
| `[mcu]` / `[mcu eboard]` | serial `/dev/ttyS5` / `/dev/ttyS1`, baud `230400`, `restart_method: command` |
| `[stepper_x]` | step `PC1` dir `PC0` en `!PA1`, microsteps `16`, **rotation_distance 40**, endstop `!eboard:PA15`, pos_endstop `110`, max `125` min `-125`, homing_speed `50`, retract `10`@`25` |
| `[stepper_y]` | step `PA3` dir `PA2` en `!PA6`, rotation `40`, endstop `!eboard:PB11`, pos_endstop `110`, max `125` min `-125`, homing_speed `50`, retract `10`@`25` |
| `[stepper_z]` | step `PC4` dir `PA7` en `!PB1`, rotation `8`, endstop `PB15`, pos_endstop `220`, max `230` min `-10`, homing_speed `20`, retract `5`@`10` |
| `[extruder]` (printer.cfg) | step `eboard:PB14` dir `!eboard:PB15` en `!eboard:PB12`, microsteps `16`, **rotation_distance 4.7**, `Generic 3950` @ `eboard:PA0`, heater `eboard:PA8`, min_extrude_temp `100`, PA `0.035`/`0.040`, max_extrude_only `1500`, max_cross_section `1000`; **PID (SAVE_CONFIG) Kp 38.331 Ki 6.084 Kd 60.372** |
| `[heater_bed]` (printer.cfg) | heater `PB9`, `Generic 3950` @ `PC3`, pullup `4700`, **PID Kp 32.79 Ki 4.970 Kd 54.118**, max_temp `130` |
| `[tmc2209 stepper_x/y]` | uart `PC2`/`PA4`, run_current **0.9**, sense `0.10`, interpolate True |
| `[tmc2209 stepper_z]` | uart `PC5`, run **0.6** hold **0.6**, sense `0.10` |
| `[tmc2209 extruder]` (printer.cfg) | uart `eboard:PB10`, run **0.8** hold **0.8**, sense `0.10` |
| `[adxl345]` | cs `eboard:PA4`, software SPI sclk `eboard:PA5` mosi `eboard:PA7` miso `eboard:PA6`, axes_map `x,y,z`, **rate 800** |
| `[resonance_tester]` | accel_chip `adxl345`, freq `5..100`, probe_points `0,0,100` |
| `[probe]` | pin `!PB4`, **z_offset -0.25**, speed `5`, samples `3`, average, tolerance `0.100`, retries `2` |
| `[bed_mesh]` | speed `300`, horizontal_move_z `5`, move_check `8`, mesh `±105`, 5×5, pps 3×3, bicubic `0.2` |
| `[printer]` | **corexy**, max_velocity `600`, max_accel `20000`, **max_accel_to_decel 5000**, max_z_velocity `25`, max_z_accel `500`, square_corner_velocity `25` |
| loadcell/TVOC | `MAX31856 weightValue` (PD5 + sw-SPI PD6/7/8, gcode_id W); `MAX31865 tvocValue` (PD4 + sw-SPI PE3/4/5, gcode_id V) |
| leveling | `level_h1/h2/h3` = `PG2/PG3/PG4`, `level_clear` = `PD10`, `check_level_pin` = `!PE0` |
| misc | `servo my_servo` `PC9` (**factory `initial_angle: 90`**; forge-x/ZMod use 115), `idle_timeout 600`, `pause_resume recover_velocity 50`, fans: `heat_fan eboard:PB4`, `fanM106 eboard:PB5`, `chamber_fan PC6/PC7 hw_pwm`, `internal_fan PB8`, `external_fan PB6`, **`fan_generic pcb_fan PB7`** (factory; forge-x renames it `controller_fan driver_fan`); M106/M107/M900 macros |

---

## 5. Parameter diff: stock(v11) vs xblax(v13) vs ZMod(v11) vs ReForge

`[mcu]`, `[mcu eboard]`, all four `[tmc2209]`, `[adxl345]`, `[resonance_tester]`, and the
X/Y/Z **pin** assignments are **identical** across stock / xblax / ZMod. Real differences:

| Parameter | Stock (v11) | xblax (v13) | ZMod (v11) | ReForge (current, post-strip) |
|---|---|---|---|---|
| X/Y position_max / min | 125 / −125 | **110.1 / −110** | 125 / −125 | 125 / −125 |
| X/Y homing_speed | 50 | **25** | 50 | 50 |
| Z homing_speed | 20 | 25 | 20 | 20 |
| second_homing_speed | — | **2.5** | — | — |
| extruder rotation_distance | 4.7 | **4.4** | 4.7 | 4.7 (tuning.cfg on device → 4.4) |
| extruder PID (Kp/Ki/Kd) | 38.331/6.084/60.372 | 33.443/4.372/63.961 | 20.109/1.943/52.031 | 38.331/6.084/60.372 |
| heater_bed PID (Kp/Ki/Kd) | 32.79/4.970/54.118 | **74.793/1.619/863.863** | 32.79/4.970/54.118 | 32.79/4.970/54.118 |
| min_extrude_temp | 100 | default 170 | 100 | (inherits) |
| `[printer]` cruise | `max_accel_to_decel 5000` | **`minimum_cruise_ratio 0.5`** | `max_accel_to_decel 5000` | `max_accel_to_decel 5000` |
| probe samples | 3 (avg, tol) | **1** | 3 (avg, tol) | **disabled** |
| bed_mesh horizontal_move_z / move_check | 5 / 8 | **1 / 5** | 5 / 8 | **disabled** |
| input_shaper x/y | (SAVE_CONFIG 52.2/48.2 mzv) | mzv 52.5 / **zv 50** | mzv 47.4 / mzv 46.2 | **disabled** |
| loadcell / TVOC | MAX31856 / MAX31865 | **flashforge_loadcell / flashforge_tvoc** | MAX31856 / MAX31865 | **stripped** (was xblax-form) |
| firmware_retraction | — | present (0.8/35) | — | present |

**Reading:** ReForge's numeric values track **stock/ZMod (v11)**, but its loadcell/TVOC
sections were the **xblax (v13)** custom-module form — the mismatch that forced the strips.
The `[printer]` cruise spelling (`max_accel_to_decel` vs `minimum_cruise_ratio`) is the one
purely version-correlated config knob (see §6, 20240313).

---

## 6. Upstream Klipper v0.11 → v0.13 config-affecting changes

From `Klipper3d/klipper` `docs/Config_Changes.md` @ `v0.13.0` (v0.11.0 = 2022-11-29,
v0.12.0 = 2023-10-13, v0.13.0 = 2025-04-10). AD5M-relevant entries:

- **20230201** `[bed_mesh]` no longer auto-loads the `default` profile at startup — add
  `BED_MESH_PROFILE LOAD=default` to `START_PRINT`.
- **20230525** `SHAPER_CALIBRATE` applies shaper params immediately if `[input_shaper]` is
  already enabled.
- **20240215** `SET_EXTRUDER_STEP_DISTANCE` / `SYNC_STEPPER_TO_EXTRUDER` removed; extruder
  `shared_heater` removed.
- **20240313** ⭐ `[printer] max_accel_to_decel` **deprecated** → use `minimum_cruise_ratio`.
  (This is exactly stock/ZMod-v11 `max_accel_to_decel:5000` vs xblax-v13
  `minimum_cruise_ratio:0.5`. v0.13 still accepts the old key with a deprecation warning.)
- **20240415** `[virtual_sdcard] on_error_gcode` now defaults to `TURN_OFF_HEATERS`.
- **20240912** `[output_pin]` `maximum_mcu_duration`/`static_value` removed; `SET_PIN`/
  `SET_SERVO`/`SET_FAN_SPEED`/`M106`/`M107` are now collated (only the latest rapid update
  may apply).
- **20241112** `CHIPS=` in `TEST_RESONANCES`/`SHAPER_CALIBRATE` needs the full chip name.
- **20241203** ⭐ resonance test now does slow sweeping moves — test point(s) need ±30 mm
  X/Y clearance; restore old behavior with `sweeping_period: 0` + `accel_per_hz: 75` in
  `[resonance_tester]`. (`probe_points: 0,0,100` is centered, so it's fine.)
- **20250131** `SAVE_VARIABLE` requires lowercase `VARIABLE=` value.

(Per-version printer.cfg for the AD5M is otherwise unchanged — ZMod ships one config for
both v11 and v13; only the MCU firmware + host Klipper binary swap.)

---

## 7. Recommendations for ReForge

ReForge currently ships a Klipper **newer** than the native v11 MCU and a config wrongly
based on xblax's v13 custom-module form. Two coherent targets:

**A. v11 path (no MCU reflash — lowest risk, matches the shipped hardware).**
- **Rebase `printer.base.cfg` on the stock/golden config** (MAX31856 + MAX31865 +
  `[adxl345]` + `[probe] pin:!PB4 z_offset:-0.25` + `level_h*`) — re-enabling everything we
  stripped, all vanilla-supported.
- **Pin ReForge's host Klipper to a v0.11-matched build** so the `query_adxl345` (and any
  other v11) protocol matches the native MCU → input shaping / resonance work (forge-x
  proves this on this exact unit: SAVE_CONFIG `shaper_freq_x 52.2 / y 48.2`).
- Use `max_accel_to_decel: 5000` (v0.11 spelling).

**B. v13 path (flash the MCU — parity with upstream, xblax-style).**
- Flash both N32G455 MCUs to v0.13 via the IAP path (we hold the stock binaries + flasher;
  xblax/ZMod provide v13 binaries), ship a v0.13 host, and use `minimum_cruise_ratio: 0.5`.
- Keep an **auto-downgrade-to-stock on uninstall/dual-boot** (xblax pattern) so brick-safety
  + dual-boot with stock/forge-x survive.

**To support switching v11↔v13** (the stated goal), mirror ZMod's model: a single config +
a flag (e.g. a ReForge equivalent of `klipper13=1`) that selects {MCU firmware image, host
Klipper build, and the one cruise-param spelling}. Everything else in the config is
version-independent. The switch must (1) flash the matching MCU firmware and (2) swap the
host Klipper build together — never one without the other, or it's the `query_adxl345`
mismatch again.
