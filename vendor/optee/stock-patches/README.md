# OP-TEE reconstruction research

This profile builds from source but **does not reproduce the original secure OS**. It is separate from the production firmware build. Its standby BSS layout, secure-service integration and several reconstructed function shapes remain incomplete; it is not ready for deployment.

Run `tools/build/build-stock-optee.sh SOURCE_TAR NEW_OUTPUT_DIR [ORIGINAL_OPTEE_REFERENCE]`. The optional original executable is hash-checked before building and used only for comparison; none of its bytes enter compilation. Comparison requires full byte identity, allows no exceptions, and currently exits 1 while retaining the built artifacts and report.

The source archive is [official OP-TEE 3.7.0](https://github.com/OP-TEE/optee_os/commit/a2fa5018cb595a9cd9ab62e82c7485ca57a62084), SHA-256 `1662d74cd682ebfe1d52b3ced8a61c2d490a12a011b9c4255a73bd6b460e1b58`. The build uses the pinned Linaro 5.3.1 toolchain, the source commit's timestamp and an explicit `3.7.0-reforge-reconstruction` version label. It does not claim the original vendor's `553fe17e2-dirty` source identity.

The first two patches are published upstream implementations, unchanged:

- [SM4](https://github.com/OP-TEE/optee_os/commit/ade6f848e084d7c63f1e3866d7c059b8a9f9e834).
- [SM3](https://github.com/OP-TEE/optee_os/commit/47645577).

The third patch introduces the reconstructed T113 platform and boot hook; patches 0005–0007 replace three draft service units with verified source assembly. The current profile has twelve platform/helper bodies matching every original byte outside genuine object relocation fields (1,528 bytes in total); the CPU-interface initializer and early CPU-reset routine also match all their bytes without relocations. Complete service integration and unmatched core functions remain unverified. No original opcodes, target objects, post-link metadata replacements or empty vendor-service implementations are used. Explicit diagnostic arguments preserve observed runtime error reports, rather than manufacturing source-line padding.

The fourth patch reconstructs the Allwinner image header as typed C data plus an ARM branch, with link-derived offsets to the genuine generated TA public key. The 4092-byte header and normal 8-KiB reset alignment reproduce all first-8192 bytes except the three public-key offset words, whose values correctly track this reconstruction's different symbol addresses. No header or executable bytes are imported from the original image.

Caller recovery corrected an earlier mistaken name: the 24-byte panic body is `itr_core_handler`, not `console_init`. The actual console initializer scans the CCU UART-enable bits and registers a real 8250 console. The original's complete 16 physical-MMIO records now compile from source with identical expanded names, security types, physical addresses and lengths, including non-secure SRAM/UART mappings. Record order is not claimed identical. `CFG_TEE_CORE_LOG_LEVEL=3` restores common DEBUG/version diagnostics present in the original.

The memory profile uses the observed `0x41b00000` secure OS, `0x41c00000` TA region and two MiB of shared memory at `0x41900000`. Original image strings establish enabled statistics and stack-canary support. Remaining configuration choices and reconstructed service behavior need continued binary verification.

The vendor comparison candidate is `artifacts/optee.bin`, the raw source-linked `tee-pager.bin` carrying this header. `artifacts/tee.bin` is retained as the separate standard OP-TEE loader container; it is not the original board's carrier format.

Validation on 2026-10-26: a fresh invocation of this recipe produced a 258,536-byte `optee.bin`, SHA-256 `ed4b751ceda60a2247debbbed463695ffc84b3d9ffaa8035e32472345c9f2915`. Generated configuration and the actual compiler command both select log level 3, and the observed common DEBUG/version messages are present. Full comparison correctly exits 1: the original is 300,248 bytes, the first differing position is offset 252 (a naturally linked public-key offset), and 244,839 positions differ within the shared extent. Nine function bodies (620 bytes) match outside actual relocations; the full runtime instruction stream does not yet match.

The original also contains executable ARM standby/DRAM code and parameters between offsets `0x4000` and `0x6100`, referenced by its vendor standby service. Those initialized bytes now build from retained source and are embedded by patch 0008; the BSS layout and service integration remain unresolved. That region is not filled with copied target code. No hardware execution was performed.


## Source export reproducibility and target-runtime audit (2026-10-28)

Git discovery is now bounded at the new output directory. An extracted upstream
archive has no Git metadata; its OS revision response must not inherit the parent
Reforge repository's unrelated SHA. No `TEE_IMPL_GIT_SHA1` override is supplied:
the upstream generator naturally falls back to zero. The explicit honest
reconstruction version remains unchanged.

A control build inside Reforge had compiled `0x3f2be1b1` from the parent repository
and produced SHA-256 `fc98f9a5f4e8e022f38a593bda014d152b6039f68c9d1e7ec58bb1697b01512c`.
Two fresh bounded builds, one inside Reforge and one outside it, now reproduce
all 258,536 raw carrier bytes with the previously verified SHA-256
`ed4b751ceda60a2247debbbed463695ffc84b3d9ffaa8035e32472345c9f2915`.
Both generated compiler commands contain the natural `0x0` archive fallback,
and both correctly exit 1 on the unresolved stock comparison.

The core link map includes a `LOAD` line for the compiler's `libgcc.a` but extracts
**no members** from that archive. All 193 selected archive members are from this
fresh build's own source-built archives. OP-TEE supplies its integer division,
64-bit division and shift helpers under `lib/libutils/isoc/arch/arm`; this result
is narrower than a historical compiler bootstrap or whole-firmware source audit.
[Retained evidence](../../../docs/board-notes/stock-runtime-link-audit.json) includes
raw carrier hashes, build locations, link-map hashes and comparison boundaries.

## Hash-list installer recovery (2026-10-28)

Patch 0005 replaces the draft C body with readable Thumb assembly implementing
the observed allocation, record-copy and count/logging algorithm. It uses real
calls to `malloc`, `trace_printf` and `memcpy`, references the source-defined
header and globals symbolically, and carries ordinary generated EHABI unwind
information. Plaintext diagnostics are source-owned strings. No original opcode
array, fixed target pointer or post-link replacement is used. This recovers the
program, not the unavailable original C spelling.

Original function `0x41b14f20` has 172 bytes. All 128 bytes outside its eleven
four-byte ELF relocation fields match exactly. The generated unwind descriptor
`0x8004afb0` also matches the original entry at file offset `0x46c28`, which lies
between neighboring unwind entries. ARM QEMU checks copied names and
digests, cumulative count, trace arguments, allocation failure and zero entries.
Ten other platform objects remain identical after removal of debug information.
After this step the verified platform/helper total was ten bodies / 792 bytes outside genuine
relocations; whole-program correspondence is still incomplete.

A fresh recipe invocation at `build/stock-optee-vendor-recovery/source-build`
produces 258,536 bytes, SHA-256
`ed608f12a28dcf68edf33f6901a40d1d7c609cb283e4fee5bf44ed406e760bd0`.
A second clean build outside Reforge reproduces every raw carrier byte.
Strict comparison correctly exits 1: size delta −41,712 bytes, 244,777 differing
positions in the common extent, first difference at 252. This remains a research
candidate with unresolved standby and other vendor services, not a deployable
secure OS. [Evidence](../../../docs/board-notes/stock-optee-hash-installer-proof.json)
records the exact function comparison, relocation scope and fresh-build report.

```sh
python3 tests/release/test_stock_optee_hash_installer.py
```

The test uses the local pinned Linaro 5.3.1 compiler and `qemu-arm`; it explicitly
skips if either is absent. No hardware was used.

## Secure-memory-controller recovery (2026-10-28)

Patch 0006 replaces the draft SMC C unit with readable Thumb source. The function
still accepts a 64-bit start/size pair and implements the original algorithm:
partition into at most sixteen aligned blocks (4 GiB maximum, 32 KiB minimum),
find the first free SMC region, then write its high address, low address and
secure attributes. It preserves original warnings and return behavior, including
partial coverage on region exhaustion. MMIO numbers are hardware register
constants; calls and diagnostic pointers are symbolic ELF relocations.

Original `sunxi_smc_config` at `0x41b13adc` is 400 bytes. All 352 bytes outside its
twelve four-byte relocation fields match, including every hardware constant.
The automatically generated EHABI word `0x80063faf` matches the original table
entry at file offset `0x46b60`: restore 284 local-stack bytes and registers
r4-r11/lr. No executable opcode array, fixed code pointer, stock metadata or
post-link substitution is used. Original C spelling remains unknown.

A freestanding ARM QEMU test uses a simulated 16-region bank. It checks zero-size
no-op behavior; the stock 4-MiB mapping and translation-call order; preserving an
occupied first region while splitting a 32/64-KiB request; 64-bit address high
words; minimum-size rounding with the exact warning payload; all registers busy
without writes; generated-map exhaustion with the exact remaining-byte count;
and untouched reserved register words. This is simulated MMIO, not a hardware
validation or isolation certification.

The fresh carrier is still 258,536 bytes, SHA-256
`becab365f99411fee5de13460aa2fe2c4d7aa39f527b0920d9d1458d0fb4dc2e`.
A second fresh build outside Reforge reproduces every raw carrier byte.
Stock comparison correctly exits 1: delta −41,712 bytes, 244,833 differing byte
positions in the shared extent, first difference at 252. The number of differing
whole-file positions is not a measure of how many routines are recovered, because
layout and relocated addresses also differ. All eleven other platform objects
remain identical after debug removal; eleven bodies / 1,192 bytes now match
outside real relocation fields. SRAM standby and complete service/layout/original-input reconstruction remain
unfinished. Hardware policy is covered by patch 0007 below.
[SMC proof](../../../docs/board-notes/stock-optee-smc-proof.json) records the exact
comparison boundary and fresh build report.

```sh
python3 tests/release/test_stock_optee_smc.py
```

Validation: `make unit` passes, including the new QEMU register-policy test;
`bash -n` and ShellCheck pass for the build recipe. No hardware was used.

## Hardware-identification policy recovery (2026-10-28)

Patch 0007 replaces the draft hardware-policy C unit with readable Thumb source,
preserving the original checks and return values. The source copies the observed
16-byte XOR data, reads the hardware identifier, checks metadata magic/count and
flags, then searches decoded single-byte or paired identifiers. This is a
reconstruction of the observed policy, not a change to device acceptance.

The original `check_hardware_info` at `0x41b2bcd4` is 336 bytes. All 276 bytes
outside fifteen real relocation fields match. The 16-byte data array also
matches. Original unwind entry `0x479c0` covers addresses
`0x41b2bc9c..0x41b2be24` with `CANTUNWIND`; the source uses `.cantunwind` and the
linked function retains that policy. No synthetic stack-unwind descriptor is
introduced. Calls, header and diagnostic pointers are symbolic relocations;
there are no copied executable bytes or post-link replacements.

Fifteen freestanding ARM QEMU cases cover the zero-low-halfword shortcut, invalid
magic/count/flags, single-byte and paired matches, mismatches, zero entries,
and original odd-count zero-padding behavior. They verify return codes, exact
trace lines/severity/decoded-byte payload, one key copy and hardware-ID read,
and that header data stays unchanged. The test does not replace the production
hardware-ID reader; only the isolated QEMU fixture supplies simulated identifiers.

A fresh build produces 258,536 bytes with SHA-256
`e53b9b393bf567607263ebf4bec6db9626f33f1d5af0301a18491adccb9af53b`.
A second clean build outside Reforge reproduces every raw carrier byte.
The full stock comparison still exits 1: size delta −41,712 bytes, first difference
252, and 244,787 differing positions in the shared extent. All eleven other
platform objects remain unchanged after debug removal. Twelve platform/helper
bodies / 1,528 bytes now match outside actual relocation fields, while complete
layout, standby, other integration and original inputs remain unresolved.
[Evidence](../../../docs/board-notes/stock-optee-hardware-policy-proof.json) records
function, unwind, data, execution-test and whole-build comparison boundaries.

```sh
python3 tests/release/test_stock_optee_hardware_policy.py
```

The original C spelling is unknown. QEMU exercises controlled header/identifier
inputs; no printer hardware or physical fuse access was used.

Validation: the full `make unit` suite passes with the pinned boot0 compiler
explicitly supplied; no skips are reported. Build-script syntax and ShellCheck
also pass. No hardware was used.


## Standalone SRAM helper source (2026-10-28)

Separate [standby source](../standby-src/README.md) now recovers three C memory
helpers (116 bytes) plus a 420-byte source-built ARM runtime block, totaling
536 initialized bytes with complete equality and no relocation masks.
Their QEMU tests exercise original master-access masks and checksum edge cases.
This partial module is not yet integrated into the carrier; the current carrier
hash/size above remain unchanged. The rest of the 8,400-byte image and main
standby integration are still open. The source note also records the entry clear
loop's inclusive `0x2229c` boundary, separate from unresolved allocation symbols.


## Standalone counted delays (2026-10-28)

Separate [SRAM delay source](../standby-src/README.md#counted-delay-recovery-2026-10-28)
adds four routines spanning 116 bytes. The 52-byte loop bodies match completely;
the 64-byte wrappers match outside twelve genuine branch-relocation bytes,
whose original targets all identify the recovered countdown helper. QEMU checks
real register behavior and requested scaled/chunked counts. The complete SRAM
link and physical timing remain open; no partial payload is inserted into the
current OP-TEE carrier. The full unit suite passes with the pinned boot0 compiler
supplied. [Proof](../../../docs/board-notes/stock-optee-standby-delay-proof.json)
records the comparison boundary.

## Connected standalone TWI engine (2026-10-28)

The [standby reconstruction](../standby-src/README.md#connected-twi-engine-2026-10-28)
now includes the full connected 932-byte TWI code block, its five-controller table
and source-defined state. All internal branches match after linking; comparison
masks only the address immediates of twelve actual MOVW/MOVT relocations, keeping
opcodes and register bits checked. Reactive guest-MMIO tests run every stop and
transfer timeout at its full limit, error paths, and real PMIC callers. Two copied
source builds reproduce the linked ELF. [Proof](../../../docs/board-notes/stock-optee-standby-twi-proof.json)
records the exact fields and original targets. The full unit suite passes without
skips. Remaining SRAM code/layout and carrier integration are still open; the
carrier artifact, size and strict-comparison failure above remain unchanged.

## Connected standalone regulator/stack block (2026-10-28)

The [connected recovery](../standby-src/README.md#connected-regulator-and-stack-recovery-2026-10-28)
adds four regulator routines and both stack helpers. Selector, PMIC, regulators,
TWI, stack, loops and division now link into a continuous 2,696-byte source block.
All branches match, including previously masked PMIC calls. Only twelve actual
TWI address-immediate fields still require full SRAM layout. ARM tests cover all
entry/code pairs, rounding/boundary/error behavior, original invalid-selection
faults and stack switch/restore in guest memory. [Proof](../../../docs/board-notes/stock-optee-standby-regulator-proof.json)
records full new-function hashes and repeat builds. Main carrier artifacts and
strict comparison remain unchanged; full standby and integration are unfinished.

## Extended standalone setup and WFI block (2026-10-28)

The [setup/WFI recovery](../standby-src/README.md#pmic-setup-grouped-control-and-secure-wfi-2026-10-28)
adds three C setup wrappers, grouped control in ARM source, and the 96-byte secure
WFI primitive. A continuous 3,076-byte linked block now compares with no branch
exclusions; eighteen genuine address-immediate fields await full SRAM layout.
ARM tests cover 1,048,576 grouped transactions and preparation/init/error paths.
The secure-WFI body matches all bytes but has no privileged execution validation.
[Proof](../../../docs/board-notes/stock-optee-standby-pmic-setup-proof.json) records
source-copy repeats and the exact comparison/execution boundary. The main carrier
and its strict comparison remain unchanged; header/earlier code/layout/integration
are still unfinished.

## Clock sequence and initialized suffix (2026-10-28)

The [clock recovery](../standby-src/README.md#clock-sequence-and-complete-initialized-suffix-2026-10-28)
adds three routines and typed clock data. Source now links a continuous 4,556-byte
code/data suffix with every branch checked, including delays, and every initialized
symbol at the original relative offset. Only 26 true address-immediate fields and
four table-pointer words await full link. ARM tests verify ordered virtual MMIO,
save-once records and real delay execution. [Proof](../../../docs/board-notes/stock-optee-standby-clock-proof.json)
records the field-level comparison and unresolved 444-byte BSS/layout constraint.
This adds no arbitrary BSS padding. Earlier code/header, full BSS and carrier
integration remain open; the main carrier and strict comparison are unchanged.
No physical timing, clock stability or DRAM-retention test has run.

## Complete initialized SRAM source image (2026-10-28)

The [complete SRAM source build](../standby-src/README.md#complete-initialized-image-and-dram-reconstruction-2026-10-28)
now emits all 8,400 initialized bytes. Size delta is zero; exactly eight byte
positions still differ, all address immediates caused by the unresolved 16-byte
BSS/layout gap. Every other byte matches without normalization. The strict
[source builder/comparer](../../../tools/build/build-stock-optee-standby.sh) exits 1
against stock and has no accepted-difference rule. Source-copy object/ELF/bin
repeats and DRAM snapshot/restore/helper tests pass. [Proof](../../../docs/board-notes/stock-optee-standby-full-proof.json)
records exact differences and remaining inputs. No placeholder allocation or
recorded-address override fixes BSS. The main carrier remains unchanged and its
standby wrapper/service integration is still open; no privileged/full-resume or
physical suspend/resume execution has been validated.

## Source-built carrier wrapper integration (2026-10-30)

Patch `0008-source-standby-wrapper.patch` embeds the freshly source-built SRAM
image, retaining its own SRAM link addresses. Assembler alignment emits the
observed 48-byte ARM NOP tail and 7,936 zero bytes. All alignment bytes match
stock; eight payload byte positions remain different because the original BSS
layout is unresolved. No reference executable is an input to compilation.

Two independent builds produce identical `optee.bin` and `tee.bin`; debug ELFs
are not identical, although every allocated section matches between the builds.
The carrier is 283,112 bytes (stock 300,248), with 241,732 differing positions in
the shared extent. The strict comparison still fails. The original suspend
caller's copy/entry sequence is identified, but service/resume integration and
physical suspend/resume validation remain incomplete.

[Wrapper proof](../../../docs/board-notes/stock-optee-standby-wrapper-proof.json)
records the exact artifact hashes and section comparisons. Run
`python3 tests/release/test_stock_optee_standby_wrapper.py` to check the real
source payload, complete alignment tail, exported bounds and absent relocations.

## Stock MMU split restored

Patch `0009-source-mmu-table-split.patch` restores `TTBCR_N_VALUE=5`, directly
observed in the stock initializer. The upstream constant 7 selected a different
TTBR0 split and smaller user tables. N=5 selects 128 MiB and 128 L1 entries
(512 bytes per thread). This is a functional MMU input, not a metadata change.

The source initializer now has the stock instruction layout. Raw differences
fall from 31 to 11; outside six genuine relocation fields only the panic source
line differs (253 versus 249). No source-line override or comment padding was
introduced. Two independent full builds produce identical deployable binaries;
their debug ELFs differ. The carrier remains 283,112 bytes and is not stock-equal.
Its shared-extent differences increase by 40 positions as the corrected table
size changes other layout/data, despite fixing this MMU operation.

[MMU proof](../../../docs/board-notes/stock-optee-mmu-split-proof.json) records
artifact hashes, actual compiler relocations and strict stock comparison.
Original source/debug layout, service integration and privileged runtime
validation remain unfinished.

## Late-reset hook and console binding

The original primary reset and resume paths both call `plat_cpu_reset_late`
followed by `console_init`. The latter matches the console C source already
retained in patch 0004: it reads the UART clock bits, chooses the first enabled
port among six and initializes/registers an 8250 console. A host test exercises
all 64 port masks with two upper-bit patterns (128 cases) using test-only IO,
UART and trace providers. It preserves the original no-port diagnostic/path.
Its compiled instruction shape is still different and is not claimed identical.

`reset-late.S` now supplies the missing strong `plat_cpu_reset_late`: primary
counter/CCU initialization and secondary CNTFRQ restoration. All 196 bytes
outside nine relocations in its 232-byte text/literal unit match stock. Its
compact unwind descriptor also matches `0x80a8b0b0`. Patch 0010 and the build
recipe compile this source into the carrier, replacing the upstream weak
default; there is no empty vendor implementation. Two full source builds
repeat the deployable binaries; whole stock comparison still fails.

```sh
python3 tests/release/test_stock_optee_console.py
python3 tests/release/test_stock_optee_host_resume.py
```

[Proof](../../../docs/board-notes/stock-optee-late-reset-proof.json) records
source hashes, actual linked symbol, original caller evidence and byte checks.
The late-reset privileged/MMIO sequence has not executed. Resume secondary
initialization, full suspend dispatch, original source/layout and whole-image
identity remain unfinished. No hardware boot or suspend/resume was tested.

## Secondary-boot and PSCI source inputs

Patch 0011 enables `CFG_BOOT_SECONDARY_REQUEST=y` and `CFG_PSCI_ARM32=y`.
Together they reproduce four original functions from unchanged upstream C:
`generic_boot_core_release`, `generic_boot_core_hpen`, `smc_std_handler` and
`tee_psci_handler`. All 238 bytes outside 23 real relocation fields in their
330-byte total match stock. The release spin-table store disappears naturally
because the selected PSCI path no longer reads that private table; no source
statement, output byte or recorded address is overridden to obtain the match.

Both clean builds generate identical deployable binaries. The carrier is
287,208 bytes, versus stock 300,248, and still fails strict whole-file equality.
[Proof](../../../docs/board-notes/stock-optee-secondary-boot-proof.json) records
actual configuration, compiler relocation tables, byte comparisons and all
thirteen PSCI target bindings. Five upstream default bodies match; eight
platform overrides remain different: version, CPU suspend/off/on, affinity,
system reset, features and system suspend. Enabling the framework does not
complete those platform implementations. The vendor dispatcher and full
standby service integration also remain unfinished. No physical CPU release,
power, reset or suspend/resume action was executed.

## PSCI version and advertised feature responses

`psci-identification.c` supplies strong platform overrides for `psci_version`
and `psci_features`. The original reports PSCI 1.0 and advertises only VERSION,
SYSTEM_RESET, FEATURES and SYSTEM_SUSPEND. A C switch naturally compiles to
all 42 original instruction bytes with the pinned compiler and production
`-Os` flags. No relocation fields, metadata normalization, padding or post-link
substitution is needed. The unwind descriptors also match.

Patch 0012 and the builder compile these into the carrier. Two clean builds
repeat the deployable binaries. QEMU checks 262,148 IDs across normal, wrong-owner
and 64-bit namespaces plus boundary values, and verifies the version response.
These are query operations; no power or hardware action runs.

```sh
python3 tests/release/test_stock_optee_psci_identification.py
```

[Proof](../../../docs/board-notes/stock-optee-psci-identification-proof.json)
records exact function hashes, strong linked symbols and whole-carrier failure.
Six PSCI overrides remain unfinished: CPU suspend/off/on, affinity, system reset
and system suspend. Advertised support is preserved exactly and does not imply
those original implementations have been completed. Whole-image stock identity,
full dispatcher/configuration integration and physical resume remain open.
