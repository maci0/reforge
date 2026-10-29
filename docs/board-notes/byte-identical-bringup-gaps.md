# Byte-identical bring-up: remaining gaps

Updated 2026-10-28; original baseline implementation was `2e5c7dd`.
**The complete captured
machine image and complete original boot chain are not yet reproducible byte
for byte from source.** This is the current gap ledger; the longer
[build/status record](stock-bringup-rebuild.md) contains recipes and history.
Reference offsets and hashes are in [the artifact manifest](stock-boot-artifacts.json).

“Identical” means complete-file byte equality, including metadata and padding.
A zero size delta, matching function shapes, a valid checksum or successful boot
does not establish that equality. Source reconstruction, source-build
repeatability, stock equality and hardware validation are separate claims.

The early-boot firmware gaps are G01–G05; G09 covers strict runtime source
closure, G10 covers factory MCU firmware, and G12 covers physical validation.
G06/G07/G11 additionally apply when claiming complete partitions, the captured
disk or original userspace. Updated ReForge userspace is intentionally a separate
target. G08 is the accepted kernel ELF/debug residual, not an open mismatch in
the explicitly patched delivery images.

## Verified results that are not open binary gaps

| Component | Established result | Boundary |
|---|---|---|
| 2023 primary U-Boot | All 966,656 bytes match stock; SHA-256 `31aaa8a085b4985dafdad87d97637fcc1d35a300101295edfaf51c826ff53019`. | This is the primary 2023 target, not the different 2025 backup. Historical source revision remains unknown despite byte-equivalent reconstructed source. |
| Kernel delivery Image / zImage / uImage | All three delivery files match stock after the explicitly authorized 20-byte raw Image build-ID patch. | Natural `Image.source` and `vmlinux` remain unmodified. Original ELF/debug provenance is still open under G08. |
| Deployed flat RTL8821CU module | Complete 2,441,368-byte file matches stock, including naturally generated source-version/build-ID fields; SHA-256 `7c0a036726227752359556f8e109683d5ce836bb65ec64afd46bfb754d6afa69`. | This proves the selected flat module, not every module/firmware variant elsewhere in the rootfs. |
| Kernel, primary TOC and U-Boot control DTBs | Recovered DTS builds match their respective reference files. | LCD PWM7 kernel tree and PWM6 primary TOC tree are deliberately distinct. |
| Both environment partitions | Complete 1-MiB files match stock, including redundant-format flag, CRC, record order and padding. | Does not prove their placement inside a newly generated whole-disk image. |
| ReForge rootfs | Fresh source build and ARM QEMU integration pass, including live Moonraker API and source-built Mainsail. | Updated distribution, not stock rootfs equality; one full fresh build, not two-image reproducibility certification. |
| Optional Klipper 13 firmware | Two clean newlib/MCU closures reproduce all 12 packaged files; matching host package also builds. | Intentional v13 upgrade, not the factory MCU firmware. Same source-built compiler binaries were reused across the repeat-build test. |

The integrated Buildroot kernel uses GCC 15. The stock-identical kernel delivery
comes from the separate historical-toolchain recipe. These outputs have distinct
provenance even though the integrated device DTB now matches stock exactly.

## G01 — boot0 source label and derived checksum

**Known binary difference, zero size delta.** Both original copies are 49,152
bytes. Two clean source-archive builds, inside and outside this repository,
produce SHA-256 `dcc60dce4700e9658f3f8c5d25ccdde1d5424b5cbeed16910ea1200779f45cc4`.
Original SHA-256 is `f9397c286a0faba8cf19d7583b8f508470ce5e2ea1e6c53621d77d9f9b66093e`.

| Offset | Differing bytes | Original | Source-archive build |
|---|---:|---|---|
| `0x0c..0x0f` | 4 | Additive checksum `0x778af875` | Correctly regenerated checksum `0x4327900e` |
| `0x2f8..0x2fe` | 7 | ASCII `5224261` | Zero bytes from the naturally empty archive-export commit label |

Every other byte matches at the same offset: **49,141 identical byte positions**,
including executable instructions, real relocations, DRAM/board configuration,
initialized data and deterministic packing. Both checksums are valid; their
entire difference is explained by the label. The source label occupies a
16-byte field; the other nine bytes already match.

**To close:** recover the authentic original source/Git or original generated
input that naturally produces `5224261`. No original-label substitution or
checksum override is currently authorized. The strict builder still exits 1.
See [the boot0 recipe and source provenance](../../tools/build/README-stock-boot0.md).
G09 separately records compiler-runtime source closure.

## G02 — OP-TEE runtime, layout and original build inputs

**Actual executable/source gaps remain.** Original Allwinner carrier:
300,248 bytes, SHA-256
`7ccd7a54ae2142f68d6bac60e3e2b36ccbfa2ec677aa6ce84342cc6f1b821c99`.
Current clean source candidate: 287,208 bytes, SHA-256
`7b21094f8e5f9cedc37da04c4a3d21a4ff8bc512f39543e901dc3367e357f604`
(after standby/MMU/reset reconstruction, secondary-boot/PSCI inputs and PSCI identification).
The **size delta is −13,040 bytes**; **244,444 byte positions differ in the
shared extent**. Neither number means that exactly 13,040 instruction bytes are
missing: section layout, data and alignment also contribute.

Remaining work:

- **Standalone SRAM standby program:** original carrier offsets `0x4000..0x60cf`
  contain an 8,400-byte independently linked initialized image for SRAM address
  `0x20000`. Its 240-byte parameter header precedes ARM entry at `0x200f0`.
  The entry clear loop writes `0x220d0` through `0x2229c` **inclusively**;
  original allocated BSS/linker-symbol bounds remain unverified.
  All initialized code/data now build from reconstructed C/ARM source plus the
  published division runtime. The [source recipe](../../tools/build/build-stock-optee-standby.sh)
  emits **8,400 bytes, size delta zero, with exactly eight differing byte positions**.
  Every other byte matches directly, without normalization. The eight positions
  are low address-immediate bytes in MOVW instructions for the BSS clear bound,
  clock auxiliary word and TWI state. The strict full-file comparison exits 1;
  no difference is accepted as an exception. Exact offsets/values and hashes are
  in the [complete-image proof](stock-optee-standby-full-proof.json).
  The source BSS has saved SP (4 bytes), the observed DRAM snapshot extent
  (424), clock auxiliary word (4) and TWI state (12): 444 bytes versus the recorded
  clear-bound span of 460. The remaining **16-byte layout gap** is unexplained;
  original declarations/object extents/alignment are needed. No placeholder
  tail, recorded-address override or post-link substitution closes it. Ordinary power-of-two
  alignment of the next object directly after the 424-byte snapshot is ruled
  out: snapshot end `0x2227c` cannot round up to stock auxiliary address
  `0x2228c` for any power-of-two alignment. A larger original allocation,
  omitted object or more complex linker layout remains necessary; this does
  not prove a 110-word array. [BSS address/alignment audit](stock-optee-standby-bss-layout-proof.json)
  decodes the reference MOVW/MOVT pairs and records the bounded calculation.
  The 240-byte initialized parameter area matches all bytes. Its DRAM prefix
  follows the BSP type; some extension meanings and original debug names remain
  unknown. Both copied-source builds reproduce every object and the ELF/bin,
  and the strict checker rejects byte or trailing-length mismatches.
  ARM tests exercise snapshot/write/restore behavior in four virtual MMIO banks,
  prior clock/TWI/register/regulator paths and real source division/stack helpers.
  Entry, privileged CP15/WFI, PLL lock and full DRAM resume execution remain
  untested. The source SRAM image is now embedded in the main secure-OS
  carrier through a source assembly wrapper. Its 12 ARM NOPs arise from
  256-byte alignment, followed by zero alignment to the 16 KiB boundary.
  All 7,984 alignment-tail bytes match stock exactly. The complete wrapper
  differs at only the eight unresolved payload positions; no stock executable
  bytes are used as build inputs. Two independent source builds produce identical
  `optee.bin` and `tee.bin`. Their debug ELFs differ; every allocated section's
  content and attributes (excluding file offset) match between builds.
  The stock caller's SRAM copy and entry sequence is identified, but its service
  bindings/resume integration are unfinished. Whole carrier equality remains
  false. No physical suspend/resume test ran.
  [Wrapper proof](stock-optee-standby-wrapper-proof.json) records hashes,
  section-level repeat checks and the unnormalized stock comparison.
  [Source history](../../vendor/optee/standby-src/README.md) retains the
  instruction/data/relocation proofs and limitations.
- **Vendor services:** the 172-byte hash-list installer is now reconstructed as
  readable Thumb source with genuine symbolic relocations. All bytes outside its
  eleven real relocation fields match the original, and its unwind descriptor
  also matches. ARM QEMU verifies copying, count/log updates, allocation failure
  and zero entries. The 400-byte SMC routine is also reconstructed, including
  its real MMIO constants, twelve symbolic relocation fields and exact unwind
  descriptor. QEMU verifies region selection, split/rounded mappings, 64-bit
  offsets and exhaustion against a simulated register bank.
  The 336-byte hardware-identification routine is now source-built with its
  original XOR data, return paths and `CANTUNWIND` policy. Fifteen QEMU cases
  preserve original acceptance/rejection, diagnostics and edge behavior.
  Remaining service integration still requires complete instruction/data
  verification, especially SRAM standby and its callers.
  The suspend caller's five host cache/MMU helpers now have retained Thumb
  source: 198 bytes, with all 190 non-external-call bytes matching directly
  under an independent test link. Two external `dcache_op_all` call fields
  are genuine relocations. Its 20-byte upstream entry body matches stock.
  Six QEMU cases execute the real delay; privileged paths remain unexecuted.
  The caller invokes D-cache disable before SRAM, then MMU enable followed by
  MMU disable on return; this observed order is retained for further caller
  reconstruction, not silently rearranged. [Host helper proof](stock-optee-host-mmu-proof.json)
  records addresses, source hash, relocation checks and execution limits.
  The 532-byte suspend caller now also has retained source, with all 380 bytes
  outside its 38 genuine call/data relocations matching. Ten QEMU cases verify
  parameter/header/wrapper copies, twelve diagnostics and entry/return order
  using explicit test substitutes for the SRAM program and privileged services.
  This does not exercise actual DRAM or CP15 behavior. Resume/configuration
  recovery and production wiring are still open.
  [Caller evidence](stock-optee-host-suspend-proof.json) records the boundary.
  The 52-byte standby-type reader is now source-built too: 36 bytes match
  outside four genuine relocations. All 1,024 tested flag combinations confirm
  only request bit 3 selects audio standby, with its original diagnostic and
  no request mutation. The ten caller cases now use this actual reader.
  [Type-reader proof](stock-optee-host-type-proof.json) also identifies the
  resume pointer as an ARM branch to the separate routine at `0x41b0c52c`;
  the request producer remains unfinished. The ARM resume vector and 156-byte
  reset-style routine now have retained source: all 100 bytes outside fourteen
  genuine body relocations match stock. Independent linking checks every ARM,
  Thumb and conditional-park target. All three setup bodies are now identified/reconstructed;
  no empty implementations are supplied. Four upstream helper bodies (92 bytes)
  match stock directly and can be reused. Restoring stock `TTBCR_N_VALUE=5`
  (upstream uses 7) reduces `core_init_mmu_regs` raw differences from 31 to 11.
  Outside its six genuine relocation fields only the panic-line immediate
  differs: stock 253 versus upstream 249. No line-number override is applied.
  This restores the 128 MiB TTBR0 split and 512-byte per-thread user L1 tables.
  [MMU split proof](stock-optee-mmu-split-proof.json) records two matching
  deployable builds and the whole-carrier comparison, which still fails.
  [Resume evidence](stock-optee-host-resume-proof.json) records each binding
  comparison. This path has not executed; full service integration remains open.
  Two vendor calls are now identified as `plat_cpu_reset_late` and `console_init`.
  The late-reset hook has 232 retained source bytes; all 196 bytes outside nine
  real relocations match, including a matching compact unwind descriptor.
  It is integrated as a strong platform hook, replacing the upstream weak
  default; the primary reset path calls the real implementation. Existing
  console C source is reused, with 128 host test cases for UART selection,
  diagnostic arguments and registration. Its instruction shape is not yet
  identical. Primary resume source is now recovered; full suspend dispatch remains open.
  [Late reset and console evidence](stock-optee-late-reset-proof.json) records
  two clean deployable repeats and the exact execution/identity limits.
  The final call is `generic_boot_resume_primary`, established by its own
  diagnostic (the earlier secondary-init description was incorrect). Its
  84-byte unit matches all 44 bytes outside ten genuine relocations; unwind
  policy also matches. Sixteen QEMU cases exercise its instructions with an
  explicit NSACR model and thread/monitor/GIC recorders, preserving other bits,
  call order, diagnostic arguments and return. Two return-only hook bodies
  match their original two-byte instructions; original hook names are unknown.
  [Primary-resume evidence](stock-optee-resume-primary-proof.json) also records
  operation `0xb2000214`, whose dispatcher case supplies the saved resume entry.
  That producer and dispatcher are not yet reconstructed or wired into the
  carrier. No privileged hardware resume execution is claimed.
  Enabling the observed secondary-boot/PSCI input combination recovers four
  original functions directly from unmodified upstream source: core release,
  core entry lookup, standard SMC dispatch and PSCI dispatch. Their 330 bytes
  match outside 23 real relocation fields (238 other bytes). No spin-table
  source write was manually removed; the compiler eliminates it naturally
  when PSCI removes its last reader. Two clean builds repeat deployable bytes.
  [Secondary boot proof](stock-optee-secondary-boot-proof.json) records each
  relocation and all thirteen PSCI target bindings. Six platform overrides
  remain different from upstream defaults: CPU suspend/off/on, affinity,
  system reset and system suspend. They are not complete
  platform implementations yet; no physical secondary/power action ran.
  PSCI version and feature reporting now have C platform overrides. All 42
  instruction bytes match stock directly, without normalization or relocation
  exclusions, as do their unwind descriptors. The original response is PSCI
  1.0 and only four advertised IDs (VERSION, SYSTEM_RESET, FEATURES and
  SYSTEM_SUSPEND). QEMU checks 262,148 function IDs and the version response.
  [Identification proof](stock-optee-psci-identification-proof.json) records
  exact function hashes and two clean deployable repeats. The advertised
  power operations are still among the unresolved implementations.
  Exact complete linked instruction/data comparison remains necessary.
  [Installer evidence](stock-optee-hash-installer-proof.json) and
  [SMC evidence](stock-optee-smc-proof.json) and
  [hardware-policy evidence](stock-optee-hardware-policy-proof.json) record the boundaries.
- **Complete core correspondence:** the pre-installer baseline mapped 913
  source/original functions covering 125,412 bytes, including normalized matches checked
  against 2,541 known-callee/string constraints with no contradictions. These
  partial mappings are not whole-program equality; the complete correspondence
  graph has not been regenerated after these service reconstructions. Unmatched MMU, TA/syscall,
  thread and vendor code still needs explanation.
- **Layout and integration:** all 16 recovered physical-map records match their
  names, types, addresses and lengths, but record order is not certified. The
  first 8,192 header bytes match except three genuine link-derived public-key
  offset words; those offsets follow the candidate's different symbol addresses.
  They must converge through correct code/data layout, not forced addresses.
- **Original provenance:** vendor revision `553fe17e2-dirty`, its dirty changes,
  build number 6 and February 18, 2022 build inputs have not been recovered.
  The recipe deliberately identifies itself as `3.7.0-reforge-reconstruction`.

The typed vendor header, 48-byte early reset routine, actual UART console,
log level 3 and physical mappings are now source-built. Twelve platform/helper
bodies, totalling 1,528 bytes, match outside genuine relocation fields. The other
eleven platform objects remain byte-identical after debug removal across the
hardware-policy change.
The candidate remains **research-only and not a verified deployable secure OS**.

A differential `-O2` core build approached the original size but lost 579
previous function matches / 67,018 matched bytes and gained none. It was rejected;
current `-Os` is retained. Current small-code crypto and memory permissions have
positive instruction/table evidence. Further blind option/size tuning is not a
substitute for missing-code recovery.

**To close:** compile the recovered standalone SRAM program, vendor services and
remaining authentic configuration/source changes; reproduce the carrier and
compare every byte with no permitted exceptions. See [the OP-TEE recipe](../../vendor/optee/stock-patches/README.md).

## G03 — DSP0 license, source cohort and complete partition

**Compile blocked and original source identity unresolved.** The active boot
command loads this firmware; exclusion from the current build does not remove
it from a complete original bring-up target.

- Original ELF: 261,240 bytes, SHA-256
  `61ed4f199ca3b15f96c245a709282e1a4798b14d0f23a5e2930577487ebd20d1`.
- Recorded source version: `sun8iw20_fpga_v0.5.0-37-gfb1fe0d`.
- Matching tools: Cadence RI-2020.4 / XCC 14.04, Xtensa `aw_axi_cfg0` core.
  A working compiler entitlement is unavailable. Docker host networking did not
  resolve it: the server-file checkout still fails `-96`; the alternative file
  fails `-5` for the requested feature. Neither probe produced an object.
- The later public `pdscomp/oc-freertos-dsp-xt` import at
  `38fa249bd9997f63b35aa4cdf95248b3bef5b685` is not established as the original
  source. Mapping found 30 exact paths, 56 basename matches and two missing
  filenames (`notifier.c`, `sunxi_dma_core.c`); filename correspondence is not
  source equivalence. Original configuration, compile cohort and runtime-library
  source-build closure remain unverified.
- The whole 1-MiB DSP partition has SHA-256
  `3ce7c4ff5b9953986c63193acde1ca8783fe6a0a1ef12df9f8983cbdc018efb1`.
  A 904-byte residual tail follows the ELF through the 256-KiB boundary, then
  zeroes. Its generation/history is not reproduced. An identical ELF alone
  would not certify that partition.

**To close:** obtain a valid entitlement for the actual core, recover the
original source/configuration and compile all target/runtime inputs; reproduce
both ELF and partition writer/tail behavior. No license bypass is part of this
work, and no license secrets are recorded here.

## G04 — different 2025 backup U-Boot and slot identity

The golden backup TOC at `0x1004000` contains U-Boot
`2018.05-g2a24076-dirty`, dated April 18, 2025. Its 966,656-byte member has
SHA-256 `b31940650d2072b403cd109b4def5e435abf1326f8fd1292d67c83d0898ecfe3`.
It differs from the reproduced 2023 primary in 779,577 byte positions; layout
changes prevent inferring how many instructions differ from that count.
Its exact source/dirty changes, build recipe and complete equality are unverified.
The saved running-unit boot argument names the 2025 build; no UART trace has
independently established selection of the primary or backup slot.

The independent stock dump's backup instead matches the 2023 primary. Thus the
golden capture is not an untouched single-version factory release.

The golden backup DTB is understood: it equals the source-proven kernel DTB
(PWM7) padded with zeroes to 59,392 bytes, SHA-256
`9cc6dbe97217514628c34741d905224e75e28c0958745cc552cbe438fc7f1e04`.
It differs from primary TOC DTB PWM6 at only offset `0x8a67`. This is a known
configuration variant, not an unidentified driver gap.

**To close:** reconstruct the 2025 build separately if reproducing this golden
snapshot or the observed running version; establish actual slot selection.
Do not report the exact 2023 primary as proof of the 2025 binary.

## G05 — complete primary/backup TOC packaging

**Container format is now reproduced; complete source payload closure remains open.**
The source [TOC1 packer](../../tools/build/pack-stock-toc1.py) regenerates all headers,
records, names, zero padding and the additive checksum without reading a reference
container or copying any header bytes. Its structures agree with the BSP's
`include/private_toc.h`; layout and padding are verified against both captures.

- Primary: 1,343,488 bytes, SHA-256
  `9345c28b17c90b994e7688bf611ca275b5be230ce6e9a0e9e74b8c7983f1bc07`.
- Golden backup: same length, SHA-256
  `8f6d733683e8e3bba479584983002be88fca56de01b08b4ddc8f0d84a9664849`.

Repacking extracted members reproduced **every byte in both containers**, with
checksums `0x61492f60` and `0x22a79b32`. A second primary comparison uses our
source-built U-Boot and source-built padded TOC DTB; it also matches every byte,
but still uses reference OP-TEE **only to validate the packer**. This is not a
source-built secure OS or complete source-only boot-package result.
[Retained comparison evidence](stock-toc-format-proof.json) identifies those boundaries.

The generated layout has a 64-byte header, three 368-byte item records, 2-KiB
member alignment and 16-KiB container alignment. Primary members begin at offsets
2,048, 968,704 and 1,269,760. Offsets and lengths are computed from the supplied
payloads, not restored from the capture; a different-size candidate naturally
produces different records/layout.

**To close:** resolve G02 and G04 where applicable, then feed those verified
source outputs into the packer and prove complete primary/backup TOC equality.
See [the recipe](../../tools/build/README-stock-toc1.md). No reference executable
payload is vendored or automatically selected by the packer.

## G06 — boot-resource FAT filesystem and inactive Android carrier

The configured path uses FAT p1 `uImage` and `sunxi.dtb`, both individually
reproduced. Complete p1 filesystem equality is not established.
Its 25-file inventory also includes 17 BMPs, two fonts, two waveform data files,
VCOM text and a 512-byte UUID/magic file. Exact asset provenance/conversion and
reproducible filesystem construction remain unverified. These data assets are
not evidence of missing Linux drivers or additional native executables.

File equality alone does not reproduce FAT geometry, volume identifiers,
allocation order, directory entries/timestamps, free-space contents, FSInfo and
backup boot records. Their original generator/parameters must be recovered or
reimplemented and compared at partition level.

The p4 Android `boot.img` is not selected by the validated saved environment.
Its complete carrier/partition has not been source-repacked byte-identically.
It requires a separate payload/header/ramdisk/unused-byte inventory and a proved
packing recipe if the target includes every stored boot path.

## G07 — GPT, reserved areas and whole captured disk

Known boot/member offsets and partition LBAs are inventoried, but no complete
source-generated disk image matches the golden capture. Remaining coverage
includes primary/backup GPT metadata and CRCs, GUIDs/attributes, exact geometry,
boot-copy placement, reserved/unallocated regions, partition padding and trailing
sectors. Historical writes can leave residual bytes that a fresh image does not
naturally generate.

The original rootfs and UDISK filesystem images, including allocation,
timestamps, UUIDs, journals, logs and machine/user state, have not been recreated
from source. The golden capture also contains later modifications. Producing a
fresh bootable image is a different test from reproducing that entire snapshot.

**To close:** fix a precise snapshot/slot target; reconstruct the original writer,
filesystem tools/options, immutable assets and relevant state/history; compare
each partition and the full raw disk. A compressed golden-image hash alone does
not prove regenerated raw sectors or gzip-stream equality.

## G08 — accepted kernel ELF/debug provenance residual

Natural raw Image differs in exactly 20 build-ID bytes at `0xacc154..0xacc167`;
all other raw bytes match. Its size delta is zero. The user-authorized patch
closes the delivery Image/zImage/uImage comparison, and the script verifies the
whole resulting Image hash before writing a new output.

This does **not** recover the original unstripped/pre-sort ELF. Original debug
sections, complete symbol/string tables, some compiler/assembler path/input
provenance and original ELF ordering are unavailable. The GNU build-ID algorithm
is understood and independently modelled; the unavailable original hash inputs
remain the gap. Further input-matrix/header tests have not produced the natural
stock ID.

**To close natural ELF identity:** obtain the original full ELF or recover all
original source/compiler/assembler/debug inputs and naturally reproduce it.
This residual is accepted for delivered kernel bring-up, not silently waived for
other components. See the detailed [kernel evidence record](stock-bringup-rebuild.md).

## G09 — historical toolchain/runtime source closure

Historical Linaro compiler binaries are pinned external build tools; their own
clean source bootstraps and cross-host repeatability have not been demonstrated.

**Boot0's concrete target-runtime dependency was closed on 2026-10-28.** The
three routines previously linked from distributed `libgcc.a` (`_udivsi3`,
`_divsi3`, `_dvmd_lnx`) now compile from retained, unmodified GNU ARM source.
All 1,332 text bytes match, and relinking preserves every byte of the previous
34,592-byte raw / 49,152-byte packed source candidate. The recipe links only the
new three-object archive, not compiler-provided target code. The private opaque
DRAM archive also remains excluded.
After restoring and hash-checking GCC 4.6.3, a complete clean source-archive
recipe run also reproduces the same candidate. Its link uses only the newly
compiled runtime archive; the unchanged eleven G01 provenance bytes still fail
the strict stock comparison.
See [source provenance](../../vendor/runtime/gcc-7.2.0-arm/README.md) and
[comparison evidence](stock-boot0-runtime-proof.json).

**Additional selected-runtime checks on 2026-10-28:** primary U-Boot's link map
selects only three members of its source-built `arch/arm/lib/lib.a`, with no
compiler-distributed archive members. A fresh OP-TEE core selects 193 members
from its own newly built archives; the compiler's `libgcc.a` is listed as an
input but contributes no selected member. OP-TEE implements its AEABI helpers
in source. [Audit evidence](stock-runtime-link-audit.json) records map hashes and
scope. Two clean OP-TEE builds inside/outside Reforge also reproduce the previous
candidate after bounding Git discovery; unrelated Reforge revisions can no
longer contaminate the exported-source OS revision response.

**Remaining audit:** inspect remaining historical-toolchain stages and packaged
firmware for target runtime inputs and rebuild any such dependencies from source. A compiler
executable bootstrap is a separate claim from application/runtime source closure;
neither the boot0 result nor the newer Klipper13 compiler/newlib source builds
certifies all historical tools. G01's source-label/checksum mismatch is unchanged.

## G10 — factory MCU applications and retained IAP

The optional v13 source/repeatability result does not reproduce factory firmware:

| Factory artifact | Size | SHA-256 |
|---|---:|---|
| Mainboard-20230831.bin | 38,812 | `8b5d42a78de773c105bc037a49bf0fb5e4d30dcd378d1709b4e3ace7fac8dd3a` |
| Eboard-20231012.hex (OTA reference) | 94,590 | `c8621a4279770d1c13e0e32c17d608979536bc4eb3f4516443d15c13dd65bcac` |
| Decoded Eboard application | 33,608 | `fd56bf0baa636e254a5db4124b95f5416e9b6dbae54472a4d0a17b0d6979b3a8` |

Both identify strings give `?-20230317_182329-ubuntu20-virtual-machine`, with no
recoverable Git commit, GCC 9.2.1 and binutils 2.34. Their 144-MHz clock and
`0x20020000` initial stack pointer are N32-like despite the `stm32f103xe` label;
the public unmodified v0.11 STM32 selections do not explain these inputs.
The Eboard application starts at `0x08010000`; the retained first 64-KiB IAP is
absent from that application HEX and its source/build identity is unresolved.
The userspace `eboard_run` launcher is not that bootloader. A separate stock
`mcu.img` asset is a pixel image, not MCU executable firmware.

**To close:** recover the original N32-aware source/configuration/toolchain inputs
and reproduce both factory applications; separately identify/capture and source
rebuild the retained IAP. Do not infer source identity from matching public
Klipper host sources or substitute the intentionally different v13 firmware.

## G11 — remaining deployed components and updated userspace scope

The source audit has not certified every external module, firmware variant,
vendor userspace executable or data asset stored in the original rootfs.
The flat RTL8821CU result must not be generalized to its differently packaged
`/lib/modules/5.4.61` variant or unrelated components without comparison.
Built-in code in the verified stock raw kernel is already covered by that
whole-Image equality; no separate MCU UART Linux driver gap was found.

Updated ReForge services and v13 firmware deliberately target new versions.
Their successful builds and QEMU tests establish neither equality with original
FlashForge/modified userspace nor complete two-build rootfs reproducibility.
Stock proprietary userspace/state would require its own source/provenance audit
if included in a whole-machine stock-equality target.

## G12 — physical validation and end-to-end acceptance

No bootloader/environment write, flash operation, physical printer boot or new
MCU flashing was performed. QEMU validates userspace integration, not the T113
boot ROM, actual slot selection, SRAM suspend/resume, PMIC/DRAM timing, interrupt
routing, real module loading, MCU UART communication or calibration.
Matching zram vermagic/exports is useful static evidence, not a physical ABI test.

**Acceptance still required:** source-closed component builds, strict per-file
hashes, exact containers/partitions for the agreed target and a separately
recorded hardware bring-up/recovery test. Hardware success cannot waive a known
byte mismatch, and byte equality does not itself record an observed hardware test.

## Evidence and maintenance

Committed source/build entry points:

- [Boot0 source recipe](../../tools/build/build-stock-boot0.sh) and [packing source](../../tools/build/pack-stock-boot0.py).
- [OP-TEE recipe](../../tools/build/build-stock-optee.sh) and [source patches](../../vendor/optee/stock-patches/README.md).
- [Stock U-Boot recipe](../../tools/build/build-stock-uboot.sh).
- [Stock kernel recipe](../../tools/build/build-bsp-kernel-stock.sh), [build-ID patcher](../../tools/build/patch-stock-kernel-build-id.py), and [board-data recipe](../../tools/build/build-stock-board-data.py).

Local retained proof records (research state; not portable build inputs):

- `/tmp/reforge-boot0-source/closure-proof.json` and `build/stock-boot0-source-closure-check/manifest.json`.
- `/tmp/reforge-stock-optee/header-reconstruction/final-clean-proof.json` and `/tmp/reforge-optee-core-config/report.json`.
- `/tmp/reforge-stock-dsp/reproduction-status.json` and `docker-host-network-probe-results.json` in that directory.
- `/tmp/reforge-factory-mcu-audit/report.json`.
- `/tmp/reforge-rootfs-clean-proof/build-report.json`, `integration.log`, `full-stack-smoke.log` and `device-dtb-report.json`.

A gap closes only when its stated evidence is produced. Update this ledger when
new clean builds change hashes or comparisons; do not turn exploratory `/tmp`
results into a claimed verified recipe before sealing and rerunning that recipe.
