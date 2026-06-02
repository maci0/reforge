# Pristine factory AD5M Klipper config

Extracted verbatim from `tools/recovery/archive/Adventurer5M-factory.tar.xz`
(`opt/config/`) — the **untouched factory FlashForge config**, before any mod
(forge-x / ZMod). This is the canonical v11 baseline.

Findings (see docs/2026-06-02-ad5m-mcu-firmware-and-config.md):
- `printer.cfg` here is byte-identical to ZMod's `ff5m/printer.cfg`; `printer.base.cfg`
  is identical to ZMod's except the servo `initial_angle` (factory 90 vs ZMod 115).
  i.e. **ZMod ships the pristine factory config.**
- forge-x is the same config *restructured* (heater_bed/led moved into printer.cfg,
  `controller_fan driver_fan` instead of `pcb_fan`) and recalibrated.
- The (non-Pro) factory `base.cfg` already contains the Pro TVOC sensor
  (`MAX31865 tvocValue`) + the load cell (`MAX31856 weightValue`), so AD5M and AD5M Pro
  share one base.cfg.
- Native MCU = Klipper v11; `[adxl345]` is enabled and `[printer]` uses the v11
  `max_accel_to_decel` spelling.

`printer111.cfg` is the factory's USB-serial variant (`/dev/ttyACM*`).
