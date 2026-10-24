# Reference captures

These files record configurations from stock firmware and a printer running Forge-X.
They support hardware research and comparisons between firmware versions.

| Directory | Origin |
|---|---|
| [ad5m-factory-config/](ad5m-factory-config/README.md) | Pristine factory AD5M Klipper configuration, before installing a mod. |
| [ad5m-forge-x-config/](ad5m-forge-x-config/README.md) | Configuration captured on an AD5M Pro running Forge-X over stock firmware 5.1.4, including that unit's saved calibration. |

ReForge packages its runtime defaults from
[`br-external/board/reforge/rootfs-overlay/etc/reforge/`](../br-external/board/reforge/rootfs-overlay/etc/reforge/).
The capture directories remain independent so their original contents can be compared with those defaults.
Per-unit PID, input shaper, and bed mesh values describe the captured printer.

See the [hardware config comparison](../docs/reverse-engineering/ad5m-pro-klipper-hardware-config.md)
for the shared pin map and differences across versions.
