# Stock firmware reverse-engineering

Finding reports from reverse-engineering the **stock FlashForge AD5M Pro firmware** — primarily the
non-stripped QT4 UI app `firmwareExe` (`/opt/PROGRAM/software/5.1.4/`) plus the stock Klipper
config. All findings were verified against the on-device binary (`arm-linux-gnueabi` toolchain:
`readelf -sW`, `c++filt`, `objdump -d`, `strings`). Companion device/platform reference:
[`../board-notes/`](../board-notes/) (device-overview, forge-x boot, kernel config).

## firmwareExe (stock UI app)
- [firmwareexe-reverse-engineering.md](firmwareexe-reverse-engineering.md) — overview, architecture, security summary.
- [gdb-firmwareexe-injection.md](gdb-firmwareexe-injection.md) — drive the UI from shell via gdb method-injection.
- [firmwareexe-local-print-api.md](firmwareexe-local-print-api.md) — Klippy socket `/tmp/uds` (ETX-framed) + print g-code.
- [firmwareexe-orcaserver-lan-api.md](firmwareexe-orcaserver-lan-api.md) — LAN HTTP API (:8898).
- [firmwareexe-lan-protocol-and-crypto.md](firmwareexe-lan-protocol-and-crypto.md) — raw TCP 8899, UDP discovery, crypto/keys.
- [firmwareexe-cloud-command-surface.md](firmwareexe-cloud-command-surface.md) — MQTT/NIM remote-control surface.
- [firmwareexe-cloud-rest-and-oss.md](firmwareexe-cloud-rest-and-oss.md) — cloud REST catalog + Alibaba OSS upload.
- [firmwareexe-ota-update.md](firmwareexe-ota-update.md) — OTA path (MD5-only, unsigned).
- [firmwareexe-network-wifi.md](firmwareexe-network-wifi.md) — wifi/eth/AP/static via shell-outs.
- [firmwareexe-filesystem-and-system.md](firmwareexe-filesystem-and-system.md) — ffsdk, filesystem map, USB, PWM, display.
- [firmwareexe-ui-classes.md](firmwareexe-ui-classes.md) — Keyboard/Language/Scanner/Guider/dialogs/QR.

## Stock Klipper config
- [ad5m-pro-klipper-hardware-config.md](ad5m-pro-klipper-hardware-config.md) — complete pin map / printer.cfg
  (cross-validated against firmwareExe 5.1.4, factory 3.1.3, and the forge-x live config).

## Related (not stock-fw RE)
- [`../board-notes/device-overview.md`](../board-notes/device-overview.md) — hardware/stack inventory + consolidated security findings.
- [`../board-notes/forge-x-boot-architecture.md`](../board-notes/forge-x-boot-architecture.md) — the forge-x **mod** boot/chroot stack.
- [`ad5m-mcu-firmware-and-config.md`](ad5m-mcu-firmware-and-config.md) — MCU firmware (v11/v13, N32G455) + config diff vs mods.
- `../../lab/venc-scratch/` — Cedar VE H.264 encode investigation (HW encode non-functional; stock uses x264 software).
