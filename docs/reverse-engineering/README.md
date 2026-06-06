# Stock firmware reverse-engineering

> **For a consolidated security-findings view across all the docs in this folder —
> 15 findings with severity + closure status per ReForge deployment mode — see
> [`../security-findings.md`](../security-findings.md).** This README indexes the
> per-component RE notes that the security doc draws from.

Finding reports from reverse-engineering the **stock FlashForge AD5M Pro firmware** — primarily the
non-stripped QT4 UI app `firmwareExe` (`/opt/PROGRAM/software/5.1.4/`) plus the stock Klipper
config. All findings were verified against the on-device binary (`arm-linux-gnueabi` toolchain:
`readelf -sW`, `c++filt`, `objdump -d`, `strings`). Companion device/platform reference:
[`../board-notes/`](../board-notes/) (device-overview, forge-x boot, kernel config).

## firmwareExe (stock UI app)
- [firmwareexe-reverse-engineering.md](stock-ui/firmwareexe-reverse-engineering.md) — overview, architecture, security summary.
- [gdb-firmwareexe-injection.md](stock-ui/gdb-firmwareexe-injection.md) — drive the UI from shell via gdb method-injection.
- [firmwareexe-local-print-api.md](stock-ui/firmwareexe-local-print-api.md) — Klippy socket `/tmp/uds` (ETX-framed) + print g-code.
- [firmwareexe-orcaserver-lan-api.md](stock-ui/firmwareexe-orcaserver-lan-api.md) — LAN HTTP API (:8898).
- [firmwareexe-lan-protocol-and-crypto.md](stock-ui/firmwareexe-lan-protocol-and-crypto.md) — raw TCP 8899, UDP discovery, crypto/keys.
- [firmwareexe-cloud-command-surface.md](stock-ui/firmwareexe-cloud-command-surface.md) — MQTT/NIM remote-control surface.
- [firmwareexe-cloud-rest-and-oss.md](stock-ui/firmwareexe-cloud-rest-and-oss.md) — cloud REST catalog + Alibaba OSS upload.
- [firmwareexe-ota-update.md](stock-ui/firmwareexe-ota-update.md) — OTA path (MD5-only, unsigned).
- [firmwareexe-network-wifi.md](stock-ui/firmwareexe-network-wifi.md) — wifi/eth/AP/static via shell-outs.
- [firmwareexe-filesystem-and-system.md](stock-ui/firmwareexe-filesystem-and-system.md) — ffsdk, filesystem map, USB, PWM, display.
- [firmwareexe-ui-classes.md](stock-ui/firmwareexe-ui-classes.md) — Keyboard/Language/Scanner/Guider/dialogs/QR.

## Stock Klipper config
- [ad5m-pro-klipper-hardware-config.md](ad5m-pro-klipper-hardware-config.md) — complete pin map / printer.cfg
  (cross-validated against firmwareExe 5.1.4, factory 3.1.3, and the forge-x live config).

## Stock kernel / modules
- [stock-kernel-modules-packaging.md](stock-kernel-modules-packaging.md) — how FF packages
  and loads kernel modules: standard `/lib/modules/5.4.61/` kbuild layout + a flat duplicate
  of `8821cu.ko` at `/lib/modules/8821cu.ko` (insmod'd by `auto_run.sh`); the unstripped
  DWARF is a build-pipeline artifact, not a runtime gdb capability; the `comp_dir`
  identifies the SDK as Allwinner's proprietary **T113-Linux-Auto-v1.1** Auto distribution.
- [stock-kernel-byte-identical-build.md](stock-kernel-byte-identical-build.md) — **reference
  method** for reproducing the stock `Image` host-only from public source (Linaro GCC 5.3.1 +
  exact build path), reaching +128 bytes (a 256-byte linker-alignment artifact). The dated
  experiment + dead-driver audit is in
  [`../research/2026-06-04-byte-identical-kernel-reproduction.md`](../research/kernel/2026-06-04-byte-identical-kernel-reproduction.md);
  for the mainline alternative see [`../research/2026-06-01-t113-mainline-kernel-support.md`](../research/kernel/2026-06-01-t113-mainline-kernel-support.md).

## Related (not stock-fw RE)
- [`../board-notes/device-overview.md`](../board-notes/device-overview.md) — hardware/stack inventory + consolidated security findings.
- [`../board-notes/forge-x-boot-architecture.md`](../board-notes/forge-x-boot-architecture.md) — the forge-x **mod** boot/chroot stack.
- [`ad5m-mcu-firmware-and-config.md`](ad5m-mcu-firmware-and-config.md) — MCU firmware (v11/v13, N32G455) + config diff vs mods.
- `../../lab/venc-scratch/` — Cedar VE H.264 encode investigation (HW encode non-functional; stock uses x264 software).
