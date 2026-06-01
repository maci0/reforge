# Allwinner T113-S3 (sun8iw20) — mainline / LTS kernel support (Plan 5)

Research for ReForge Plan 5: replace the stock 5.4.61 vendor BSP with a mainline-LTS
kernel + a ported display driver, for the FlashForge Adventurer 5M Pro.

## TL;DR

The T113-S3 is **well mainlined** for everything except display polish and a few niche
peripherals. It's the same die as the RISC-V D1/D1s with the C906 core swapped for 2×
Cortex-A7, so nearly all peripherals reuse `allwinner,sun20i-d1-*` compatibles and the ARM
T113 "rides" the mature D1 work. Core bring-up (CCU, pinctrl, MMC/eMMC, USB, EMAC, I2C/SPI/
UART, DMA, thermal, watchdog) is fully upstream. The DE2 + TCON-LCD + MIPI-DSI display block
is in-tree, and crucially the **generic RGB/parallel (DPI) output path is already wired for
the D1/T113 TCON-LCD** — which is exactly what the AD5M Pro's 800×480 parallel TFT needs.
**Biggest risk = first-to-exercise RGB bring-up** (timing/clock/pinmux), not a missing driver.

## Recommended target

- **Kernel:** 6.12 LTS (fallback 6.6 LTS). T113 SoC + MangoPi MQ-R board landed v6.5.
- **U-Boot:** mainline ≥ 2024.10, base `mangopi_mq_r_defconfig` (T113 since v2024.01; switched
  to `OF_UPSTREAM`).
- **Board DT to fork:** `sun8i-t113s-mangopi-mq-r-t113.dts`, pulling the display pipeline
  wiring from `sunxi-d1s-t113.dtsi`.
- **Display path:** DE2 mixer → TCON-TOP → TCON-LCD → **RGB/DPI (`sun4i_rgb`)** → `panel-dpi`.
  Avoid LVDS (not upstream yet) and **do not** port the BSP `disp2`/`sunxi-disp` driver.

## Per-subsystem status (compatibles verified against torvalds/linux master)

| Subsystem | Status | Driver / compatible |
|---|---|---|
| CCU clocks + reset | ✅ mainline | `allwinner,sun20i-d1-ccu`, `-r-ccu` |
| pinctrl / GPIO | ✅ mainline | `sun20i-d1-pinctrl` (has `lcd_rgb666_pins` PD0–PD21) |
| MMC / eMMC | ✅ mainline | `sun20i-d1-mmc` / `-emmc` (`sunxi-mmc`) |
| USB (musb/ehci/ohci) | ✅ mainline | `sun20i-d1-musb` (⚠️ gadget PIO-only, no DMA) |
| EMAC | ✅ mainline | `sun20i-d1-emac` → `dwmac-sun8i` (a64 fallback). AD5M Pro has no ethernet. |
| I2C / SPI / UART | ✅ mainline | `sun20i-d1-i2c`, `-spi`/`-spi-dbi`, `snps,dw-apb-uart` |
| Watchdog / PWM / DMA | ✅ mainline | `sun20i-d1-wdt-reset`, `-pwm`, `-dma` |
| Thermal (THS) | ✅ mainline | `sun20i-d1-ths` + zones/cooling maps |
| cpufreq / DVFS | ⚠️ partial | OPP table exists for RISC-V D1s; **ARM T113s dtsi has no OPP** → run fixed-clock initially |
| Audio I2S / DMIC | ✅ mainline | `sun20i-d1-i2s` (r329 fallback), `-dmic` |
| Audio analog codec | ❌ out-of-tree | no `sun20i-d1` analog codec upstream (2023 patch unmerged). N/A for a printer. |
| WiFi | ❌ out-of-tree | MangoPi RTL8189FTV needs `rtl8189fs`; AD5M Pro module needs its own assessment |
| **Display — DE2 mixers** | ✅ mainline | `sun20i-d1-de2-mixer-0/1`, `-de2-clk` (`sun8i_mixer.c`) |
| **Display — TCON-LCD** | ✅ mainline | `sun20i-d1-tcon-lcd` → `sun20i_d1_lcd_quirks` (`has_channel_0=true` ⇒ RGB path) |
| **Display — TCON-TV / TCON-TOP** | ✅ mainline | `sun20i-d1-tcon-tv`, `-tcon-top` |
| **Display — MIPI-DSI + D-PHY** | ✅ mainline | `sun20i-d1-mipi-dsi` (a100 fallback), `-mipi-dphy` |
| **Display — LVDS** | ⚠️ out-of-tree | combo-PHY LVDS mode series was v3-in-review (Nov 2025); not needed (panel is RGB) |
| CAN/LRADC/GPADC/LEDC/RTC/crypto/SID | ✅ mainline | all `sun20i-d1-*` present |

## Display porting specifics (the load-bearing question)

The RGB/parallel (DPI) path is **already upstream**, verified in `drivers/gpu/drm/sun4i/`:
`sun20i_d1_lcd_quirks.has_channel_0 = true`; at TCON-LCD probe, when the output endpoint's
remote is not a `panel-lvds`, the driver calls `sun4i_rgb_init()` and attaches a generic RGB
encoder/connector to any `panel-dpi`/`simple-panel`. So porting the AD5M Pro panel is **device-
tree work, not a new C driver**:

1. Fork the MangoPi MQ-R-T113 DTS.
2. Enable `&de` + the mixer→tcon_top→tcon_lcd0 pipeline; add an **RGB output endpoint** on
   `tcon_lcd0_out` (the in-tree dtsi only pre-wires the DSI endpoint there).
3. Add a `panel-dpi` node with the 800×480 `panel-timing` + correct `bus-format`/`data-mapping`.
4. **Pinmux nuance:** in-tree defines `lcd_rgb666_pins` (18-bit RGB666). If the AD5M Pro panel
   is fed RGB888, declare a 24-bit `lcd0` pin group. "32 bpp" is almost certainly the XRGB8888
   framebuffer/DE format — the on-wire bus depth (565/666/888) must be read from FlashForge's
   BSP DT / schematic to set pinmux + `bus-format`.

**Risks:** no in-tree T113 board exercises the RGB path (all use MIPI-DSI), so you validate the
DE2→TCON_TOP→TCON_LCD→RGB mux + pixel-clock chain first on this SoC. RGB-on-sunxi itself is a
long-solved mechanism (A10/A20/V3s). No in-tree DVFS for the ARM cores (fixed clock initially).

## Sources

- linux-sunxi.org: [T113-s3](https://linux-sunxi.org/T113-s3), [mainlining effort](https://linux-sunxi.org/Linux_mainlining_effort), [MangoPi MQ-R](https://linux-sunxi.org/MangoPi_MQ-R)
- kernel.org: [ARM sunxi docs](https://docs.kernel.org/arch/arm/sunxi.html)
- torvalds/linux: [`sunxi-d1s-t113.dtsi`](https://github.com/torvalds/linux/blob/master/arch/riscv/boot/dts/allwinner/sunxi-d1s-t113.dtsi), [`sun8i-t113s.dtsi`](https://github.com/torvalds/linux/blob/master/arch/arm/boot/dts/allwinner/sun8i-t113s.dtsi), [`sun4i_tcon.c`](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/sun4i/sun4i_tcon.c), [`sun4i_rgb.c`](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/sun4i/sun4i_rgb.c)
- [MangoPi MQ-R-T113 DT patch (Przywara)](https://patchwork.kernel.org/project/linux-arm-kernel/patch/20230320005249.13403-5-andre.przywara@arm.com/)
- [clk: sunxi-ng R528/T113 (Holland)](https://lore.kernel.org/linux-arm-kernel/20221203002205.0f97d3bf@slackpad.lan/T/)
- [LVDS-on-D1s/T113 series (LWN)](https://lwn.net/Articles/1046783/)
- [u-boot: T113 OF_UPSTREAM](https://www.mail-archive.com/u-boot@lists.denx.de/msg557196.html)
- [NetCube Nagami T113-S3, mainline 6.18 (CNX)](https://www.cnx-software.com/2025/12/01/netcube-systems-nagami-allwinner-t113-s3-mini-pcie-som-features-esp32-wireless-soc-supports-mainline-linux/)

### Uncertainty notes
- LVDS-on-T113 not in master as of Nov 2025 (irrelevant — panel is RGB). Verify against the
  exact stable tag you fork.
- AD5M Pro panel on-wire bit depth must be read from FlashForge's BSP DT/schematic — not
  independently verifiable from public mainline sources.
