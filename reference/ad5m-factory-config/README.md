# Pristine factory AD5M Klipper config

Extracted verbatim from `tools/recovery/archive/Adventurer5M-factory.tar.xz`
(`opt/config/`) — the **untouched factory FlashForge config**, before any mod
(forge-x / ZMod). This is the canonical v11 baseline.

The `printer.cfg` and `printer.base.cfg` also match the copies extracted from the
AD5M Pro factory image `Adventurer5MPro-3.1.3-2.2.3-20250107-Factory.tgz`, distributed
with ff5m 1.2.0. Those duplicate copies previously lived under `vendor/stock-printer-cfg/`.

Findings (see the [MCU and config report](../../docs/reverse-engineering/ad5m-mcu-firmware-and-config.md)):

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

The on-device config captured while running forge-x is in
[`../ad5m-forge-x-config/`](../ad5m-forge-x-config/). Both directories are reference snapshots;
ReForge's runtime defaults live under `br-external/board/reforge/rootfs-overlay/etc/reforge/`.
