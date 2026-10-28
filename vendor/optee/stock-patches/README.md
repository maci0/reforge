# OP-TEE reconstruction research

This profile builds from source but **does not reproduce the original secure OS**. It is separate from the production firmware build. Its standby code, secure-service integration and several reconstructed function shapes remain incomplete; it is not ready for deployment.

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

The original also contains executable ARM standby/DRAM code and parameters between offsets `0x4000` and `0x6100`, referenced by its vendor standby service. Those sources and service integration remain unresolved; that region is not filled with copied target code. No hardware execution was performed.


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
