# Secure-world standby caller helpers

`mmu.S` reconstructs the five contiguous Thumb helpers at original addresses
`0x41b2c966..0x41b2ca2b`. These belong to the main secure OS, separately from
`../standby-src/`, which is the ARM SRAM program.

The source retains the delay loop, cache operations, SCTLR/ACTLR accesses and
barriers in their observed order. Calls use actual symbols; the only external
is upstream `dcache_op_all`. Its 20-byte entry body matches our source-built
OP-TEE. All five helper bodies total 198 bytes. At independent test addresses,
190 bytes match stock directly; only the two genuine external call relocations
differ. The test also checks all six symbolic call/jump relocations and runs
the delay under QEMU for six input values.

```sh
python3 tests/release/test_stock_optee_host_mmu.py
```

The original suspend caller invokes D-cache disable before the ARM SRAM entry,
then the MMU-enable helper and MMU-disable helper in that order on return.
These names describe register effects; original source/debug names remain
unknown. No privileged cache/MMU operation or physical suspend/resume test has
run. These helpers are retained reconstruction units; they are not yet wired
into the source secure-OS service. Whole carrier identity remains unfinished.

[Evidence](../../../docs/board-notes/stock-optee-host-mmu-proof.json) records
reference/source hashes, comparison scope and remaining boundaries.

## Suspend caller

`suspend.S` retains the original caller's instructions, local branches, literal
references and diagnostic strings as source. Its 532-byte text/literal unit
matches all 380 bytes outside 38 genuine call/data relocation fields. This is
an object-level comparison, not whole linked-image equality.

Ten QEMU cases execute this caller with a test-only 16 KiB wrapper and service
recorders. They cover both standby types and zero through four paired PMU-byte
copies, compare all 240 parameter bytes, check the copied wrapper suffix, all
twelve diagnostic calls, and the exact cache/copy/entry/return order. The ARM
entry recorder replaces actual DRAM/CP15 behavior. The test ELF is linked away
from SRAM so its fixed-address test mapping cannot overwrite the harness.

```sh
python3 tests/release/test_stock_optee_host_suspend.py
```

[Caller evidence](../../../docs/board-notes/stock-optee-host-suspend-proof.json)
records every relocation and the runtime boundary. The resume entry, original
configuration objects and complete service binding remain
unfinished; this caller is not wired into the secure-OS build yet.

## Standby-type reader

`type.S` reconstructs the 52-byte reader at `0x41b11354`. All 36 bytes outside
one call and three data relocations match stock. Request flags at offset four
select type 2 when bit 3 is set, otherwise type 1. The audio branch preserves
its original diagnostic. QEMU checks all 256 low-byte combinations with four
upper-word patterns (1,024 cases), including unchanged request words. The ten
caller cases now link this reader directly rather than substituting it.

```sh
python3 tests/release/test_stock_optee_host_type.py
```

[Reader proof](../../../docs/board-notes/stock-optee-host-type-proof.json)
records the address/flag evidence and resume-entry discovery. The request
producer and full request layout remain unknown. The resume entry is an ARM
branch at `0x41b0c0fc` to a separate reset-style routine at `0x41b0c52c`, beginning
with the already reconstructed early CPU-reset hook. That body, runtime
configuration setup and service dispatch still need source closure.

## ARM resume entry and reset path

`resume.S` retains the branch at `0x41b0c0fc` and the 156-byte ARM routine at
`0x41b0c52c..0x41b0c5c7`, including its literal pool. All 100 bytes outside the
fourteen genuine body relocation fields match stock. An independent link test
checks ARM/Thumb call modes, the unsupported-CPU branch, vector branch and
absence of unresolved symbols using link-only trap fixtures. It executes no
privileged instructions.

```sh
python3 tests/release/test_stock_optee_host_resume.py
```

`__get_core_pos` and all three `cpu_mmu_enable*` bodies match the source-built
upstream OP-TEE byte-for-byte (92 bytes total). The MMU-register initializer
still differs in 31 positions; its original configuration and linked inputs
need verification. Three vendor setup calls retain descriptive names rather
than guessed original names. Their implementations, vector/stack symbol
visibility and full production integration remain unfinished. No empty vendor
implementations are included in the reconstruction.

[Resume proof](../../../docs/board-notes/stock-optee-host-resume-proof.json)
records every call/data relocation and the exact upstream comparison scope.
No SMC, reset, MMU/cache transition or physical resume test has run.

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

## Primary resume initialization

The remaining setup call is `generic_boot_resume_primary`, as established by
its own diagnostic string; the earlier secondary-init description was incorrect.
`resume-primary.S` retains its 84-byte text/literal unit. All 44 bytes outside
ten genuine relocations match stock, as does unwind descriptor `0x8001a8b0`.
The two called return-only hooks retain their observed `bx lr` bodies. Their
original symbol names are unknown; the source names describe call placement.
They are recovered bodies, not invented empty implementations.

Sixteen QEMU cases run the unmodified Thumb sequence with a SIGILL handler that
models exactly the NSACR read/write instructions. Other instructions, including
the VFP-access bit operation and actual return-only hooks, execute normally.
Thread/monitor/GIC functions are test recorders. The cases verify call order,
masking, saved entry, preservation of other NSACR bits, diagnostics and return.
No real privileged register is changed and no hardware resume is claimed.

```sh
python3 tests/release/test_stock_optee_resume_primary.py
```

[Proof](../../../docs/board-notes/stock-optee-resume-primary-proof.json)
also identifies the saved-entry producer in operation `0xb2000214`: it stores
argument word one, returns the secure resume vector in word zero and cleans/invalidates the
data cache. Its full dispatcher/source integration remains unfinished. The
primary-resume unit remains separate from the carrier until that path is wired.

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

## PSCI system-suspend wrapper

`system-suspend.c` reconstructs the wrapper at `0x41b11338`. Its 28-byte unit
matches all 16 bytes outside three genuine relocations. The unwind descriptor
matches `0x80b108a9`. A compile using the real pinned production headers/flags
confirms `sm_nsec_ctx.mon_lr` at offset `0x7c`, also asserted in source. The
pre-suspend hook retains its observed two-byte return-only body; its original
name remains unknown.

Ten composed QEMU cases execute this C wrapper, the retained standby caller
and the retained type reader together. They verify the saved global and
monitor return field before standby, all other monitor fields unchanged,
ignored context ID, zero return and the complete parameter-copy/diagnostic
path. Privileged cache/MMU calls and the ARM SRAM program are test substitutes.

```sh
python3 tests/release/test_stock_optee_system_suspend.py
```

[Proof](../../../docs/board-notes/stock-optee-system-suspend-proof.json)
records production-ABI compilation and the composed runtime boundary. This
unit remains outside the carrier until the runtime configuration and dispatcher
are reconstructed. Five other platform PSCI bodies remain unrecovered; the
carrier still needs six overrides including this wrapper's wiring. No physical
power, CPU release, reset or suspend/resume test ran.

## CPU-on and affinity control

`cpu-control.S` retains `psci_cpu_on`, `psci_affinity_info` and their outlined
current-core query. The text/literal units total 252 bytes; all 172 bytes
outside twenty genuine relocations match stock. Both compact unwind
descriptors and the twelve-byte current-core unwind payload match too.

QEMU passes 1,024 CPU-on cases, 6,288 affinity cases and an interrupt-mask
assertion case. Register banks are private test arrays; no physical MMIO is
mapped. Checks cover context publication, boot-vector writes, reset/power bit
order at the delay boundary, unchanged unrelated words, diagnostics and
returns. Original quirks are retained: CPU-on checks only the ID's low byte;
affinity ignores its level argument, uses ARM register-shift behavior and can
clear a control bit while reporting status.

```sh
python3 tests/release/test_stock_optee_cpu_control.py
```

[Proof](../../../docs/board-notes/stock-optee-cpu-control-proof.json) records
all relocation fields, unwind and test boundaries. Original `plat_init` maps
pointer object `0x41b49d00` to physical `0x09010000`, and `0x41b49d0c` to
`0x07000400`. These match existing `cpucfg_base` and `rtc_base` source bindings.
Patch 0013 and the builder now link the two strong PSCI overrides into the
carrier. The existing upstream context setter is reused; its 24 bytes match
outside one real pointer relocation. Two clean builds repeat deployable bytes,
and the full unit suite passes. Three PSCI bodies remain unrecovered: CPU
suspend, CPU off and system reset. System-suspend and full dispatcher wiring
remain unfinished. No hardware CPU release, power or status query ran.

## Watchdog system reset

Patch 0014 compiles `system-reset.S` as the strong `psci_system_reset` override.
Its 32-byte text/literal unit matches all 28 bytes outside the single genuine
`phys_to_virt_io` call relocation. The twelve-byte unwind payload matches too.
The existing source IO map includes the original `0x07020800` region. The
routine writes `0x203` at offset `0x10`, then `0x0d140001` at `0x14`, and enters
the original non-returning WFI/branch loop.

Four QEMU cases substitute a private register bank and terminate the emulated
wait loop by signal. They verify the mapping argument, writes, unchanged
unrelated words and failure on unexpected return. No hardware watchdog, host
or printer reset operation runs.

```sh
python3 tests/release/test_stock_optee_system_reset.py
```

[Proof](../../../docs/board-notes/stock-optee-system-reset-proof.json) records
actual linked bytes and two clean deployable repeats. Whole-carrier comparison
still fails. CPU suspend/off source and full system-suspend/dispatcher wiring
remain unfinished; no physical reset or resume was tested.
