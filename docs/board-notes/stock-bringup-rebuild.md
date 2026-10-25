# Stock AD5M Pro bringup: source builds and byte-identity status

Rechecked 2026-10-25. **The complete original boot chain has not been rebuilt
byte-identically.** No bootloader, environment, MCU or flash device was written.
Reference bytes and source-build outputs are kept separately.

## Reference identity and configured boot path

The reference is `tools/recovery/golden.img.gz`, compressed SHA-256
`c09dfbf7aa0e049d2ad179ccd7632b156667b5b0ae92ff2c914517963e21702e`.
The original Forge-X dump and independent AceOfBase stock dump corroborate the
primary boot0, primary TOC1 payload and environment. Exact member offsets,
lengths, checksums and hashes are in [stock-boot-artifacts.json](stock-boot-artifacts.json).

The validated redundant environments select
`run setargs_mmc boot_dsp0 boot_uImage`: U-Boot loads `uImage` and `sunxi.dtb`
from FAT partition p1. The Android `boot.img` on p4 is not the configured path
in these dumps. A UART trace has not established the primary/fallback U-Boot
slot selected by the physical machine at runtime.

There are three distinct DTBs: the appended U-Boot control FDT (17,784 bytes),
the TOC external FDT (55,093 bytes within a 59,392-byte allocation), and the FAT
p1 kernel FDT (55,093 bytes). The TOC primary FDT names `lcd_pwm_ch6`; the p1
kernel FDT names `lcd_pwm_ch7`. The independent stock p1 FDT matches the golden
p1 FDT exactly, so the latter difference is not evidence of a local modification.

The golden backup TOC at `0x1004000` contains a different
`U-Boot 2018.05-g2a24076-dirty` build dated April 18, 2025. The independent stock
backup instead matches the original 2023 primary. The golden image therefore
must not be described as an unchanged factory boot chain throughout.

## Source-build status

| Stage | Original identity | Current result / missing input |
|---|---|---|
| boot0 / SPL | Two identical 48 KiB eGON copies at `0x2000` and `0x20000`; commit field `5224261`, DRAM driver `V0.32`, DDR3 at 792 MHz. | Held SDK's `spl-pub/nboot/Makefile` links `board/sun8iw20p1/libsun8iw20p1_sdcard.a`, an ELF relocatable without the DRAM implementation source. No source-only replacement or byte-identical rebuild is claimed. |
| Primary U-Boot | 2018.05, August 25, 2023 17:05:54 +0800; Linaro GCC 7.2.1 20171011, binutils 2.28.2.20170706. Stock source revision is unknown. | Candidate built entirely from the held SDK's U-Boot C/assembly/DTS sources. It is 966,851 bytes versus stock 966,656; comparison fails. Original FlashForge config, board DTS, exact source revision and final vendor packing remain unproven. |
| OP-TEE secure world | Build `553fe17e2-dirty`, Linaro 5.3.1, build #6 dated February 18, 2022. | Held `lichee.zip` contains U-Boot/Linux client shims, not the secure-world OP-TEE OS source tree. No prebuilt payload is imported into source-build outputs. |
| Kernel | p1 uImage decompresses to raw Image SHA-256 `902f44fe517aedd9424fa14adbf4f7c6212f372cfed10b19d479044a53111fa6`, 12,970,156 bytes. | Cached public-source reconstruction has matching banner and embedded config, but a different complete Image. See comparison below. |
| Rootfs / services | ReForge Buildroot source packages. | Existing ReForge build path; no full image boot validation was performed in this audit. |
| Mainboard / toolhead | Matching Klipper 13 host and MCU source pin. | Integrated [source-build package](../../br-external/package/klipper13/README.md), with per-board checks and image/checksum output. No flashing. |

The held SDK is `/home/maci/Desktop/Projects/flashforge/lichee.zip`, containing
`lichee/brandy-2.0` and `lichee/linux-5.4`; archive SHA-256
`6ed0f793436067c694bcec3538b24861b48f8d914c603f48aa5939c26f158197`.
This is a bounded source inventory,
not a claim that the missing original source cannot exist elsewhere.

## Original U-Boot comparison build

Use local source, a new output directory, and an explicitly supplied compiler
prefix; the script downloads
nothing, extracts no bundled binary toolchain, imports no prebuilt target code,
and never flashes. Recover the stock payload as a **reference**, then build:

```sh
python3 tools/recovery/extract-stock-boot.py tools/recovery/golden.img.gz build/stock-boot-reference
tools/build/build-stock-uboot.sh /path/to/lichee.zip \
    /path/to/linaro-7.2/bin/arm-linux-gnueabi- \
    build/stock-boot-reference/u-boot.bin build/stock-uboot
```

`build-stock-uboot.sh` uses an isolated temporary source tree and records archive,
source-tree, compiler, config and reference identities. It recovers the original
128-byte generated challenge initializer as C source data from the reference:
the vendor Makefile otherwise generates it with `/dev/urandom`. It also freezes
the original timestamp. Those inputs do not establish that the generic
`sun8iw20p1_auto_defconfig` or source snapshot is FlashForge's exact original.

Outputs include source-built ELF/BIN/DTB files, build logs, `inputs.json`, and
`comparison.json`. **A successful compilation with a byte mismatch exits nonzero.**
Two independent clean source extractions/builds produced candidate SHA-256
`d6290d48f2c935b34d12ceebf2e28e5b7aed81fd5fcf71a874b4208ba082f3a0`.
The original SDK Linaro host-tool archive was used for this comparison; a source
bootstrap of that historical compiler is not established.
The current candidate has 873,000 mismatched bytes at common offsets; the first
is offset 12 (the header checksum). Final vendor image packing is not reproduced.

## Kernel comparison and limits

The closest cached source reconstruction is
`build/bsp-kernel-rebuild-stock/artifacts/Image.ours-linaro`, SHA-256
`8fa9bb8ddc316b28fc83d107727ea11c25f64fd0fa85f349c8e464ad72831b18`,
12,970,284 bytes. It is 128 bytes larger than stock, with 5,915,891 differing
bytes at shared offsets. The first difference is `0xf968c`: exactly 1,021,580
leading bytes match, less than 1 MiB. Matching banner and IKCONFIG are useful
diagnostics, not whole-image identity or hardware-equivalence proof.

The historical `build-bsp-kernel-stock.sh` needs the original absolute source
path and mutates/resets its source checkout. It is not invoked automatically by
the U-Boot comparison build. Future integration must use an isolated source copy
at the original path inside a controlled namespace, rather than reset the shared
vendor checkout. The historical path is currently not populated with usable source.
The public-source reproduction also contains a Wi-Fi Kconfig stub, not a working
source build of the original RTL8821CU module.

Finishing the original source-only bringup requires the original boot0 DRAM
implementation, secure-world OP-TEE source including dirty changes, original
U-Boot build inputs/packing, and resolution of the kernel/module source gaps.
Source builds, strict byte comparisons, and recoverable hardware boot validation
are separate milestones; only observed results are marked above.
