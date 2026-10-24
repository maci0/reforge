# forge-x live config (on-unit, for diff reference)

Captured from the live unit's `/opt/config/printer.{cfg,base.cfg}` while running forge-x on stock
firmware 5.1.4. These are reference snapshots for comparison; ReForge does not install or load
them. The shared hardware pin map is documented in
[`docs/reverse-engineering/ad5m-pro-klipper-hardware-config.md`](../../docs/reverse-engineering/ad5m-pro-klipper-hardware-config.md#config-differences-across-versions).

Compared with the factory 3.1.3 snapshot in [`../ad5m-factory-config/`](../ad5m-factory-config/),
forge-x defers extruder PID + input_shaper to
SAVE_CONFIG/user.cfg, moves heater_bed + chamber LED into printer.cfg, drops pcb_fan, renames
chamber_led→chamber_light (+cycle_time 0.002), adds skew_correction + mod includes. servo
initial_angle 115 (vs factory 90). Pin map identical.
