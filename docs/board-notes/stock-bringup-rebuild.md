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
| Primary U-Boot | 2018.05, August 25, 2023 17:05:54 +0800; Linaro GCC 7.2.1 20171011, binutils 2.28.2.20170706. Stock source revision is unknown. | Candidate built from the held SDK's U-Boot C/assembly sources with recovered/recompiled stock control DTS and observed stock image packing. Packed size is now 966,656 bytes, equal to stock, but byte comparison still fails. Complete original FlashForge config/source revision remains unproven. |
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
and never flashes. It disables the measured extra T050K589 panel and memory-info
features, recompiles the recovered stock control DTS, then regenerates the length
and additive-checksum fields and aligns with `0xff` fill to the observed 16-KiB
boundary. It rejects any payload that cannot fit that natural stock span, without
truncating code. Recover the stock payload as a **reference**, then build:

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
Two independent clean source extractions/builds of the initial generic SDK
profile produced candidate SHA-256
`d6290d48f2c935b34d12ceebf2e28e5b7aed81fd5fcf71a874b4208ba082f3a0`.
The original SDK Linaro host-tool archive was used for this comparison; a source
bootstrap of that historical compiler is not established.
The initial generic SDK candidate had 873,000 mismatched bytes at common offsets;
the first was offset 12 (the header checksum). Its final image packing had not
yet been reproduced. The corrected size-zero result is recorded below.

## Initial generic-SDK size difference (2026-10-25 investigation)

The 195-byte increase is a net artifact-layout difference, not a 195-byte code
change. Compared with the original primary U-Boot payload:

| Region | Stock bytes | Candidate bytes | Candidate minus stock |
|---|---:|---:|---:|
| Header | 1,600 | 1,600 | 0 |
| Executable text | 522,872 | 524,624 | +1,752 |
| Read-only data and its end alignment | 197,212 | 198,000 | +788 |
| ELF hash table | 24 | 24 | 0 |
| Alignment before data | 4 | 0 | −4 |
| Data, GOT and linker lists | 114,552 | 131,060 | +16,508 |
| ARM-relative relocations | 96,248 | 96,952 | +704 |
| Appended control DTB | 17,784 | 14,591 | −3,193 |
| Final `0xff` packing fill | 16,360 | 0 | −16,360 |
| **Total** | **966,656** | **966,851** | **+195** |

The pre-DTB part is 19,748 bytes larger. Stock relocation entries occupy
`0xcc2a8..0xe3aa0`; candidate entries occupy `0xd0d0c..0xe87c4`. There are
12,031 versus 12,119 `R_ARM_RELATIVE` entries, explaining the 704-byte increase.
The stock ELF/map is unavailable; its text/data boundaries were recovered from
the unique 32-pointer CPSR-name table, matching 24-byte ELF hash, 16-byte timer
object and consecutive relocation records. Candidate boundaries also match its ELF.

A controlled source rebuild disabling only `CONFIG_LCD_SUPPORT_T050K589`
removes **16,616 pre-DTB bytes**: a 15,264-byte JD9365 initialization table,
52-byte panel descriptor, 4-byte panel-list pointer, 720 bytes of text,
324 bytes of read-only data/alignment, 256 relocation bytes and a −4-byte
alignment adjustment. Disabling `CONFIG_SUNXI_MEM_INFO` as well removes another
**1,492 bytes**: 280 bytes of text, 260 bytes of read-only data/alignment, 4 bytes
of alignment, an 800-byte `g_memory_info` table, a 28-byte command descriptor and
120 relocation bytes. The stock data layout has no corresponding memory-info table.

The two controlled changes remove 18,108 of the 19,748 extra pre-DTB bytes.
**1,640 bytes remain**: +752 text, +204 read-only data/alignment, −4 pre-data
alignment, +360 data and +328 relocations (41 entries). This residual is not
explained away as relocation noise. The 360 data bytes are exactly six additional
60-byte SPI-NAND chip descriptors: `DS35X2GBXXX`, `SCN00SA3W1AI8A`,
`GD5F4GQ6UEY1G`, `FS35SQA001G`, `XT26G02CWSIG`, and `XT26G04CWSIG`.
One existing descriptor (`XT26G01C`) also changes its `OperationOpt` from `0x7`
to `0x1`, selecting dual-read instead of the original quad-read/program capability
flags. The remaining instruction/source attribution is incomplete.
The generic SDK source/config is not the original FlashForge source snapshot.

The source revisions also differ observably: the stock MMC driver marker is
`uboot2018:2021-09-07 19:43:00`; the held SDK's
`drivers/mmc/mmc_def.h` embeds `uboot2018:2021-12-20 13:35:00`. Stock and candidate
also have different USB, partition-update and SPI debug strings. These are real
source/config differences, not merely timestamp or pointer-relocation noise.

The DTB difference is completely enumerated: stock has one extra node and
110 additional properties; its structure is 2,068 bytes larger and its string
table 1,125 bytes larger. Other changes include phandle renumbering and three
display-pin mux values. The recovered stock control DTS recompiles to all
17,784 original DTB bytes exactly (SHA-256
`488d06dfbab38e7e6d06ec9354e2fdb4d8ceadfa89b082641c1d2073a37c6731`).
This solves that configuration artifact, not the remaining executable differences.

The offset-wise ledger at `build/stock-uboot-diff/byte-differences.tsv.gz` records
all 873,000 changed shared-offset bytes and all 195 appended bytes. Applying
those entries to the stock payload was checked to reconstruct the candidate
exactly. `layout-comparison.json` contains region boundaries, while
`dtb-semantic.diff`, `dtb-comparison.json` and `string-diff.json` retain the
complete configuration/string differences. These are local generated artifacts,
not target firmware or a source-level patch.

## Size-zero source build

The corrected builder now emits **966,656 bytes**, exactly the stock packed
length, with `size_delta: 0` and `size_matches: true` in `comparison.json`.
The source-built core is 934,152 bytes, the recovered/source-compiled stock
control DTB is 17,784 bytes, and normal 16-KiB packing adds 14,720 bytes of
`0xff` fill. No executable bytes are truncated or copied from the reference.
The checksum and both image-length header fields are regenerated.

The clean build at `build/stock-uboot-size-zero/` produced SHA-256
`92ccc0b70ae4dde5fc6b987e0e06c5147431f94acca2e7620418cee0d18ab6e2`.
This matches an independently packed controlled source build. Tests cover exact
repacking, preserving a larger core, corrupted references/DTBs, and refusing
payloads that would require truncation or forced size matching.

**Size equality is not byte identity:** the unpadded core remains 1,640 bytes
larger than stock, reducing packing fill by the same amount. There are 786,077
different bytes at shared offsets in the packed images. The script therefore
continues to exit nonzero for the strict byte-comparison failure. No hardware
boot or flashing was performed.

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
