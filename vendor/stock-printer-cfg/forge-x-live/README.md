# forge-x live config (on-unit, for diff reference)

The actual `/opt/config/printer.{cfg,base.cfg}` pulled from the live unit (forge-x, stock fw
5.1.4 base). Kept for the version diff in
`../../../docs/board-notes/ad5m-pro-klipper-hardware-config.md` ("Config differences across versions").

vs the factory 3.1.3 copies one dir up, forge-x: defers extruder PID + input_shaper to
SAVE_CONFIG/user.cfg, moves heater_bed + chamber LED into printer.cfg, drops pcb_fan, renames
chamber_led→chamber_light (+cycle_time 0.002), adds skew_correction + mod includes. servo
initial_angle 115 (vs factory 90). Pin map identical.
