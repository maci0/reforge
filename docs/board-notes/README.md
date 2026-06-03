# Board Notes — FlashForge AD5M Pro (Allwinner T113-S3)

Reference data captured from the live unit (`root@192.168.0.158`, hostname `kunos`)
for the Plan 5 (P4) kernel + U-Boot + genimage work. **Reference for parameter
extraction — not shipped.**

## Captured artifacts (this dir)

- `stock-kernel-config-5.4.61.txt.gz` — the **exact stock kernel `.config`** (`/proc/config.gz`,
  1017 `CONFIG_` lines). The slim-down baseline for `reforge_t113_defconfig`.
- `running-unit-probe.txt` — uname, cmdline, lsmod.

## Kernel cmdline (stock)

```
earlycon=uart8250,mmio32,0x05000000 clk_ignore_unused initcall_debug=0
console=ttyS3,115200 loglevel=4 root=/dev/mmcblk0p6 init=/init
partitions=boot-resource@mmcblk0p1:env@mmcblk0p2:env-redund@mmcblk0p3:boot@mmcblk0p4:dsp0@mmcblk0p5:rootfs@mmcblk0p6:UDISK@mmcblk0p7
cma=16M snum= mac_addr= wifi_mac= bt_mac= specialstr= gpt=1
androidboot.hardware=sun8iw20p1 boot_type=1 androidboot.boot_type=1
uboot_message=2018.05-g2a24076-dirty(04/18/2025-11:25:23)
disp_reserve=1536000,0x448ee000 androidboot.dramsize=128
```

## Derived facts

| Fact | Value | Relevant to |
|---|---|---|
| Console UART | `ttyS3` @ 115200, base `0x05000000` | kernel console, U-Boot stdout |
| Root partition | `mmcblk0p6` (rootfs), ext4 | genimage, fstab |
| Data partition | `mmcblk0p7` (UDISK / `/data`) | genimage, fstab |
| Reserved | `p5 = dsp0` — HiFi4 DSP firmware | partition map; leave intact |
| CMA | 16 MB | display/DMA; kernel `cma=` |
| DRAM | **128 MB** | U-Boot DRAM init, RAM budget |
| Display reserve | `1536000 @ 0x448ee000` | framebuffer / DRM |
| SoC id | `sun8iw20p1` | DT compatible, U-Boot board |
| Vendor U-Boot | **2018.05** (vendor fork) | we replace with mainline ≥2024.01 |
| Loaded modules | only `8821cu` (RTL8821CU wifi/BT) | mainline `CONFIG_RTW88_8821CU` replaces it (see notes) |

## Notes

- Stock kernel is essentially monolithic (one out-of-tree module). When building
  `reforge_t113_defconfig` from mainline-LTS, the captured stock `.config` is the
  authoritative list of which subsystems/drivers this board actually uses — start
  from a board-minimal config and cross-check against it, rather than shipping a
  generic sunxi defconfig.
- `8821cu` (RTL8821CU) is out-of-tree in the stock BSP, but **mainline covers it**:
  `CONFIG_RTW88_8821CU` (rtw88 family) since kernel 6.2, flaky early but solid by
  6.12 (our target LTS); BT via `btusb`+`btrtl`. **No vendor module needed.** rtw88
  is station-mode-solid (AP/monitor weaker than vendor, irrelevant for a printer).
- The `dsp0@p5` partition holds DSP firmware; the partition map must be preserved
  by genimage so the DSP and boot chain are not disturbed.

---

## Documentation index

Reverse-engineering of the stock firmware + the device/mod platform. Start with
[device-overview.md](device-overview.md) (hardware/stack inventory + consolidated security
findings). MCU firmware + config-baseline detail:
[`../2026-06-02-ad5m-mcu-firmware-and-config.md`](../2026-06-02-ad5m-mcu-firmware-and-config.md).

### firmwareExe reverse-engineering (stock UI app)
- [firmwareexe-reverse-engineering.md](firmwareexe-reverse-engineering.md) — overview + architecture.
- [gdb-firmwareexe-injection.md](gdb-firmwareexe-injection.md) — drive the UI from shell via gdb.
- [firmwareexe-local-print-api.md](firmwareexe-local-print-api.md) — Klippy socket /tmp/uds + print g-code.
- [firmwareexe-orcaserver-lan-api.md](firmwareexe-orcaserver-lan-api.md) — LAN HTTP API (:8898).
- [firmwareexe-ota-update.md](firmwareexe-ota-update.md) — OTA path (MD5-only, unsigned).
- [firmwareexe-cloud-command-surface.md](firmwareexe-cloud-command-surface.md) — remote-control surface.
- [firmwareexe-lan-protocol-and-crypto.md](firmwareexe-lan-protocol-and-crypto.md) — TCP 8899 + crypto/keys.
- [firmwareexe-cloud-rest-and-oss.md](firmwareexe-cloud-rest-and-oss.md) — cloud REST + OSS upload.
- [firmwareexe-filesystem-and-system.md](firmwareexe-filesystem-and-system.md) — ffsdk, FS map, USB, PWM, display.
- [firmwareexe-network-wifi.md](firmwareexe-network-wifi.md) — wifi/eth/AP/static.
- [firmwareexe-ui-classes.md](firmwareexe-ui-classes.md) — UI/i18n/Guider/dialogs/QR.

### Device, hardware & mod architecture
- [device-overview.md](device-overview.md) — hardware/stack inventory + security summary.
- [ad5m-pro-klipper-hardware-config.md](ad5m-pro-klipper-hardware-config.md) — Klipper pin map / printer.cfg.
- [forge-x-boot-architecture.md](forge-x-boot-architecture.md) — mod boot/chroot/service stack.
