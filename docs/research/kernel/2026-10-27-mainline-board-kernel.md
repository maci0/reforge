# Mainline 7.3 board kernel: only what the AD5M uses

**Date:** 2026-10-27
**Status:** snapshot. Size measured with `size vmlinux`; no board DTS, not booted.
**TL;DR:** a 7.3 kernel scoped to the T113 peripherals the printer uses and the features the
ReForge rootfs uses is **7.41 MB**, 2.82 MB under the stocklike 7.3 proxy (10.23 MB) and 3.18 MB
under the 5.4 stock device kernel (10.59 MB).

## Method

`make kernel-mainline` (`tools/build/build-mainline-kernel.sh`): `linux-7.3` from `pins.lock`,
`allnoconfig` with `KCONFIG_ALLCONFIG=br-external/board/reforge/linux-mainline-t113.config`,
Buildroot gcc 15.3.0 + binutils 2.45.1 (same toolchain as the stocklike rerun in
[2026-06-06-kernel-compiler-and-size-options.md](2026-06-06-kernel-compiler-and-size-options.md)).
The script fails if any fragment value does not survive dependency resolution, so every listed
driver is in the build. Size knobs: `-Os`, gc-sections (`EXPERT=y`), `MODULES=n` (everything
built in; `TRIM_UNUSED_KSYMS` needs modules, so it does not apply).

## Result

| kernel (gcc 15.3) | .text | .data | .bss | total |
|---|---|---|---|---|
| 5.4 stock device (ref) | 7.57M | 2.84M | 0.19M | 10.59M |
| 7.3 stocklike B | 7,537,955 | 2,594,360 | 101,092 | 10,233,407 |
| **7.3 board** | **5,603,292** | **1,629,672** | **180,628** | **7,413,592** |

Checked in the built `vmlinux` (`nm`): symbols from `rtw8821c*`, `sun4i_tcon`, `sun8i_mixer`,
`goodix`, `stmmac`, `sunxi_mmc`, `dw8250`, `uvc_`, `zram_` are all present. Pre-link sizes by
top-level directory (text+data of `built-in.a`, before gc-sections): drivers 2.70M (gpu 0.51M,
net 0.44M, media 0.29M, usb 0.24M), net 2.00M, kernel 1.08M, fs 0.99M.

## In scope

From [device-overview](../../board-notes/device-overview.md), the stock DTS
(`br-external/board/reforge/stock/kernel.dts`) and the rootfs overlay, mapped to the mainline
drivers for the `sun8i-t113s.dtsi` / `sunxi-d1s-t113.dtsi` compatibles:

- SoC: D1/T113 CCU + R-CCU + DE2 CCU, pinctrl, PPU, SRAM, LDOs, DMA, SID, RTC, watchdog, THS.
- UART (8250 DW, 6 ports: MCUs on ttyS1 and ttyS5), eMMC (`MMC_SUNXI`, GPT).
- USB host EHCI/OHCI + sun4i USB PHY: RTL8821CU (`rtw88`), UVC camera, USB storage + VFAT, USB-ACM.
- Display: DE2 mixer, TCON TOP/LCD, `panel-simple`, GPIO backlight (stock drives GPIO203; 7.3 has
  no D1 PWM driver), Goodix touch on I2C, SPI (panel init bus in the stock DTS).
- Ethernet: on-SoC EMAC (`DWMAC_SUN8I`, RMII PHY).
- Rootfs features: ext4, tmpfs, devtmpfs, inotify, swap, zram with zstd (`S35zram`), IPv4,
  UNIX and packet sockets, SysV IPC, POSIX mqueue.

## Deliberately excluded

Enabled in the stock DTS or config, but nothing in ReForge uses them; each is a one-line add:

- **Sound** (codec, DMIC, I2S, SPDIF): no ReForge consumer found. Unverified whether the board
  has a speaker.
- **CAN**: stock carries a vendor CAN driver (`vendor/kernels/stock-patches/0006-stock-can.patch`);
  both MCUs are on UARTs. Mainline has `allwinner,sun20i-d1-can` if needed.
- **IPv6, Bluetooth, netfilter**: rootfs ships no `ip6tables`/`iptables`/`nft` or BT userland.
- **CSI/ISP/TV-in, Cedar VE, G2D, deinterlace, IR, LRADC keys, resistive touch, crypto engine,
  MUSB gadget**: camera is USB UVC; VE does not complete codec ops on this unit.
- **Loadable modules**: everything is built in.

## Open before this can boot

- Board DTS for mainline bindings (the stock DTS uses BSP bindings).
- RGB panel timings and on-wire bus depth
  ([mainline support](2026-06-01-t113-mainline-kernel-support.md), pinmux note).
- Secondary-CPU bring-up: `sun8i-t113s.dtsi` has no `enable-method`; `ARM_PSCI` is in the config,
  but whether the stock OP-TEE provides PSCI is unchecked.
- Which root port carries WiFi, camera and the USB socket (EHCI0 behind the OTG PHY or EHCI1).
- Runtime check of the ReForge userland (init, klippy, Moonraker, GuppyScreen) on this config;
  only the build is verified.
