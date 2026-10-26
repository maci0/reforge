# Stock AD5M Pro bringup: source builds and byte-identity status

Rechecked 2026-10-26. **The complete original boot chain has not been rebuilt
byte-identically.** No bootloader, environment, MCU or flash device was written.
Reference bytes and source-build outputs are kept separately.

## Accepted kernel result and remaining bring-up target

On 2026-10-26 the user accepted the raw kernel's metadata-only difference.
Both Images are exactly 12,970,156 bytes; every instruction, embedded data byte,
kallsyms byte and padding byte in the delivered raw Image matches, except the
20-byte GNU build ID at `0xacc154..0xacc167`. The size delta is zero. Further
recovery of stripped kernel debug metadata is not a prerequisite for this
accepted bring-up result. This acceptance does not claim complete ELF identity.

The user subsequently authorized an explicit 20-byte build-ID patch. The
source-built `Image.source` and `vmlinux` are retained unchanged; the delivery
`Image` receives only that metadata patch. Its full SHA-256 then matches stock.
Building the actual kernel zImage from that delivery Image and generating the
legacy uImage metadata also reproduces both original wrappers byte-identically.
This is an explicitly patched delivery artifact, not a claim that the original
ELF/debug inputs have been recovered.

Independent boot stages and board configuration remain strict whole-file
byte-identity targets built from source. No target executable code is imported
from reference binaries.

The intentionally updated userspace packages and optional Klipper 13 firmware
retain their selected version pins. Their source-build repeatability is checked
separately from reproduction of immutable stock hardware bring-up artifacts.

## Reference identity and configured boot path

The reference is `tools/recovery/golden.img.gz`, compressed SHA-256
`c09dfbf7aa0e049d2ad179ccd7632b156667b5b0ae92ff2c914517963e21702e`.
The original Forge-X dump and independent AceOfBase stock dump corroborate the
primary boot0, primary TOC1 payload and environment. Exact member offsets,
lengths, checksums and hashes are in [stock-boot-artifacts.json](stock-boot-artifacts.json).

The validated redundant environments select
`run setargs_mmc boot_dsp0 boot_uImage`: U-Boot loads `uImage` and `sunxi.dtb`
from FAT partition p1. The Android `boot.img` on p4 is not the configured path
in these dumps. The saved [running-unit probe](running-unit-probe.txt) records
`uboot_message=2018.05-g2a24076-dirty(04/18/2025-11:25:23)`. The SDK appends
this argument from its compiled version/date/time in
`board/sunxi/sunxi_bootargs.c`; the captured environment has no override.
This identifies the 2025 build at that captured boot, consistent with the
golden backup payload. A UART trace has not independently established slot
selection. The 2023 primary remains the explicit byte-comparison target below;
it must not be described as the build observed running in that probe.

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
| boot0 / SPL | Two identical 48 KiB eGON copies at `0x2000` and `0x20000`; commit field `5224261`, DRAM driver `V0.32`, DDR3 at 792 MHz. | Two clean source builds reproduce all code, relocations, configuration, initialized data and packing bytes. Only **11 bytes differ**: the original seven-character commit label and its four-byte derived checksum. The archive naturally emits an empty label; original commit `5224261` remains unavailable and is not substituted. Whole-file comparison still fails. |
| Primary U-Boot | 2018.05, August 25, 2023 17:05:54 +0800; Linaro GCC 7.2.1 20171011, binutils 2.28.2.20170706. Historical source revision is unknown. | **Byte-identical source reconstruction verified:** 966,656 bytes, SHA-256 `31aaa8a085b4985dafdad87d97637fcc1d35a300101295edfaf51c826ff53019`. Uses pinned older source, recovered source changes and source-compiled control DTS. |
| OP-TEE secure world | Build `553fe17e2-dirty`, Linaro 5.3.1, build #6 dated February 18, 2022. | Sealed source-only recipe builds upstream 3.7, published SM3/SM4 and reconstructed T113 platform code. The resulting secure OS differs from stock and is research-only. The typed Allwinner header, reset sequence and physical mappings are recovered; standby/DRAM code, vendor services and exact code shapes remain incomplete. No prebuilt payload is imported. |
| Kernel delivery | p1 uImage decompresses to raw Image SHA-256 `902f44fe517aedd9424fa14adbf4f7c6212f372cfed10b19d479044a53111fa6`, 12,970,156 bytes. | **Whole-file identical after the user-authorized 20-byte metadata patch.** Untouched source output is preserved separately. Full ELF/debug identity is not claimed. |
| zImage / uImage | zImage SHA-256 `dd7fbccace45bbea6862597b86db12644480024ff6e276b93b6014123b9c5a34`; uImage `13c17296c9ed34cff1c355dc717ab76803410bd872a495bdefaca07cdaf89c79`. | **Whole-file identical**, actual source-built decompressor and gzip stream, after patching the raw Image before compression. Legacy header and both CRCs regenerated from source-defined metadata. |
| Board DTBs / environments | Kernel, primary TOC and U-Boot control DTBs; both 1-MiB environment partitions. | **Byte-identical configuration source builds verified.** Recovered DTS/text inputs and strict builder are committed; no firmware image is needed to build them. |
| DSP0 | Active boot command loads the Xtensa ELF from p5; 261,240-byte ELF SHA-256 `61ed4f199ca3b15f96c245a709282e1a4798b14d0f23a5e2930577487ebd20d1`, matching the held SDK firmware exactly. | Source build not yet reproduced. Original source version `sun8iw20_fpga_v0.5.0-37-gfb1fe0d`; matching Cadence RI-2020.4/compiler 14.04 acquired, but a real compile fails without an `XTENSA_XCC_TIE` entitlement. Original source revision/config still unresolved. |
| Wi-Fi module | Deployed flat RTL8821CU module, 2,441,368 bytes. | **Byte-identical source build verified**, SHA-256 `7c0a036726227752359556f8e109683d5ce836bb65ec64afd46bfb754d6afa69`; natural source-version and build-id, no metadata overrides. |
| Optional zram / zsmalloc modules | Add-on modules for the stock 5.4.61 ABI. | Now compiled from the pinned vendor BSP in a package-private tree; the static `swapon_prio` helper is compiled too. GCC 15.3 build verified exact vermagic and all required kernel/peer exports. Hardware loading has not been tested for this rebuild. |
| Rootfs / services | ReForge Buildroot source packages. | A fresh full source build completed in `build/output-source-clean`, separate from older installed-package stamps. Mainsail now builds from its source archive and locked npm dependencies with source-built Node.js. The fresh build completed successfully and passes ARM QEMU integration, including the live Moonraker API and Mainsail HTTP serving. Real printer boot remains untested. |
| Factory MCU applications / retained IAP | Mainboard and Eboard identify strings report `?-20230317_182329-ubuntu20-virtual-machine`, GCC 9.2.1, 144 MHz and STM32F103 identification with N32-like memory. | Original source/build identity unresolved. Public v0.11 STM32 selections do not explain those clock/RAM settings. The retained 64-KiB Eboard IAP is not present in the application HEX. Optional v13 repeatability does not establish factory equality. |
| Optional Klipper 13 mainboard / toolhead | Matching host and MCU source pin. | **Source repeatability verified:** two independently rebuilt newlib/MCU closures produce identical libraries and all 12 packaged firmware files, including ELF. This is the selected v13 upgrade, not factory MCU equality. No flashing. |

The held SDK is `/home/maci/Desktop/Projects/flashforge/lichee.zip`, containing
`lichee/brandy-2.0` and `lichee/linux-5.4`; archive SHA-256
`6ed0f793436067c694bcec3538b24861b48f8d914c603f48aa5939c26f158197`.
This is a bounded source inventory,
not a claim that the missing original source cannot exist elsewhere.

## Incomplete boot-stage source builds

The boot0 [research recipe](../../tools/build/README-stock-boot0.md) and OP-TEE
[research profile](../../vendor/optee/stock-patches/README.md) now compile from
pinned source archives plus recovered C/assembly. Neither is a verified
replacement for the original stage. Their comparisons require whole-file
identity and retain the candidate and difference report on failure; they do not
accept size equality as success or import original target code into the build.

Two clean boot0 builds, one outside and one inside this repository, produce
SHA-256 `dcc60dce4700e9658f3f8c5d25ccdde1d5424b5cbeed16910ea1200779f45cc4`.
Every byte outside `0x0c..0x0f` and `0x2f8..0x2fe` matches the original. The first
range is the valid regenerated checksum; the second is the empty archive-export
commit label versus stock ASCII `5224261`. The checksum difference is explained
entirely by that label. This is an 11-byte binary difference, with **zero size
delta**, not whole-file identity.

The boot0 packer reproduces the original host tool's default-seed glibc random
stream before overlaying compiled code and calculating the checksum. The stock
14,560-byte tail matches this algorithm; it is not copied from firmware. A
separate legacy chip-ID C unit requires GCC 4.6.3 while most code uses GCC 7.2.1.
Git discovery is bounded to the source build so an unrelated parent repository
cannot supply a false label. Neither the original label nor the checksum is
patched.

OP-TEE retains an honest reconstruction version label. Published SM3/SM4, the typed vendor header and recovered platform routines
compile, but standby/DRAM code, vendor services and complete configuration still
differ from the original secure OS. These candidates are
kept separate from the byte-identical U-Boot/kernel delivery outputs.

## Reproducible board configuration

The [recovered source configuration](../../br-external/board/reforge/stock/README.md)
compiles the kernel DTB, primary-TOC DTB, U-Boot control DTB and both redundant
environment partitions without reading a reference firmware image:

```sh
python3 tools/build/build-stock-board-data.py build/stock-board-data
```

The primary TOC tree differs from the kernel tree only in LCD PWM6 versus PWM7.
The TOC allocation is regenerated with zero padding. Environment encoding
preserves variable order and whitespace, computes CRC32 over the 128-KiB slot,
sets the active flag to 1, and zero-pads the remaining 1-MiB partition. The
builder checks all six generated artifacts against fixed original SHA-256 pins.

## Authorized kernel metadata patch and exact delivery wrappers

```sh
python3 tools/build/patch-stock-kernel-build-id.py Image.source Image.stock
```

The patcher requires the exact 12,970,156-byte profile and GNU note header. It
changes only `0xacc154..0xacc167`, refuses to overwrite an existing output, and
rejects the input unless the resulting whole-file SHA-256 is exactly the stock
`902f44fe517aedd9424fa14adbf4f7c6212f372cfed10b19d479044a53111fa6`.
This prevents a code/data difference from being concealed by the metadata patch.
The original input is left untouched and the emitted JSON records both IDs and
hashes. No naturally generated build-ID equality is claimed.

The full kernel recipe now requires `STOCK_UIMAGE=/path/to/original/uImage`
alongside its existing positional references. A clean run in
`build/stock-kernel-delivery-verified/` preserved `artifacts/Image.source` and
`vmlinux`, recorded `kernel-build-id-patch.json`, and built delivery `Image`,
`zImage`, `uImage` and `8821cu.ko` whose full bytes all match their originals.
An independent preceding wrapper build has the same result. `comparison.json`
checks the delivery Image, `kernel-source-comparison.json` retains the honest
20-byte source-output difference, and `wrapper-comparison.json` verifies the
complete uImage, payload, CRCs and metadata. The uImage timestamp is 1692776025;
the source kernel timestamp remains 1692776013.

## Original U-Boot comparison build

Use local source, a new output directory, and an explicitly supplied compiler
prefix; the script downloads
nothing, extracts no bundled binary toolchain, imports no prebuilt target code,
and never flashes. The source ZIP is pinned to
[`CamelShoko/longan-t113-u-boot-2018` at `fc662c13f3fde9d8bda1a2ad3fc53ff827f92576`](https://github.com/CamelShoko/longan-t113-u-boot-2018/tree/fc662c13f3fde9d8bda1a2ad3fc53ff827f92576),
SHA-256 `d4233e9c0f3695b5adf2ec8bb385b9f0f8e4b2e87748704a22367511ecd8b0ec`.
This older source snapshot matches both stock MMC/NAND revision markers; the
newer held SDK does not. Recovered stock changes are applied as a source patch.
The builder recompiles the recovered stock control DTS, then regenerates the length
and additive-checksum fields and aligns with `0xff` fill to the observed 16-KiB
boundary. It rejects any payload that cannot fit that natural stock span, without
truncating code. Recover the stock payload as a **reference**, then build:

```sh
python3 tools/recovery/extract-stock-boot.py tools/recovery/golden.img.gz build/stock-boot-reference
curl -fL https://codeload.github.com/CamelShoko/longan-t113-u-boot-2018/zip/fc662c13f3fde9d8bda1a2ad3fc53ff827f92576 -o /tmp/stock-uboot-source.zip
tools/build/build-stock-uboot.sh /tmp/stock-uboot-source.zip \
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

## Verified byte-identical primary U-Boot

A clean invocation of the current builder produced
`build/stock-uboot-identical/u-boot.bin`, **966,656 bytes**, with **zero differing
bytes** and SHA-256
`31aaa8a085b4985dafdad87d97637fcc1d35a300101295edfaf51c826ff53019`.
`cmp` against the extracted 2023 primary passes. An independently built and
packed development candidate has the same hash.

The source-built core is 932,512 bytes, followed by the 17,784-byte
source-compiled control DTB and 16,360 bytes of normal `0xff` alignment fill.
Only the image checksum and two packed-length fields change during packing.
Every executable byte comes from the source build; none is copied from the
reference. The challenge initializer and board configuration are recovered
non-executable source data.

The [source patch](../../tools/build/patches/stock-uboot-2023.patch) reconstructs
the observed boot logging, disabled USB-burn entry point, UART/I2C header pins,
HDMI PHY settings, MMC recovery argument and LCD wait before environment loading.
IDA Pro 9.4 decompilation and ARM disassembly established these changes.
Keeping the original USB-burn body after its early return preserves GCC's
`__func__` declaration IDs and the original linker string ordering.

`env_load` uses an explicit GCC loop-optimization setting and register variables
to reproduce the original instructions. These are reconstruction constraints;
the original author's source spelling and compiler flags have not been recovered.
The verified claim is complete artifact equality, not historical source identity.
The matching Linaro compiler is an existing binary toolchain; its source bootstrap
has not been established. No device flashing or new hardware boot was performed.

## Earlier generic-SDK comparisons

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

## Verified kernel source reconstruction

A clean source build in `build/stock-kernel-authentic-can-inputs/` produced a 12,970,156-byte
Image. Its complete executable region and every byte outside validated symbol and
build-id metadata match the original raw Image, SHA-256
`902f44fe517aedd9424fa14adbf4f7c6212f372cfed10b19d479044a53111fa6`.
**The complete rebuilt Image is not byte-identical:** only the 20-byte GNU
build-id differs. **This is a 20-byte binary difference, not a size difference:**
both original and rebuilt raw Images are exactly **12,970,156 bytes**, so the
size delta is **0 bytes**. The differing bytes occupy file offsets
`0xacc154` through `0xacc167` inclusive. All other 12,970,136 bytes match, including the entire
compressed kallsyms table. Earlier reconstructions differed by 13,029 bytes,
then 39 bytes; original framebuffer inputs and the recovered Goodix preprocessing
condition removed those differences without metadata overrides or post-link
corrections.

Both Images decode to identical 72,471 symbol names, addresses and types. The
[read-only checker](../../tools/build/compare-stock-kernel.py) validates the
compressed tables, markers, token indexes and zero alignment, checks all decoded
records, and compares every byte outside those validated metadata regions.
It reports `payload_equal` separately from `full_file_equal`; it never rewrites
symbols, build IDs or executable bytes. Its tests reject code/data mutations,
address/type/public-name changes and malformed metadata.

The foundation is the pinned
[`guanglun/longan-t113-linux-5.4` source at `d51ad00c047eccd5c88e807aedf56a5a25d9a155`](https://github.com/guanglun/longan-t113-linux-5.4/tree/d51ad00c047eccd5c88e807aedf56a5a25d9a155),
with selected original CAN/I2C/PWM source from the held BSP pin and the
[stock source patches](../../vendor/kernels/stock-patches). IDA Pro ARM32 analysis,
original kallsyms and object comparisons established the remaining changes:

The framebuffer implementation, display manager and display header were recovered
unchanged from `yangchaohong/AbFixedWings-kernel` at
`d2f4699308d190ad9abc96a879368be296e8dc63`: `dev_fb.c` SHA-256
`3ab64e3faf0ba3c599f300735aa7bcb9ab77477801cee4c7c4e3e409f6f77d34`
and `dev_disp.h` SHA-256
`67d71e7b9b6feed7227245eb8be6a74d1cb15bd684b76141b0a03de440908b43`.
The unchanged `dev_disp.c` from that same pin has SHA-256
`afc5d09ddb4337b27d1cf5cc0817ec09f677ae8d1f31796ab2f0636f6749e600`.
It also recovers the original placement of a compiled-out logging call,
which affects debug line mapping without changing code or functional data.
The original outer `int i = 0` declaration, shadowed by the parser's inner `i`,
explains seven private-symbol numbering differences in the earlier reconstruction.
Compiling these original files restores those names naturally; no symbol-name or
build-ID overrides are used.

The Goodix names identify a real missing preprocessing condition: `DEBUG` is
enabled for `gt9xx.o`. Without it, `include/linux/printk.h` declares an unused
`print_hex_dump_debug` inline function with seven parameters and a result entity;
with it, the header uses its existing macro branch. Those nine compiler entities
explain the uniform UID offset. A scoped `CFLAGS_gt9xx.o += -DDEBUG` restores all
ten stock names. All 15 allocated sections and all 4,960 relocation records
remain identical; no declarations or symbol strings are edited. The original
spelling/location of this setting is inferred, not recovered source text.

The original kernel's debug ELF was not found in the held archives. The SDK's
available `vmlinux` is a different June 2025 GCC 6.4.1 build, not the August 2023
GCC 5.3.1 target.

The CAN interface header is now the unchanged 149-line vendor file from
[`MYIR-ALLWINNER/myir-t1-kernel@2697a98867b8eb1d4059084a3aa3a357fc42a77f`](https://github.com/MYIR-ALLWINNER/myir-t1-kernel/blob/2697a98867b8eb1d4059084a3aa3a357fc42a77f/drivers/net/can/sunxi_can_asm.h),
SHA-256 `28dd938ae6ed015292b5f619b8cdc6c3a852d11ae1d412c57081737f28224d07`.
The recovered C helpers use its original prototypes. Their executable sections,
unwind data and relocations remain unchanged. The published assembly in that
tree is an older 2,964-byte implementation, rather than the stock 4,292-byte
implementation; the matching original helper C and debug inputs remain unknown.
With this header, the rebuilt Image SHA-256 is
`f5d40c6d7b14206e8464fbf80d02b0606609309f6c398460af168550d9e8db39`;
only the same 20-byte build-ID region differs. Wi-Fi remains byte-identical in
this clean build.

The kernel enables debug information, and GNU build IDs also depend on that
information before it is stripped from the raw Image. A check with the pinned
compiler/linker confirmed that changing only a C parameter name can change the
build ID while leaving every instruction unchanged. Exact source inputs remain
necessary for natural full-file identity; matching executable behavior does not
recover discarded source names or source-version hash inputs.

### IDA 9.4 build-ID investigation

IDA 9.4 inspected the original raw Image in its existing ARM32 database. At
`0xc0ad4144` (file offset `0xacc144`), `__start_notes` contains a GNU note with
`namesz=4`, `descsz=20`, `type=3`, owner `GNU`, and descriptor
`07002ca89d308edcf17b1bdca56d38bc46972263`. The descriptor occupies exactly
the remaining differing file range `0xacc154..0xacc167`. It is data, not a
function; the existing database reports no direct references to those bytes.
That reference result is bounded by the database's analysis coverage.

IDA 9.4 also decompiled the actual pinned Linaro linker (SHA-256
`aea26a4804c52ffbaa646b68254fc3136e355396eb755bf9389808caf198abc5`):
`generate_build_id` at `0x41f3a0`, `bfd_elf32_checksum_contents` at `0x45a0e0`,
and both `write_build_id` implementations at `0x421b20` and `0x4259a0`.
The SHA-1 branch initializes a hash, feeds the ELF checksum callback, and writes
the digest. The callback hashes normalized ELF headers and available section
contents, including debug contents; stripping those sections from the delivered
Image does not remove their prior contribution to the digest. The existing
read-only hash model independently reproduces the stock Wi-Fi module's ID.

This identifies the generation mechanism, not the original debug inputs.
The 160-bit digest cannot uniquely recover discarded source names, line tables,
or compilation paths. Candidate original inputs can be tested against it;
decompiling the digest as ARM instructions cannot reconstruct those inputs.
Local IDA exports and scripts are retained under `/tmp/reforge-ida-buildid/`;
they are research evidence, not build inputs or metadata overrides.

The exact forward calculation for this Linaro GNU ld 2.25 pipeline is now
implemented by the read-only
[`calculate-stock-build-id.py`](../../tools/build/calculate-stock-build-id.py):

1. Start SHA-1 with the 52-byte little-endian ARM32 ELF header, setting only
   `e_phoff` and `e_shoff` to zero in the hash input.
2. Append each 32-byte program header in ELF order, unchanged.
3. For each section in ELF order, append its 40-byte section header with only
   `sh_offset` zeroed. Then append its contents, except `SHT_NOBITS` and the
   `.symtab`, `.strtab`, and `.shstrtab` contents. Their headers still contribute.
4. In the GNU note's section contents, treat the entire generated 36-byte GNU
   note (header, owner and descriptor) as zero, matching the linker's write-time
   buffer. Preserve the neighboring Linux note and all other contents.
5. Store the resulting 20-byte SHA-1 digest as the GNU note's descriptor.

The symbol/string-table content omission models the observed BFD buffer state;
it is not a general exclusion rule for every GNU linker/version. This is also
not `sha1sum Image` or `sha1sum vmlinux`. It must run on the ELF before
`sortextable` and `objcopy`. Source text is not directly hashed; compiled debug
records can carry its names, line locations, types, options and paths into the
hashed ELF.

```sh
python3 tools/build/calculate-stock-build-id.py PRE_SORT_ELF
python3 tests/release/test_stock_build_id.py
```

The calculator independently reproduced the pre-sort kernel ID
`bed97c2650c095afe984b33260f005d8dc141eb9` and the original flat Wi-Fi module ID
`1b43ea87f9b4edd2fd9b48de9c8050a0013855ba`. Its test assembles and links an ELF
with the pinned historical tools, verifies the actual generated digest, and
checks that changing nonallocated debug contents invalidates it without
modifying the input file. It never writes a replacement ID.

### Reproducibility audit and remaining historical inputs

The [Reproducible Builds definition](https://reproducible-builds.org/docs/definition/)
requires the same source, environment and instructions. Its
[build-path guidance](https://reproducible-builds.org/docs/build-path/) and the
[kernel documentation](https://docs.kernel.org/5.15/kbuild/reproducible-builds.html)
identify debug paths as build inputs. For stock identity, those inputs must
match the historical build; choosing new normalized paths alone cannot establish
identity with an existing factory artifact.

A second clean build of the authentic-CAN-header recipe, under `LC_ALL=C`,
`TZ=UTC`, and `BUILD_JOBS=16`, reproduced all six staged artifacts exactly.
The complete 142,826,184-byte `vmlinux` SHA-256 is
`0a934d3309fdd49793cb9649134c1dd54ba4a8ff9f41062b65251f12d7b53d0c`.
The report is `build/stock-kernel-reproducibility-audit/reproducibility.json`.
This is a controlled same-host test, not proof across arbitrary host toolsets.

The kernel's checksum model was separately validated against an independent
pre-sort relink: it naturally computes the stored
`bed97c2650c095afe984b33260f005d8dc141eb9` ID. The final ELF differs from that
pre-sort ELF by one byte: `main_extable_sort_needed`, raw Image offset
`0xb2a174`, changes from 1 to 0. Thus hashing the final ELF without accounting
for post-link processing is an invalid test of the linker's algorithm. The
checksum includes normalized ELF/program/section headers and available section
contents, including DWARF, `.comment`, and `.ARM.attributes`; it is not a hash
of debug information alone. Research evidence is in
`/tmp/reforge-kernel-link-audit/model-report.json`.

The audit also found 42 compilation units whose line tables embedded the host's
physical GCC include directory under `/home/maci/`. The builder now binds the
compiler itself into the namespace at the SDK root's
`out/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi` directory. The layout is
supported by vendor build scripts and recorded as inferred in `inputs.json`;
the exact factory compiler directory is not yet recovered. This is an actual
compiler invocation/path change, not a debug-section rewrite or ID override.
The clean trial at `build/stock-kernel-sdk-toolchain-path/` has no `/home/maci/`
paths in any debug section. Its Image SHA-256 is
`48335d88a43ffcc14bd7d341bd2f98adeea4a73b2bc0527f9c61c8df2b2882c5`,
ID `a776534a8692e21511f8b66c56519f62013e9a44`; it still differs from stock
only in the 20-byte ID. Wi-Fi remains fully identical.
An independent clean invocation of the updated production recipe at
`build/stock-kernel-toolchain-path-verified/` reproduced all six artifacts
exactly, including full `vmlinux` SHA-256
`edee648898df7b07717dc6ec1df3d95896564c097b79c246b87d92c55068fba6`.
Its `reproducibility.json` records the whole-file checks.

Four justified CAN debug/pipeline variants were retested after correcting the
compiler path. A control reproduced that new baseline exactly; none of the
variants recovered the stock ID. All preserved the complete payload outside
the ID. Incremental experiments must restore `artifacts/kernel.config` and
regenerate configuration headers first: the completed builder's working tree
has the later module configuration. Invalid trials using that module profile
were discarded. Results: `/tmp/reforge-can-sdk-toolchain/report.json`.

The next original-input evidence must establish the factory compiler directory,
the kernel output-directory spelling, and the actual source/debug envelope of
reconstructed translation units. Useful evidence includes the original SDK's
`.buildconfig`, build logs or `.cmd` files, matching generated CAN assembly,
and original debug ELF/object files as read-only comparison references. Final
acceptance remains a fresh source build whose whole raw Image SHA-256 equals
`902f44fe517aedd9424fa14adbf4f7c6212f372cfed10b19d479044a53111fa6`;
reproducibility of a different Image does not satisfy that check.

The complete current `disp_lcd.c` is also authenticated as an unchanged vendor
file in [`turing-machines/linux@dc6e999b53b3994078cff097ca569a3143660185`](https://github.com/turing-machines/linux/blob/dc6e999b53b3994078cff097ca569a3143660185/drivers/video/fbdev/sunxi/disp2/disp/de/disp_lcd.c),
SHA-256 `5b8d11ea9a8419963a1006eb4dce15a9b825080456bbed73585ad7ada4d043f5`.
This corroborates its whole source text, not just the compiled behavior. The
distinct JasonYANG170/LubanCat source was rejected because it requires a
`get_gamma_tbl` device member absent from the original ABI and removes the
original reload helper; that candidate was not adapted to force a match.

### Tested path and source/debug candidates

On 2026-10-26, a bounded matrix tested **64 unique combinations**: two output
directories, four compiler installation directories, and eight CAN source/debug
envelopes. Exact paths, profiles, per-case Image hashes and build IDs are recorded
in [stock-kernel-input-trials.json](stock-kernel-input-trials.json).

The output directories were the current `_s3` SDK's `out/kernel/build` and the
earlier checkout's same directory, observed directly in stock module DWARF.
Compiler locations covered the SDK's `out/gcc-linaro-...`, `out/toolchain/gcc-linaro-...`,
`out/external-toolchain/gcc-arm`, and the earlier checkout's `out/gcc-linaro-...`.
These are evidence-backed candidates, not confirmed factory kernel paths.
Board-specific `longan` output paths were rejected before building: actual SDK
scripts use them for platform packaging, not kernel objects. Their explicit
kernel output formula supports `out/kernel/build`.

CAN variants covered normal C debug, caller/helper debug omissions, variable
spellings recovered from published vendor assembly, and two source-generated
assembly pipelines. One pipeline replayed the vendor's actual expanded compiler
arguments. Its naturally generated producer prefix matches all **5,347 bytes /
85 lines** of the published assembly prefix exactly. Its reconstructed helper
algorithm retains the original 4,292 executable bytes and 104 unwind bytes;
this does not establish the missing original helper C source text.
The generic assembly was generated once per output directory using the control
compiler path; the vendor replay used its separately recorded vendor path.
The four compiler locations vary the kernel compilation environment, not every
possible combination of earlier assembly-generation environments.

**Result: zero whole-file stock matches.** Every Image is exactly 12,970,156
bytes (**0-byte size delta**), with every byte outside the 20-byte GNU descriptor
matching stock. Each directory's control reproduces its independent clean
`vmlinux` and Image exactly. A separate read-only verification checked all 64
saved Images and recomputed every pre-sort ELF's stored build ID using the
validated linker model. No stock objects, manual line padding, debug-section
rewrites or build-ID overrides were used.

The captured kernel configuration was restored and its generated headers
regenerated before compiling. Thin archives were regenerated with actual Kbuild
commands after object sizes changed. Intermediate failed setup attempts were
excluded; only the 64 validated cases are counted. Scratch recipes, commands,
objects, pre-sort/final ELFs and Images remain under
`/tmp/reforge-compiler-path-axis/`.

These results reject these particular combined reconstructions, not every
possible historical path, source spelling or debug configuration. A chance
19-byte rather than 20-byte descriptor difference is not evidence of being
closer to the correct SHA-1 input. Production source defaults were not changed
to any negative candidate.

### Field-by-field ELF header audit

The calculator can expose every header field and its exact serialized hash input:

```sh
python3 tools/build/calculate-stock-build-id.py PRE_SORT_ELF --headers
```

[stock-kernel-elf-headers.json](stock-kernel-elf-headers.json) records the current
52-byte ELF header, nine 32-byte program headers and 39 40-byte section headers:
**1,900 hashed header bytes**. Across the 64 candidates, all 52 ELF-header bytes
and all 288 program-header bytes are identical. Of 476 decoded header fields,
466 are invariant. Only these ten vary:

| Fields | Identified input causing variation |
|---|---|
| `sh_size` for `.debug_line`, `.debug_info`, `.debug_abbrev`, `.debug_aranges`, `.debug_frame`, `.debug_ranges`, `.debug_loc`, `.debug_str` | Actual debug contents, paths and compilation pipeline. |
| `.symtab.sh_size`, `.symtab.sh_info` | Local ARM `$d` mapping symbols contributed by debug sections. Removing one C debug-frame contribution removes one 16-byte symbol and lowers the first-global index by one. |

Compiler-path changes affect `.debug_line.sh_size` by exactly 42 times their
path-length delta. Shortening the output directory by 13 characters removes
728 bytes from `.debug_info` (56 inline directory strings) and 13 bytes from
the shared `.debug_str`; the assembly helper adds one further inline directory
string. These are causally explained input changes, not unexplained header noise.

Physical `e_phoff`, `e_shoff` and section `sh_offset` values are zeroed in the
hash input. Program-header **`p_offset` is not zeroed**. Original segmentation,
ABI flags, stack permissions, section counts and nonallocated section sizes
remain unknown: the inspected stock uImage/zImage/raw Image contains no valid
original kernel ELF header or header tables. Original kallsyms constrains entry,
loaded addresses and BSS bounds; it does not recover those stripped tables.
Current fields are consistent with those known address constraints, but must
not be labeled directly verified original header bytes.

Headers alone are insufficient. The generic and vendor-replayed assembly
candidates have identical complete hashed headers, but one different hashed
`.debug_line` byte: `eb 00` versus `e4 00` encodes `DW_LNS_advance_line` by
107 versus 100. It places the first instruction at line 108 versus 101 and
shifts all 1,046 line rows by seven. Both source files compile to identical
machine code; the seven-line difference arises naturally from compiler-generated
verbose option comments. The vendor replay reproduces the published producer
prefix without editing comments or line numbers. Neither candidate's original
factory line mapping is known. Header values or sizes were not forced to invent
a stock match.

The expanded stock-constraint pass derives **43 individual address/size fields
across all 25 allocated sections**, two composite section-end expressions, and two
vector/stub load addresses from original kallsyms and the known generated linker
script. All match the current ELF. All **143 linker location-marker addresses**
also match. The JSON audit records each expected value, actual value, original
symbol evidence and linker-script rule. These are conditional section-layout
constraints, not recovered original ELF tables.

Examples include `.text` at `0xc0100000`, size `0x69be10`; `.notes` at
`0xc0ad4144`, size `0x3c`; and `.data` at `0xc0c00000`, size `0x60060`.
The `.data` end is constrained by original `__stop___verbose` and
`__start___bug_table` both being `0xc0c60060`, leaving no intervening constructor
or alignment bytes. The audit deliberately does not equate `__end_rodata` with
the `.rodata` section end, or `__bss_start` with the `.bss` section start: the
current latter difference is a 20-byte alignment gap, not an image-size delta.

Four of these field constraints come from original named strings, without copying
current object sizes: 1,526 module-metadata records cover every byte from
`0xc0a45280` through `0xc0a54efa`, and 9,093 exported-name/namespace records cover
`0xc0a6f758` through `0xc0a9ad5c`. Original raw NUL terminators establish sizes
`0xfc7b` and `0x2b605`; the actual input declarations are character arrays with
alignment one. These results remain conditional on the same section association
and absence of extra trailing output padding. Exit-code start is independently
bounded by original `_einittext` and the first `__exit` function
`ikconfig_cleanup` both at `0xc0b2795c`; no function size is assumed.

ABI evidence independently supports the current defaults. All 25 original module
ELFs match the kernel's full 16-byte ELF identity and ARM/EABI5 target. Their
306 common ARM attribute values have no conflicts with the kernel. Seven
nonlayout header fields each for `.comment` and `.ARM.attributes` match all
25 modules; their whole section sizes differ because a full executable and
relocatable modules have different merge inputs and rules.

The modules' `e_flags=0x05000000` must not be copied into the kernel. GNU ld 2.25
adds `EF_ARM_HASENTRY=0x2` for a nonzero entry, and `EF_ARM_ABI_FLOAT_SOFT=0x200`
for an EABI5 executable without the VFP argument tag. The relevant operations
were verified in the actual pinned Linaro linker binary as well as the GNU 2.25
source. They explain the kernel's `0x05000202`; no evidenced ABI fix was found.
The source hashes and binary instruction addresses are included in the JSON.

Thus the expanded checks found no inconsistent header value to correct through
build inputs. Original kernel segment grouping, permissions, exact header counts
and stripped metadata remain unverified. No header field was changed merely to
increase a claimed match count.

### Remaining hash-input verification

[stock-kernel-hash-input-verification.json](stock-kernel-hash-input-verification.json)
records the follow-up checks, their scope, and the original inputs still missing.
The current pre-sort ELF feeds **138,771,303 bytes** into the validated checksum:

| Input group | Hashed bytes | Verification boundary |
|---|---:|---|
| Normalized ELF/program/section headers | 1,900 | Current generation independently reproduced; original tables absent. |
| Loaded section contents | 10,596,544 | Compared by load address with original raw bytes; only GNU descriptor and pre-sort flag differ. Original pre-sort exception-table order remains unknown. |
| Debug sections | 128,172,763 | Original module debug records corroborate a subset; original kernel debug bytes absent. |
| Compiler comment | 45 | Exact current output reproduced with real source-built inputs and linker merge rules; original kernel bytes absent. |
| ARM attributes | 51 | Exact current output reproduced from source-built inputs; original modules corroborate common tags, not the whole original kernel section. |

Actual linker experiments with the already byte-identical source-built Wi-Fi
module reproduce its 8,142-byte relocatable comment and naturally reduce it to
45 bytes in a final executable. Three source-built inputs (that module,
`head.o`, and `proc-v7.o`) reproduce the kernel's exact comment and ARM attribute
contents. A trace of all 1,841 selected kernel objects finds one compiler identity
in all 1,780 comment-bearing objects; 61 have no comment. No foreign compiler or
host-path strings were found in those input metadata sections. Division and
virtualization tags originate in `proc-v7.o`, rather than an unexplained metadata
override. This verifies the reconstructed merger behavior, not missing original
kernel bytes.

The two stock modules retaining debug information independently encode the same
140 complete named records across 45 kernel headers. Comparing them with 15
current kernel compilation units yields 3,878 definition-pair comparisons with
no conflicts. There are 133 exact unique record matches and seven for which all
original observed fields match but current records add sizes absent from original
forward declarations. Layouts, member names/types/offsets, enum values and
declaration locations are checked. This semantic subset comparison normalizes
known checkout prefixes only in the read-only comparison; it does not establish
byte identity for original kernel DIE ordering, references or complete debug data.

All 270,681 current DWARF file entries have timestamp and length zero, as do the
56 entries in each original module CU. Decoding all 1,350,776 current line-program
operations found no dynamic file definitions. No CU date/time attributes were
found. Thus stored source-file timestamp/length fields are not a differing input
in the observed debug information. Exactly 1,764 current producer strings match
the original modules' complete compiler/options string; the remaining assembler
and per-file optimization/frame-pointer variants follow actual Kbuild inputs.

All 72 current program-header fields and all 39 section-name offsets were
independently reconstructed from the real input graph and linker policy, with
zero differences. The RWE stack header is explained by 61 legacy assembly inputs
without GNU-stack notes and GNU ld's missing-note default; writable `.rodata`
comes from 37 `ro_after_init` input sections. No unexplained header generation was
found. These checks do not recover the original header tables or original input
section grouping.

The loaded comparison also distinguishes link time from delivered-image time:
`sortextable` clears its source-defined flag after the ID is calculated. The
current exception table is already ordered before sorting, but the original
pre-sort order cannot be uniquely recovered from its sorted raw Image. That is
another unobserved original hash input, separate from debug information.

Bounded lookups for the original ID returned no indexed GitHub code match and no
debug/executable artifact from `debuginfod.elfutils.org`; this is not a global
absence claim. **Complete verification against the original link-time hash stream
remains unachieved.** The original unstripped ELF, matching debug/build artifacts,
or complete historical inputs are needed to compare the unavailable bytes.

| Area | Recovered original behavior |
|---|---|
| Framebuffer | Defer freeing the boot framebuffer until display startup plus 30 ms; use the original uncached ION allocation and panel layout. |
| Display manager | Restore the canonical 200-byte private state, seven-entry reference history and older DMA-buffer aging/unmap logic. All 66 manager functions match. |
| CAN | Replace the differing generated-assembly implementation with recovered C: 13 helper routines, 4,292 executable bytes and all unwind descriptors match. Preserve original volatile arithmetic, firmware calls and controller I/O. Restore the original unassigned CAN reset-map entries and C-driver diagnostic behavior. |
| IR / GMAC / SPI | Restore old receiver globals/PM behavior, MII register dump, GMAC clock/reset behavior, per-transfer SPI buffers and both stock polling fixes. Original diagnostic locations are retained. |
| Regulator / MMC / touch | Restore the fixed 4-ms CPU-regulator delay, 30-MHz MMC default, original touch sampling thresholds and selected boot diagnostics. |
| Core / DMA / IOMMU / LCD | Restore zeroed FUSE allocation, DMA NULL guard, IOMMU resume clock enable and original DPHY clock lifetime. The LCD source is pinned to `yangchaohong/AbFixedWings-kernel@d2f4699308d190ad9abc96a879368be296e8dc63`. |

The stock MCU UART links use the existing built-in `sunxi-uart` source; no missing
separate MCU Linux module was found. `boot_code` is an IR global, not a bootlogo
function. The earlier missing-symbol-only classification was insufficient;
whole-file comparison also exposed shared-function and initialized-data changes.

The source-built RTL8821CU module is now **byte-identical** to the original flat
`/lib/modules/8821cu.ko`: 2,441,368 bytes, SHA-256
`7c0a036726227752359556f8e109683d5ce836bb65ec64afd46bfb754d6afa69`.
Independent fresh driver compilation and a clean full reconstruction both pass
whole-file comparison, including all 4,448 functions, every symbol, relocation,
debug section, operational metadata, source-version and GNU build-id. The
[module checker](../../tools/build/compare-stock-module.py) reports both
`full_file_equal=true` and static equivalence.

The original source-version `91923B9ABAF58831D5783DF` is computed naturally from
source; the original GNU build-id follows naturally during linking. No hash,
symbol or metadata values are substituted. Embedded controller firmware remains
upstream C-array data; its original firmware source has not been reconstructed.

Thirteen older vendor source bodies restore native stock warning locations,
eliminating every Wi-Fi `#line` directive. Ten files are unchanged from the pinned
kernel's RTL8821CS v5.12 source, one is unchanged from Khadas's pinned March 2021
USB release, and two restore older vendor API bodies. The baseline USB transmit
source is retained. Exact file hashes and immutable references are recorded in
[the input manifest](../../vendor/kernels/stock-patches/rtl8821cu-sources.json).
Untouched files retain their original bytes, including three mixed-format CRLF
source files. Normalizing those files changes the source-version despite
identical compiler output. Preserving them and selecting the genuine vendor
bodies recovered the historical checksum and complete ELF identity.

The module's earlier missing six compiler IDs are reproduced by a real Kconfig
profile enabling `CONFIG_TCP_MD5SIG`. Moving the existing namespace import in
`osdep_service.c` immediately after its includes restores its last lock-key ID.
These changes reproduce all symbol strings naturally, without renaming them.
The profile is inferred from output constraints, not a recovered original
configuration file. Several diagnostic preprocessor states gave the same count;
this chosen profile survives actual Kconfig resolution and preserves every code,
data, ABI, operational-metadata and DWARF byte. The module configuration differs
from the captured kernel configuration in this one setting only. The builder
stages `kernel.config` before configuring the module, checks the module's resolved
configuration against that expected delta, and records `module.config` separately.

A read-only GNU ld 2.25 model independently recomputes the original and rebuilt
module's build IDs. This verified that source-version recovery, rather than an
explicit build-ID override, resolves the linked identity. Historical source text
is not uniquely identified by binary equality; the pinned reconstruction is
proven to reproduce the complete deployed module.

Kernel source builds use the exact captured configuration and the historical
Linaro 5.3.1 compiler. A private bubblewrap namespace supplies both original build
paths without changing host `/home/linux` or resetting the BSP checkout.
The kernel output is also bound inside that namespace at the SDK-layout
`hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/out/kernel/build` path. This removes
the caller-selected output directory from DWARF. Two clean builds in distinct
output directories produced byte-identical full `vmlinux`, raw Image and Wi-Fi
module; the original kernel output-path spelling remains an SDK-layout inference.
The module's corresponding earlier-checkout output path is directly recorded in
its stock DWARF.
The builder rejects existing outputs, verifies all source/reference hashes,
rejects prebuilt object/archive/module members and records source/toolchain pins.
Source archives and reference artifacts are separate; target code is compiled
from C/assembly, including the newly recovered CAN C implementation.

```sh
curl -fL https://codeload.github.com/guanglun/longan-t113-linux-5.4/tar.gz/d51ad00c047eccd5c88e807aedf56a5a25d9a155 -o /tmp/stock-kernel-source.tar.gz
curl -fL https://codeload.github.com/rugameuser/8821cu-20210118/tar.gz/b6ad883ea547cbd5d144e6218cc122bb4de4ffc4 -o /tmp/stock-wifi-source.tar.gz
STOCK_UIMAGE=/path/to/original/uImage \
  tools/build/build-bsp-kernel-stock.sh /tmp/stock-kernel-source.tar.gz \
    /tmp/stock-wifi-source.tar.gz /path/to/original-Image.raw \
    /path/to/original-flat-8821cu.ko build/stock-kernel-reproduced
```

Host requirements include bubblewrap, Python with pyelftools, normal kernel build
tools and the pinned compiler under `vendor/toolchains/`. The captured raw Image
and flat module must have the reference hashes above. The similarly named module
under `/lib/modules/5.4.61/` is a different packaging variant and is not this target.
Artifacts, logs and both comparison reports survive under the new output directory.
No hardware execution was observed. Original SPI/IR cleanup quirks are retained
for source fidelity; the reconstruction does not silently repair stock behavior.

## Earlier kernel comparison and limits

The closest cached source reconstruction is
`build/bsp-kernel-rebuild-stock/artifacts/Image.ours-linaro`, SHA-256
`8fa9bb8ddc316b28fc83d107727ea11c25f64fd0fa85f349c8e464ad72831b18`,
12,970,284 bytes. It is 128 bytes larger than stock, with 5,915,891 differing
bytes at shared offsets. The first difference is `0xf968c`: exactly 1,021,580
leading bytes match, less than 1 MiB. Matching banner and IKCONFIG are useful
diagnostics, not whole-image identity or hardware-equivalence proof.

The historical comparison used a Wi-Fi Kconfig stub, not a working source build
of the original RTL8821CU module. Kernel and Wi-Fi reconstruction checks above
supersede that source-gap classification; full new artifact equality remains a
separate check.

Completing the remaining boot chain requires boot0's DRAM implementation and
the secure-world OP-TEE source, including vendor changes. Those stages are not
yet source-built. The primary U-Boot reproduction and kernel execution-payload
reconstruction are verified above; historical lexical source identity remains
unproved where explicitly noted.
Source builds, strict byte comparisons, and recoverable hardware boot validation
are separate milestones; only observed results are marked above.
