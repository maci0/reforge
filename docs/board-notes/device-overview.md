# AD5M Pro — device overview

Top-level map of the FlashForge Adventurer 5M Pro hardware/software stack (this unit:
`root@192.168.0.158`, hostname `kunos`). Doc index: [README.md](README.md).

## Hardware
- **SoC**: Allwinner **T113** (`sun8iw20`, D1-class), dual Cortex-A7 ARMv7, soft-float userland.
- **RAM**: 128 MB DDR (107 MB usable). Swap: **zram0 256 MB** (zstd, forge-x; see zram notes) +
  eMMC swapfile overflow.
- **eMMC**: 8 GB (`mmcblk0`, 7456 M). Partitions: `p1` 33M, `p2/p3/p5` 1M (env/misc), `p4` 34M,
  `p6` 1280M, **`p7` 6068M → `/data`**.
- **Kernel**: stock **5.4.61** (`sun8iw20p1` BSP). Loaded modules: `8821cu` (Realtek RTL8821CU USB
  WiFi), `zram`, `zsmalloc`. **Mainline-viable:** the T113 + every peripheral here — incl. the
  RTL8821CU (mainline `rtw88`/`rtw8821cu`) — is upstream since Linux **v6.4**; a 6.x kernel needs
  only a board DTS + LCD panel, not the BSP. See
  [`../research/2026-06-01-t113-mainline-kernel-support.md`](../research/2026-06-01-t113-mainline-kernel-support.md).
- **Video Engine (Cedar)** @ `0x01C0E000`, ver 0x1667 — **does not complete codec ops on this unit**
  (see `../../lab/venc-scratch/`); stock uses x264 **software** H.264.
- **Camera**: USB-UVC, **MJPEG-native** 640×480/1280×720.
- **MCUs**: 2× **Nationstech N32G455** (GD32/STM32-F4 work-alike) — main board `/dev/ttyS5` +
  toolhead `eboard` `/dev/ttyS1`, both Klipper @ 230400. Stock MCU fw = Klipper 0.11; mods flash
  0.13. See [`../reverse-engineering/ad5m-mcu-firmware-and-config.md`](../reverse-engineering/ad5m-mcu-firmware-and-config.md).
- **Display**: SPI/RGB LCD via Allwinner `dispdbg` backlight + GPIO203; touch via `libts`.

## Software stack
- **Stock**: buildroot Linux + QT4 UI `firmwareExe` (`/opt/PROGRAM/software/5.1.4/`) + Klipper
  (`/opt/klipper`) + cloud (FlashForge/Alibaba/NetEase/Polar). H.264 = libx264 (CPU).
- **forge-x mod**: overlay adding Moonraker (:7125) + Mainsail web + optional guppyscreen + `z*` CLI,
  in a buildroot chroot at `/data/.mod/.forge-x`. Keeps (STOCK) or replaces (GUPPY) firmwareExe.
  See [`forge-x-boot-architecture.md`](forge-x-boot-architecture.md).
- **Codec demos** present (all fail to complete on this VE): `demoVdecoder`, `demoVencVdec`,
  `encoderTest`, `vdecoderdemo`, `vencoderDemo`.

## Related
- **Stock-firmware RE finding reports**: [`../reverse-engineering/`](../reverse-engineering/)
  (firmwareExe analysis + stock Klipper pin map).
- Board-notes index: [README.md](README.md). forge-x mod boot: [forge-x-boot-architecture.md](forge-x-boot-architecture.md).
- `../../lab/venc-scratch/README.md` — Cedar VE H.264 encode investigation (HW encode non-functional).
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
