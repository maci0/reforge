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

## Memory against the stock kernel

Stock evidence from the live unit (`docs/board-notes/README.md`, `running-unit-probe.txt`,
[stock runtime tuning](../memory/2026-06-02-stock-kernel-runtime-tuning.md)): `MemTotal
110404 kB` of 131,072 kB DRAM, `cma=16M` (CMA counts inside `MemTotal`), `disp_reserve=1536000`,
and the vendor `8821cu` WiFi module loaded at 2,019,328 bytes (`lsmod`).

| static kernel memory | stock 5.4 | 7.3 board |
|---|---|---|
| vmlinux text+data+bss | 10.59 MB | 7.41 MB |
| WiFi driver | `8821cu.ko` 2.02 MB (loaded module) | built in: rtw88 176 KB + mac80211 418 KB + cfg80211 264 KB, pre-gc sizes, already inside 7.41 MB |
| **total** | **12.61 MB** | **7.41 MB (−5.2 MB)** |

Not measured, because the board kernel does not boot yet: init sections freed after boot (both
kernels free theirs), slab, page tables, per-CPU and other run-time kernel allocations, and the
display buffer (stock reserves 1.5 MB outside `MemTotal`; mainline DRM would allocate its
framebuffer from CMA, about 1.5 MB per 800×480×32 buffer). The −5.2 MB is therefore the static
part only, not a `MemAvailable` prediction.

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

## Stock built-ins with no consumer

Checked against the stock config (`docs/board-notes/stock-kernel-config-5.4.61.txt.gz`), the
stock DTS, and the clean stock rootfs (`stock-clean-rootfs.ext4`: init scripts, `printer.cfg`,
the `firmwareExe` UI's linked libraries and strings):

| built in (`=y`) | evidence it is unused |
|---|---|
| CAN (`CAN`, `CAN_RAW`, `CAN_BCM`, `CAN_GW`, `CAN_SUN8I`) | DTS `can@0x0 { status = "disabled"; }`: the driver never binds. No `canbus_uuid` in `printer.cfg`; both MCUs are UARTs. `candump`/`canbusload` ship in `/usr/bin` but nothing calls them. |
| Bluetooth (`BT`, `BT_RFCOMM`, `BT_HCIUART`, …) | `bt_init.sh`/`bt_play.sh` are not called by `rcS`; they would run `hciattach` on `ttyS1`, the toolhead MCU's UART. |
| Sound (24 `SND*`, sun8iw20 codec) | `firmwareExe` links no libasound and has no `/dev/snd` string; its buzzer (`buzzerPlay`) is not ALSA. Only `bt_play.sh` (unused) calls `bluealsa-aplay`. The codec's headphone-jack detector shows up as an input device the UI lists ("io Jack"). |
| NFS (v2/v3/v4/v4.1, `NFS_SWAP`) | no nfs mount in init scripts or `fstab`. |
| MTD/UBI/UBIFS | storage is eMMC; only `swupdate` and generic flash tools reference `/dev/mtd`. |
| IR (`RC_CORE`, `IR_RX_SUNXI`, NEC/RC5) | the UI enumerates input devices at start (`sunxi-ir` in its log); no reader found. |
| CSI camera input (`VIDEO_SUNXI_VIN`) | camera is USB UVC (`/dev/video0`). |
| resistive touch (`TOUCHSCREEN_SUN4I`) | touch is Goodix (`GT9XXNEW_TS`) through tslib. |
| G2D, ION, Cedar VE | only vendor media SDK libraries reference them; `firmwareExe` uses ffmpeg + x264 in software and links none of those libraries. |
| debug (`DEBUG_VM`, `DEBUG_MUTEXES`, `DEBUG_PREEMPT`, `PM_DEBUG`, `KALLSYMS_ALL`, `SUNXI_IOMMU_TESTS`, `DEBUG_INFO`) | developer checks; `DEBUG_VM`/`DEBUG_MUTEXES` also cost run-time CPU. |
| IPv6 (`IPV6`, `SIT`, tunnel) | no IPv6 configuration in the boot path; libc/busybox carry generic support only. |

The ADB service is the reverse case: `rcS` starts `adb_conf.sh` at every boot, but the stock
config has `# CONFIG_USB_GADGET is not set`, so it cannot work. Measured cost of part of the list
on the 5.4 BSP (§4 of
[kernel compiler and size options](2026-06-06-kernel-compiler-and-size-options.md)): dropping BT,
CAN, SND, IPV6, PROFILING, MAGIC_SYSRQ and `KALLSYMS_ALL` takes the stock vmlinux from 10.59 to
9.05 MB (−1.54 MB), `size` only, not booted.

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
