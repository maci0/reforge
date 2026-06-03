# Stock canonical Klipper config — AD5M Pro

Default `printer.cfg` + `printer.base.cfg` extracted verbatim from the FlashForge factory image
bundled in ff5m **1.2.0**:
`Adventurer5MPro-3.1.3-2.2.3-20250107-Factory.tgz` (software 3.1.3 / control 2.2.3, 2025-01-07).

Source: https://github.com/DrA1ex/ff5m/releases/download/1.2.0/Adventurer5MPro-3.1.3-2.2.3-20250107-Factory.tgz
(the `.tgz` is a plain GNU tar, not gzip; `printer.cfg`/`printer.base.cfg` at archive root.)

`printer.cfg` = `[include printer.base.cfg]` + `[extruder]` + `[input_shaper]` (the per-unit /
tunable bits). `printer.base.cfg` = the full board/pin config (dual MCU `eboard` ttyS1 +
main ttyS5 @230400, corexy 125x125x230, TMC2209, MAX31856 weight / MAX31865 tvoc sensors,
bed_mesh, probe, fans, macros M106/M107/M900).

Confirms the pin map reverse-engineered from firmwareExe — see
`../../docs/board-notes/ad5m-pro-klipper-hardware-config.md`. (Minor drift: this factory
`[servo my_servo] initial_angle: 90`; the firmwareExe-embedded copy showed 115.)
