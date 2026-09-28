# T113-S4 256 MB RAM upgrade (AD5M SoC swap)

A community hardware mod that replaces the AD5M's stock Allwinner **T113-S3**
(128 MB in-package DDR) with the pin-compatible **T113-S4** (256 MB), doubling
system RAM. It is the permanent fix for the 128 MB memory pressure that this
project keeps hitting: the resonance / input-shaper calc OOM, the matplotlib
plot generation that OOM-killed klippy, and the general headroom problem (see
[the software mitigations](#software-relevance) below).

Source kit: `Переделка на T113-S4 08-01-25.zip` ("Conversion to T113-S4"),
manual v2 by **Dark Simpson** (2024), assembled bootloader by **@xplayerx_d**.
Companion to [`stock-kernel-genealogy.md`](../reverse-engineering/stock-kernel-genealogy.md)
(the SoC lineage) and [`partition-map.md`](partition-map.md) (the eMMC layout
this mod flashes into).

## The swap

- **Stock part:** Allwinner **T113-S3** = `sun8iw20`, dual Cortex-A7, **128 MB**
  DDR3 SiP.
- **Upgrade part:** **T113-S4**, full marking **`T113M4020DC0`** ("M4" variant),
  same `sun8iw20` family and pinout, **256 MB** SiP DDR. Sourced from AliExpress
  or local electronics suppliers.
- **Install:** TQFP package, hot-air reflow swap. No reballing or BGA skills
  needed (the manual notes any phone-repair shop can do the swap in minutes).

The SoC is pin/package compatible, so the only firmware change required is the
**DRAM init** (which lives in `boot0`) and a DTB fix (below). The kernel,
rootfs, MCU firmware, and the rest of the eMMC are untouched.

## Enabling FEL (the real enabler)

The stock AD5M does **not** expose a usable FEL path: per
[`partition-map.md`](partition-map.md), USB0's pads are internal and there is no
broken-out UART, which is why stock recovery is "eMMC-reader-only." This mod's
first job is to *create* a FEL entry point so the new `boot0` can be flashed:

1. Solder a **USB header** (e.g. neokt593 PBS2-04) to the internal USB0 pads.
2. Solder a **momentary button**: one leg to **GND**, the other to the **CMD**
   line running to the eMMC. Holding it during power-on prevents the mask ROM
   from reading eMMC, so the SoC falls through to **FEL** (USB recovery) mode.
3. A 3.3 V **UART-to-USB** adapter on the board's UART header (GND, RX, TX,
   crossed TX/RX) for boot log visibility.
4. A **USB-FEL cable** from a spare USB-A cable: `red=5V` (left **disconnected**
   for FEL), `white=RX`, `green=TX`, `black=GND`. Reversing 5V/GND destroys the
   board.

Entry: terminal open, hold the button, plug the USB-FEL cable, board LEDs light
but UART goes quiet = FEL is up. On Windows the FEL device needs the WinUSB
driver via Zadig.

## Flashing

Tool: **`xfel_t113_ds.exe`** (Dark Simpson's fork of `xfel` with direct-eMMC
access; ships with `libusb-1.0.dll`). Windows-only binary in the kit; see
[Linux note](#linux--tooling-note).

```
xfel_t113_ds version
# expect: AWUSBFEX ID=0x00185900(R528/T113) dflag=0x44 dlength=0x08 scratchpad=0x00045000

xfel_t113_ds extra sdmmc um3 sm0 detect
# expect: MMC found, size reported

# write the 256 MB-DRAM boot0 to the primary slot, then the backup slot:
xfel_t113_ds extra sdmmc um3 sm0 write 0x00002000 ad5m_bt0_t113m4_emmc.bin
xfel_t113_ds extra sdmmc um3 sm0 write 0x00020000 ad5m_bt0_t113m4_emmc.bin
```

Writing both `boot0` slots (0x2000 primary, 0x20000 backup) is the brick-safety
measure; combined with the existing eMMC dump for recovery, risk is low.

### Buzzer fix (optional)

After the swap the buzzer may go silent (only a couple of clicks at boot). Cause:
FlashForge shipped a DTB with the buzzer PWM channel and the display PWM channel
swapped. On the S3 the PWMs reset on DTB reload so it self-corrects; on the S4
they do **not** reset, so the bad first-config sticks. Fix by flashing the
corrected bootloader package:

```
xfel_t113_ds extra sdmmc um3 sm0 write 0x01004000 ad5m_sunxi-package_dtb_fix.bin
```

## The kit's binaries

| file | type | role |
|---|---|---|
| `ad5m_bt0_t113m4_emmc.bin` | Allwinner **eGON.BT0** SPL (48 KB) | boot0 with **256 MB DRAM init** (auto-scans rank/width/size); strings show the standard sunxi DRAM bring-up + NAND/eMMC drive code |
| `ad5m_sunxi-package_dtb_fix.bin` | Allwinner **TOC1** image ("sunxi-package") | full bootloader bundle: `u-boot` (0xec000) + `optee` (0x494d8) + **dtb** (0xe800) with the buzzer PWM channel corrected |
| `xfel_t113_ds.exe` + `libusb-1.0.dll` | Windows binary | modified xfel FEL flasher with direct-eMMC write |

### eboard_run (companion tool)

`eboard_run.zip` is a separate Dark Simpson tool (static ARM, `main.c` + Makefile
included, cross-built with the buildroot `arm-...-gnueabihf` SDK). It boots the
**Klipper MCU firmware** on the AD5M Eboard from bootloader mode over
`/dev/ttyS1` @ 115200: it waits for the `Ready.\r\n` marker, sends the `A`
activation byte, and expects a `0x06` ACK. Useful when the MCU sits in its
bootloader after power-on and needs a nudge to run the application firmware.

## Software relevance

This upgrade makes the OOM workarounds we added for the 128 MB board into
belt-and-suspenders rather than load-bearing:

- forge-x `shaper_calibrate.py`: the result-pipe `poll()` drain, the 150 MB
  RLIMIT_AS cap on the calc child, the `oom_score_adj` victim marking, and the
  EOFError handling (forge-x PR #70).
- `zshaper.sh`: rendering the matplotlib plots as the first OOM victim.
- klippy `oom_score_adj=-1000` (device `start.sh`) so heavy steps never kill the
  host.

With 256 MB, the resonance FFT and the plot render fit comfortably and none of
those caps trip in normal use.

## USB and swap

Question that comes up alongside the RAM mod: would a USB-to-NVMe adapter for
swap help instead of / as well as the SoC swap?

- **The board is USB 2.0 only.** The `sun8iw20` SoC has no SuperSpeed PHY; the
  stock kernel/DTB expose `sunxi_ehci` (USB 2.0 high-speed host) + `sunxi_ohci`
  (full/low speed) + a MUSB OTG. There is **no XHCI / USB 3.0**. Real-world
  throughput is roughly 30-40 MB/s sequential and, more importantly, poor 4 KB
  random IOPS (single-queue BOT/UAS over a 480 Mbps link).
- **A USB-NVMe adapter is capped at USB 2.0**, so NVMe speed is irrelevant; you
  get USB 2.0 performance regardless of the drive behind it.
- **For swap specifically it is a poor fit.** Swap is small random I/O; USB 2.0
  random latency is high. The board already runs **zram** (compressed RAM swap,
  ~320 MB), which is RAM-speed and far better for the transient pressure that
  causes the calc/plot OOM. A USB disk swap would only act as a slow last-tier
  behind zram: it would avoid the OOM-kill but stall for seconds while thrashing.
- **Verdict:** not worth it. The T113-S4 256 MB upgrade is the real fix; zram +
  the software caps cover everything else. A USB swap file buys little over zram
  and adds an adapter, mount/fstab setup, and flash wear.

### Network-block-device swap (NBD over Ethernet)

Same idea from the network side: expose a remote block device (NBD/iSCSI) over
the board's 100 Mbit Ethernet and swap to it. Same conclusion, plus a new hazard.

Reference numbers (measured on this unit, `dram-clk` = 1584 MHz → **DDR3-1584**):

| swap tier | bandwidth | per-page latency | failure mode |
|---|---|---|---|
| **zram** (already present) | RAM-bound; ~50-150 MB/s effective (zstd-on-A7-bound) | tens of ns (RAM) | none |
| eMMC swapfile | ~10-30 MB/s random | ms, local | flash wear |
| USB-2.0 disk | ~10-30 MB/s | ms, local | adapter / wear |
| **NBD / 100 Mbit** | **~10-11 MB/s** | **hundreds of µs to ms, over TCP** | **network blip = kernel blocks in D-state on the page fault = printer freeze mid-print** |

Internal RAM (what zram swaps to) is **GB/s-class** (DDR3-1584; measured
memcpy ceiling ~1 GB/s, theoretical peak ~3 GB/s at 16-bit) with nanosecond
latency. NBD over 100 Mbit is roughly **100x slower bandwidth and ~1000x worse
latency**, and crucially it makes swap I/O depend on the network staying up: a
WiFi roam or NBD-server hiccup parks the kernel uninterruptibly on a swap-in,
which on a printer means a frozen print. zram and local disk cannot fail that
way.

**Verdict:** workable only as a deep last-resort overflow tier behind zram
(swap priorities: zram high, NBD low) purely to dodge an OOM-kill in extreme
cases, accepting the slowness and the network-hang risk. Marginal over what zram
already provides. The 256 MB SoC upgrade remains the real fix.

## Reference eMMC dump

The kit shipped with a full stock eMMC dump (`emmc_backup_AceOfBase_dump.bin`,
zip password `123`), useful as a recovery reference. Its teardown lives in
[`fw-archive/analysis/stock-emmc-dump-2.7.2-aceofbase.md`](../../../fw-archive/analysis/stock-emmc-dump-2.7.2-aceofbase.md):
stock FW 2.7.2, kernel 5.4.61, partition layout matching
[`partition-map.md`](partition-map.md).

## Credits and provenance

- Manual v2 and the xfel fork: **Dark Simpson** (`@darksimpson`). xfel ds-mods
  for direct T113 eMMC access are not public until finished; available on request
  from the author.
- Assembled bootloader: **@xplayerx_d**.
- eMMC reference dump: **AceOfBase**.

## Linux / tooling note

The kit's flasher is a Windows `.exe`. On Linux, mainline
[`xfel`](https://github.com/xboot/xfel) supports the T113 and has `sdmmc`
commands; the direct-eMMC `write` behaviour used here may need Dark Simpson's
fork or a mainline equivalent. `eboard_run` builds on Linux directly from the
included `main.c` + Makefile (point the Makefile's `CROSS_TOOLCHAIN_BIN_PATH` at
an `arm-...-gnueabihf` toolchain).
