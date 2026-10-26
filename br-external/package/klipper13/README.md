# Klipper 13 host and AD5M MCU source builds

Selecting `BR2_PACKAGE_KLIPPER13` builds the host, mainboard firmware, and toolhead
firmware from **one pinned source commit**:
[xblax/klipper `fc2aaae692b5f703420915390a3dcb8cd514c384`](https://github.com/xblax/klipper/tree/fc2aaae692b5f703420915390a3dcb8cd514c384)
(tag `v0.13.0-285-gfc2aaae69-ffadm5`). The upstream v0.13.0 release alone lacks
this fork's AD5M board variants and FlashForge load-cell/TVOC support.

The source-built bare-metal toolchain uses Buildroot's GCC, binutils and newlib
packages, targeting Cortex-M4/Thumb with software floating point and multilib
disabled. Generic ARM/Thumb libraries are not a compatible substitute for the
M-profile runtime. This package does not depend on `host-arm-gnu-toolchain`, which downloads
a prebuilt compiler. Standard newlib replaces `libc_nano` in the MCU link; the
existing section garbage collection and per-board size check keep the images
within the configured flash bounds.

## Comparison with other mods

Checked 2026-10-25:

| Mod | Public build/installation path | What ReForge uses |
|---|---|---|
| xblax | [Buildroot package](https://github.com/xblax/flashforge_ad5m_klipper_mod/blob/2500307003bfb5c81b23894de8be42c2c4d30766/build_scripts/buildroot/package/klipper/klipper.mk) compiles the matching fork once per board config and installs BIN, HEX and ELF images. | Its pinned source, board configs and local-version patch; a source-built compiler replaces its downloaded compiler. |
| ZMod | [Runtime repository](https://github.com/ghzserg/zmod_klipper/tree/a53f1356cca740634575822fe7254713aab5ddd1/mcu/ff5m) contains prebuilt images; [update_mcu.sh](https://github.com/ghzserg/z_ff5m/blob/aefbfc7c6175e0e967ce05cac53c8f964b3e3314/.shell/update_mcu.sh) passes Mainboard.bin to NationsCommand and Eboard.hex to IAPCommand. The [public Klipper fork](https://github.com/ghzserg/klipper/tree/3a1d8f37dcdb9229c831febd037f3c9245620892) has N32G455 support, but the inspected repositories do not establish a reproducible mapping from its source/configs to those shipped images. | No binaries imported. |
| Forge-X | [Its comparison](https://github.com/DrA1ex/ff5m/blob/main/docs/MOD_COMPARISON.md) describes retaining native MCU firmware, unlike xblax's rebuilt firmware. | No MCU firmware imported. |

The configs in `mcu-configs/` are copied without changes from xblax's
[`ffad5m` configs at `2500307003bfb5c81b23894de8be42c2c4d30766`](https://github.com/xblax/flashforge_ad5m_klipper_mod/tree/2500307003bfb5c81b23894de8be42c2c4d30766/build_scripts/components/mcu_configs/ffad5m).
The local-version patch retains its original author and sign-off.

| Setting | Mainboard | Toolhead (`eboard`) |
|---|---|---|
| Part | N32G455xE | N32G455xC |
| Crystal / MCU clock | 12 MHz / 144 MHz | 12 MHz / 144 MHz |
| UART | USART1, 230400 baud | USART1, 230400 baud |
| Application address | `0x08000000` | `0x08010000` (64 KiB bootloader retained) |
| Initial GPIO | `!PB9` (bed heater off) | none |
| FlashForge load-cell / TVOC driver | enabled | disabled |

The original configs conservatively limit flash to 128 KiB for both parts. The
build enforces that limit, including the toolhead's bootloader reservation.

## Outputs and checks

A `klipper13` build installs `mainboard.{bin,hex,elf,dict,config}` and
`eboard.{bin,hex,elf,dict,config}`, plus `SOURCE` and `SHA256SUMS`, into:

- `images/klipper13/` in the selected Buildroot output directory;
- `/opt/klipper/firmware/` inside the built target image.

`check-mcu.py` rejects wrong board variants, clocks, baud rates, oversized images,
invalid initial stack/reset vectors, and MCU versions that differ from the host.
`make unit` includes negative tests for these packaging boundaries. The source
configs and expanded configs are both available for review.

Validation on 2026-10-25: source-built GCC 16.2.0, binutils 2.47 and newlib
4.6.0.20260123 produced a 42,256-byte mainboard image and a 37,384-byte toolhead
image. Both passed the checks above and contained no ARM-state code. The ARM
host also imported and loaded its rebuilt helper under QEMU. No hardware
calibration or MCU UART session was exercised.

Repeat-build validation on 2026-10-26 found that GCC's random LTO seed and source
paths affected ELF debug/symbol metadata, while BIN, HEX, protocol dictionary and
configuration already matched. The package now uses relative per-output compiler
seeds and compiler-input path maps; it does not rewrite output files. Newlib's
own compilation maps its source/build paths, and its archiver/indexer use normal
deterministic creation flags instead of retaining object timestamps and owners.

Two clean newlib-and-firmware builds in different-length source/build paths and
timezones produced identical eight newlib archives and identical BIN, HEX, ELF,
dict and config files for both boards. A separate relocated-compiler test also
passed. The source-built GCC/binutils compiler binaries were reused, not
bootstrapped twice. No research-directory paths or predefined date/time macro
tokens remain in the final firmware debug sections. The mainboard/toolhead BIN
hashes remain `f2a7e808e635344d1c4f09f53a844af8b2695b1c952ecfaa413991c7c8a28061`
and `9efa694e117cdbeaf92f9e401f727122598a099c3edb208acb8fa05b335a6385`.
This checks reproducibility of the pinned v13 firmware, not equality with the
different factory MCU version.

These are build artifacts. The package does not invoke a flasher or change either
MCU on a connected printer. Review the v13 printer configuration and the recovery
path before flashing; a successful build does not validate motors, heaters,
load-cell calibration or real UART communication.
