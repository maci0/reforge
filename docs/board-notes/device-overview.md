# AD5M Pro — device overview & documentation index

Top-level map of the FlashForge Adventurer 5M Pro hardware/software, and an index of the
reverse-engineering corpus (this unit: `root@192.168.0.158`, hostname `kunos`).

## Hardware
- **SoC**: Allwinner **T113** (`sun8iw20`, D1-class), dual Cortex-A7 ARMv7, soft-float userland.
- **RAM**: 128 MB DDR (107 MB usable). Swap: **zram0 256 MB** (zstd, forge-x; see zram notes) +
  eMMC swapfile overflow.
- **eMMC**: 8 GB (`mmcblk0`, 7456 M). Partitions: `p1` 33M, `p2/p3/p5` 1M (env/misc), `p4` 34M,
  `p6` 1280M, **`p7` 6068M → `/data`**.
- **Kernel**: stock **5.4.61** (`sun8iw20p1` BSP). Loaded modules: `8821cu` (Realtek RTL8821CU USB
  WiFi), `zram`, `zsmalloc`.
- **Video Engine (Cedar)** @ `0x01C0E000`, ver 0x1667 — **does not complete codec ops on this unit**
  (see `../../lab/venc-scratch/`); stock uses x264 **software** H.264.
- **Camera**: USB-UVC, **MJPEG-native** 640×480/1280×720.
- **MCUs**: main board `/dev/ttyS5` + toolhead `eboard` `/dev/ttyS1`, both Klipper @ 230400.
- **Display**: SPI/RGB LCD via Allwinner `dispdbg` backlight + GPIO203; touch via `libts`.

## Software stack
- **Stock**: buildroot Linux + QT4 UI `firmwareExe` (`/opt/PROGRAM/software/5.1.4/`) + Klipper
  (`/opt/klipper`) + cloud (FlashForge/Alibaba/NetEase/Polar). H.264 = libx264 (CPU).
- **forge-x mod**: overlay adding Moonraker (:7125) + Mainsail web + optional guppyscreen + `z*` CLI,
  in a buildroot chroot at `/data/.mod/.forge-x`. Keeps (STOCK) or replaces (GUPPY) firmwareExe.
  See [`forge-x-boot-architecture.md`](forge-x-boot-architecture.md).
- **Codec demos** present (all fail to complete on this VE): `demoVdecoder`, `demoVencVdec`,
  `encoderTest`, `vdecoderdemo`, `vencoderDemo`.

## Documentation index
**firmwareExe (stock UI) reverse-engineering** — 11 docs:
- [firmwareexe-reverse-engineering.md](firmwareexe-reverse-engineering.md) — overview + architecture + security summary.
- [gdb-firmwareexe-injection.md](gdb-firmwareexe-injection.md) — drive the UI from shell via gdb.
- [firmwareexe-local-print-api.md](firmwareexe-local-print-api.md) — Klippy `/tmp/uds` ETX-framed API + print g-code.
- [firmwareexe-cloud-rest-and-oss.md](firmwareexe-cloud-rest-and-oss.md) — cloud REST catalog + OSS upload.
- [firmwareexe-cloud-command-surface.md](firmwareexe-cloud-command-surface.md) — MQTT/NIM remote-control surface.
- [firmwareexe-orcaserver-lan-api.md](firmwareexe-orcaserver-lan-api.md) — LAN HTTP API (:8898).
- [firmwareexe-lan-protocol-and-crypto.md](firmwareexe-lan-protocol-and-crypto.md) — TCP 8899, discovery, keys.
- [firmwareexe-ota-update.md](firmwareexe-ota-update.md) — OTA path (MD5-only, unsigned).
- [firmwareexe-network-wifi.md](firmwareexe-network-wifi.md) — wifi/eth/AP/static.
- [firmwareexe-filesystem-and-system.md](firmwareexe-filesystem-and-system.md) — ffsdk, FS map, USB, PWM, display.
- [firmwareexe-ui-classes.md](firmwareexe-ui-classes.md) — Keyboard/Language/Guider/dialogs/QR.

**Hardware / mod / platform**:
- [ad5m-pro-klipper-hardware-config.md](ad5m-pro-klipper-hardware-config.md) — pin map / printer.cfg.
- [forge-x-boot-architecture.md](forge-x-boot-architecture.md) — the mod boot/chroot/service stack.
- `../../lab/venc-scratch/README.md` — the Cedar VE H.264 encode investigation (HW encode non-functional).
- `../../lab/ve-kmod/` — VE/IOMMU/MBUS diagnostic kernel module.

## Consolidated security findings (stock firmware)
1. **Unsigned OTA** (MD5-only) → root RCE via in-package `run.sh`; dev HTTP update server shipped.
2. **Unauthenticated LAN**: raw TCP 8899 (take-control + arbitrary gcode upload/print + identity
   leak), UDP discovery 225.0.0.9 (cleartext serial/MAC/IP/cloud-bind).
3. **Plaintext cloud control**: MQTT over `ws://:8083` (no TLS), unsigned per-command.
4. **Embedded secrets**: default RSA private key (qrc blob, Polar), hardcoded HMAC log-upload
   secrets, zip password `FFP0286&*%root`, default UI creds `admin`/`ff123456`.
5. **`curl -k`** (TLS verify off); **shell-injectable** crypto/wifi/SSID paths; cleartext wifi creds.
6. **No TLS pinning**; writable `/opt/cacert.pem`. **telnetd** shipped (renamed `myBin`).
7. **Telemetry** to FlashForge + Alibaba OSS + **NetEase IM (China)** + Polar: gcode, thumbnails,
   camera RTMP, full logs, continuous status.

→ ReForge hardening: kill cloud actors + firewall 8899/19000/225.0.0.9, sign OTA, per-device keys,
LAN-only mode, drop the embedded-secret paths.
