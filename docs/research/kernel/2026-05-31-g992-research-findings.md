# g992 AD5M research repo — findings for ReForge

Mined from `g992/flashforge-ad5m-5mpro-research` (+ issue #25) and the linked
`xblax/flashforge_ad5m_klipper_mod`. Date: 2026-05-31.

> **CORRECTIONS (2026-06-02, vs the verified factory config + hardware trial — see
> `docs/reverse-engineering/ad5m-mcu-firmware-and-config.md` + `reference/ad5m-factory-config/`):**
> - **Fan pins transposed (§7):** factory is `internal_fan = PB8`, `external_fan = PB6`.
> - **`flashforge_loadcell`/`flashforge_tvoc`** are **xblax's v13** custom modules (what g992
>   mined). The stock/factory config reads the load cell as `MAX31856` (`weightValue`) and TVOC
>   as `MAX31865` (`tvocValue`) — standard vanilla sensors.
> - **N32G455 is STM32-F4-class** (Cortex-M4 @144 MHz); the `stm32f103xe` Klipper *target* is a
>   port choice, not the silicon class. The "STM32F103 same pinout" swap is g992's unverified claim.
> - Stale path: the golden dump is now `tools/recovery/golden.img.gz` (the `golden-kunos-*` name
>   was dropped 2026-06-01).
> - g992's "Klipper won't enumerate on the N32G455" is mod-build-specific; ReForge's host Klipper
>   **does** drive the stock-firmware MCUs (proven on hardware).

## 1. Repo overview
`g992/flashforge-ad5m-5mpro-research` is a small community hardware/research hub
(~140★, board photos, MCU/external-CPU notes), authoritative for **board-level +
MCU** observations but a *pointer hub*, not a deep firmware project. The real
engineering authority it links to is **`xblax/flashforge_ad5m_klipper_mod`** (the
Klipper Mod) — most concrete data below is from there. Note: xblax `BUILDING.md`
is **empty** (build-system rework pending, issue #32) — there is currently no
public from-scratch build doc, but the buildroot configs/overlays/scripts are readable.

Key g992 software finding: **stock FlashForge firmware is itself Klipper-based**
(Mainboard-*.bin compiled from Klipper) but ships **no Moonraker**.

## 2. Issue #25 — "Connecting the 5MP main board to an external CPU?"
Open since 2024-08-28. User wants to drive the stock MCUs from an external SBC. Richest MCU/comms thread in the repo. Extracted:
- g992's verdict: full external-CPU bring-up **failed** repeatedly; he recommends the xblax mod. No turnkey external-host solution exists.
- **e-board (toolhead) comms = RS-232/UART, single channel, crossover**, 115200/230400.
- MCU swap: native **N32G455** can be replaced 1:1 by an **STM32F103** (same pinout) — but STM32F103 is 72 MHz vs N32 144 MHz. g992 could **not** get a stable Klipper build to enumerate on the native **N32G455** (builds+flashes via SWD, never enumerates).
- e-board boot is gated by an undocumented mainboard handshake (issue #6) — **now fully known** (see §7).
- A UART→CAN transceiver (SCM3425) on the toolhead worked (RPi+CAN saw it).

## 3. Recovery / FEL / UART — our no-FEL/no-UART assumption STANDS
- **No FEL documented anywhere.** T113-S3 has BROM FEL in silicon, but nobody has reported pads/test-points/trigger on this board. Treat FEL as *unverified/unexposed*, not silicon-absent.
- **No host-Linux console UART documented.** The used serial ports (`/dev/ttyS1`, `/dev/ttyS5`) go to the **MCUs**, not a console header. FlashForge boards usually have an undocumented UART0 debug header — unmapped here.
- **Only recovery = stock USB `.tgz` updater hijack** (matches our model). `flashforge_init.sh` runs as the update hook from a FAT USB stick; requires stock FW ≥ **2.4.5**, PID `0023`(5M)/`0024`(5M Pro), arch armv7l.
- The Klipper Mod is a **chroot tarball inside `/data`** that hijacks PID 1 at boot — never touches partitions/U-Boot/kernel → reversible, but tells us nothing about low-level unbrick.
- **Recommendation (high-value de-risk): independently probe for a UART0 console header + test whether USB-OTG enters FEL.** This is unexplored and is the biggest brick-risk reducer before ReForge touches U-Boot/kernel.

## 4. Display panel — "must self-port" CONFIRMED, no timings here
- The mod **reuses the stock kernel + stock framebuffer**: writes splash to **`/dev/fb0`**, LVGL/`lv_drivers` fbdev for GuppyScreen. There's a patch `0001-lv_driver_fb_ioctls_flashforge_ad5m.patch` → the fb needs **custom ioctls / non-standard fbdev** (read this when porting).
- **No panel model, interface (RGB vs MIPI-DSI), resolution, pixel clock, porches, TCON/DE config anywhere.** `LCD.md` only covers backlight.
- Backlight = real Linux **PWM** (`flashforge_ad5m_backlight`, `backlight 0..100`, `LCD_ON/LCD_OFF`). GuppyScreen `"display_rotate": 0`.
- Touch = evdev via **tslib + `uinput.ko`** (touch controller is a separate, likely I²C, device).
- **Net:** panel timings must be pulled from the **stock 5.4.61 DTB / `sys_config.fex` / boot-resource in a stock eMMC dump** — neither repo ships them. Our "RGB-LCD not mainlined → self-port" assumption is confirmed.

## 5. U-Boot / DRAM / boot
- Mod uses **stock U-Boot 2018.05 + stock kernel unchanged** — zero U-Boot/SPL/boot0 work exists in either repo.
- **DRAM: 128 MB is INTEGRATED into the T113-S3 package (SiP), not a discrete chip** (issue #26) — *"can't be increased."* So no RAM-upgrade path and no external DDR part to read; mainline U-Boot targets the **T113 DDR3 128 MB SiP** params (upstream sun8iw20/T113 DRAM driver), validated against a stock boot0 dump.
- xblax SDK targets **kernel headers 5.4**, `BR2_arm`/`BR2_cortex_a7`/`BR2_ARM_FPU_NEON_VFPV4`, GCC 14 / binutils 2.44 — consistent with our findings.

## 6. Kernel / mainline porting status
**None.** Everyone runs the stock sunxi BSP 5.4.61 and works around it (chroot, reuse stock fb/wifi). The chroot even `insmod`s the stock `8821cu.ko` from the host rootfs. ReForge's mainline-kernel + self-ported display plan is **greenfield** relative to this community — they give userspace/MCU/peripheral knowledge, **no kernel head-start**.

## 7. MCU details (HIGH VALUE — fully captured)
Both satellite MCUs = **Nations N32G455** (144 MHz Cortex-M4, STM32F1-ish). Klipper built with `CONFIG_BOARD_DIRECTORY=stm32`, `CONFIG_MCU=stm32f103xe`, `CONFIG_CLOCK_FREQ=144000000`, USART1, `CONFIG_SERIAL_BAUD=230400`, 12 MHz ref. USB VID/PID `0x1d50/0x614e`.
- **Mainboard MCU:** `CONFIG_MACH_N32G455xE`, app @ `0x08000000`, `CONFIG_INITIAL_PINS="!PB9"`, + `CONFIG_FLASHFORGE_LOADCELL=y`, `CONFIG_FLASHFORGE_TVOC=y`. Linux serial **`/dev/ttyS5`**. Flash tool: `NationsCommand -c -d --pn /dev/ttyS5 --fn <fw> --v -r`.
- **e-board MCU:** `CONFIG_MACH_N32G455xC`, app @ **`0x08010000`** (64 KB stock bootloader region). Linux serial **`/dev/ttyS1`**. Flash tool: `IAPCommand <fw> /dev/ttyS1`.
- **e-board serial-bootloader entry** (`mcu_update.sh`): `stty 230400 < /dev/ttyS1` then `echo $'~ \x1c Request Serial Bootloader!! ~' >> /dev/ttyS1` (0x1c=FS), then `IAPCommand`.
- **e-board run-time boot handshake** (`boot_eboard_mcu.c`, /dev/ttyS1 @115200 raw): MCU bootloader loops emitting `"Ready."` → host sends `'A'` (0x41) → MCU replies `0x06` (ACK) → app starts. Run at boot by `S55mcu_boot`. **Mainboard needs no trigger.**
- Stock blobs: `Mainboard-20230831.bin`, `Eboard-20231012.hex`, flashers under `/opt/PROGRAM/control/2.2.3/`. MCU updates call stock tools via stock `ld-linux.so.3 --library-path /mnt/orig_root/...`.
- **Full pin map in `printer_configs/printer.base.cfg`** (CoreXY, 220×220×220):
  - Steppers **TMC2209 UART** (sense 0.10Ω). X step PC1/dir PC0/en !PA1/uart PC2; Y PA3/PA2/!PA6/PA4; Z PC4/PA7/!PB1/PC5; Extruder on **eboard** PB14/!PB15/!PB12, uart eboard:PB10.
  - Endstops X `!eboard:PA15`, Y `!eboard:PB11`, Z `PB15`. Probe/load-cell `!PB4`.
  - Extruder heater `eboard:PA8`, therm `eboard:PA0` (3950); bed heater **PB9**, bed therm PC3 (4.7k).
  - **ADXL345 on e-board via soft-SPI**: cs eboard:PA4, sclk PA5, mosi PA7, miso PA6, 800 Hz.
  - **Load cell** = `flashforge_loadcell` (mainboard, custom Klipper module); **TVOC** = `flashforge_tvoc` (mainboard).
  - Fans: part `eboard:PB5`, hotend `eboard:PB4`, chamber PC6+en PC7 (HW PWM), internal PB6, external PB8, controller_fan PB7. Chamber LED PA8 (mainboard). Servo PC9. Filament runout `!PB14`, e1 `!PE1`. Power: btn `!PC15`, `_power_off` PC14, `_clear_power_off` PG1.

## 8. eMMC / partitions
Repos confirm only **`/data = /dev/mmcblk0p7`** (mod fsck+mounts it, chroot at `/data/.klipper_mod/chroot`, needs ≥512 MB free). Other partitions (boot-resource, env, dsp0/AR100 DSP, rootfs) **not enumerated** — full GPT/offsets require a **stock eMMC dump** (we have one: `tools/recovery/golden-kunos-*.img.gz`).

## 9. Peripherals
- **WiFi: RTL8821CU** confirmed (`8821cu.ko` from stock rootfs, USB, managed by **iwd**, `wlan0`). BT is part of the combo (unused by mod). [ReForge: mainline `CONFIG_RTW88_8821CU`.]
- **Ethernet** `eth0` (DHCP).
- **Camera:** none built-in; mod uses **ustreamer** for USB UVC (port 8080); SDK pulls libcamera/libv4l. Pro TVOC connector *might* be a serial camera (unconfirmed). Poor USB shielding → short cables.
- **Buzzer:** piezo on Linux **PWM `pwmchip0` ch6** (`consp/flashforge_ad5m_audio`, M300+MIDI).
- **Backlight:** separate Linux PWM.
- **Accelerometer:** ADXL345 (e-board soft-SPI).
- **Touch:** evdev via tslib + `uinput.ko`.
- 5M-vs-Pro: Pro adds TVOC, servo, extra fans/USB; base 5M depopulates servo/fan MOSFETs (GPIO pads exposed, issues #28/#29).

## 10. Top actionable items for ReForge (ranked)
1. **[Recovery/P0 de-risk]** Independently probe for **UART0 console + FEL** on USB-OTG — unexplored, biggest brick-risk reducer before any U-Boot/kernel work.
2. **[MCU/Plan 4]** Reuse stock **N32G455** MCUs with xblax's proven Klipper defconfigs (board stm32/stm32f103xe, 144 MHz, mainboard N32G455xE @0x08000000 /dev/ttyS5, eboard N32G455xC @0x08010000 /dev/ttyS1) + the **e-board handshake** (`Ready.`→`A`/0x41→0x06) + serial-bootloader trigger. Skips the RE g992 got stuck on.
3. **[Display/Plan 5]** Extract panel timings from a **stock eMMC dump** (DTB/fex/boot-resource), not these repos. Reuse the `lv_drivers` fb-ioctl patch + tslib/uinput touch path.
4. **[Partitions/Plan 5]** Map the full stock eMMC GPT/boot0/env/dsp0/rootfs offsets from our golden dump.
5. **[DRAM/Plan 5]** DRAM = T113 integrated 128 MB DDR3 SiP — use upstream sun8iw20/T113 params, validate vs stock boot0 dump. No discrete-chip retiming.
6. **[Peripherals/kernel]** Pre-plan drivers: RTL8821CU (rtw88), buzzer PWM (pwmchip0 ch6), backlight PWM, ADXL345 (MCU-side), touch evdev.
7. **[Rootfs/Plan 2]** Mine xblax buildroot configs as a **reference package list** (iwd, dropbear, ustreamer, moonraker, mainsail, guppyscreen, klipper patches) — but rebuild vs our mainline kernel/glibc, not their 5.4-headers SDK.
8. **[Process]** Keep the stock `.tgz`-updater path working until ReForge has its own flasher — currently the only no-hardware recovery route.

## 11. Links
- Hub: https://github.com/g992/flashforge-ad5m-5mpro-research (issues #25 external-CPU, #6 e-board handshake, #26 DRAM integrated, #28/#29 board diffs)
- PCB scan / RS232 pinout: `photo/AD5M PRO Pcb Scan.png`
- Klipper Mod (real engineering): https://github.com/xblax/flashforge_ad5m_klipper_mod
  - MCU: `build_overlays/common/usr/libexec/mcu_update.sh`, `device_tools/mcu/boot_eboard_mcu.c`, `tools/build/components/mcu_configs/ffad5m/{mainboard,eboard}`
  - Boot/chroot: `build_overlays/common/etc/init/S00klipper_mod`, `device_files/install/flashforge_init.sh`
  - Pin map: `printer_configs/printer.base.cfg`
  - Buildroot: `tools/build/buildroot/configs/{base,sdk,busybox.config}`
- Buzzer: https://github.com/consp/flashforge_ad5m_audio ; Backlight: https://github.com/loss-and-quick/flashforge_ad5m_backlight

**Could NOT find (remain ReForge tasks, need stock eMMC dump + HW probing):** panel timings/model/DTS; full GPT/partition offsets (only p7=data); U-Boot/boot0/DDR params; FEL or console-UART pinout.
</content>
