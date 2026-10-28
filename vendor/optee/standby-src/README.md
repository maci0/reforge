# Standalone SRAM standby reconstruction

Coverage at 2026-10-28: **1,832 bytes of recovered function extents plus
916 bytes of initialized data** from the original 8,400-byte SRAM image. Functions
include C memory helpers (116), ARM runtime (420), counted delays (116), descriptor
selection (88), C PMIC register helpers (160), and the connected TWI engine (932).
Comparisons match every bit outside 28 branch-relocation bytes, 16 data-pointer
bytes and twelve MOVW/MOVT address-immediate fields (192 bits). These require
the complete SRAM layout; they are not exceptions to the final whole-image gate.
Complete function comparisons cover 676 bytes, including the contiguous 472-byte
loop/runtime block. The connected TWI block also resolves all its internal branches.
[Runtime source and recipe](runtime/README.md) document its public source origin
and explicit standalone ABI adaptation. This is separate recovery work; the main
OP-TEE recipe still has no reconstructed complete standby payload or integration.

| C helper | Original SRAM address | Carrier offset | Bytes |
|---|---:|---:|---:|
| `standby_dram_master_enable` | `0x202a0` | `0x42a0` | 36 |
| `standby_dram_master_disable` | `0x202c4` | `0x42c4` | 32 |
| `standby_dram_checksum` | `0x20ed4` | `0x4ed4` | 48 |

The first two routines write the original DRAM master-access masks at
`0x03102020`, `0x03102024` and `0x03102028`. The checksum reads the start address
and byte count from original parameter indices 33 and 34, then adds complete
32-bit words while the integer address is below the computed 32-bit end.
It preserves sum/end-address wrap and partial-word length behavior. No new
validation or policy is introduced.

Compiler profile verified here: pinned Linaro GCC 5.3.1, ARM mode, `-O2`,
ARMv7-A with Cortex-A9 tuning. This is a proven way to generate these bytes;
it does not establish the original compiler identity or C spelling.

```sh
standby_cross="$PWD/vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-"
standby_out=$(mktemp -d)
"${standby_cross}gcc" -c -O2 -marm -march=armv7-a -mtune=cortex-a9 \
  -ffreestanding -fno-builtin -fno-unwind-tables -ffunction-sections \
  vendor/optee/standby-src/memory.c -o "$standby_out/memory.o"
python3 tests/release/test_stock_optee_standby_memory.py
```

Two fresh builds, including a separate copied source directory, produce identical complete objects,
with no undefined symbols or imported target runtime. The QEMU test maps an
anonymous guest-memory register bank, checks enable/disable/enable and all
neighboring words, then tests empty, full, partial-word, sum-overflow and
end-address-wrap checksum cases. Source data stays unchanged.
[Proof](../../../docs/board-notes/stock-optee-standby-memory-proof.json) records
reference offsets, full function hashes, compile flags and comparison scope.
The test skips explicitly when the pinned compiler or `qemu-arm` is absent.

Remaining work includes the 240-byte parameter header, entry/exit, the other
DRAM/clock/PMIC/TWI routines, data/BSS layout, source linker/packing recipe and
main secure-OS integration. These helpers are not used to fill executable gaps
with partial code or reference bytes.

One entry detail is established by the original instructions: after clearing
`0x220d0`, its post-increment byte-store loop branches with unsigned `BLS`
against loaded address `0x2229c`. It consequently clears **through `0x2229c`
inclusively**. The original allocation/linker-symbol convention is not yet
recovered; an assumed exclusive BSS bound must not silently change that startup
behavior. This is static instruction evidence, not an executed suspend/resume
test. No printer hardware was used.

The full `make unit` suite passes with the pinned boot0 compiler supplied;
no tests were skipped in that run.

## Counted-delay recovery (2026-10-28)

`spin.S` recovers the 40-byte repeated loop at SRAM `0x21b10` and the 12-byte
countdown loop at `0x21b38`. Both entire bodies match with no excluded bytes.
`delay.S` recovers the 8-byte scaled wrapper at `0x210a4` and 56-byte chunked
wrapper at `0x210ac`. Their only excluded bytes are three genuine four-byte
branch relocations; all three original branches target `0x21b38`, corresponding
to the source-defined `standby_delay_cycles`. Full relocation values await the
complete SRAM link; these are not exceptions to the final whole-image gate.

The short wrapper requests `(count << 2)` modulo 2^32. The chunked wrapper
requests 40,000 iterations while subtracting chunks of ten, followed by
`remaining * 1000 << 2`. The countdown loop runs one subtraction even for zero;
the repeated loop executes the original 17-pass structure and restores r0-r3.
Names retain the legacy scaling convention; physical microsecond/millisecond
calibration remains unverified.

ARM QEMU executes both real loop bodies for counts 0 through 17 and checks the
observed register/return behavior. Separate wrapper tests use a count recorder
to check zero, 32-bit scaling wrap and chunk boundaries at 10/11/20/21/25 without
substituting anything in production source. Two copied-source builds reproduce
identical individual and combined relocatable objects, with no undefined
symbols after combining the two units.

```sh
python3 tests/release/test_stock_optee_standby_delay.py
```

[Delay proof](../../../docs/board-notes/stock-optee-standby-delay-proof.json)
records exact body hashes, actual relocation fields and original branch targets.
Source-reconstructed function extents now total **652 bytes**: the earlier
536-byte complete comparisons plus these 116 delay bytes, of which twelve
branch-relocation bytes require the full link. This is not a complete SRAM
image. Header/entry, other DRAM/clock/PMIC/TWI code, data/link layout and main
secure-OS integration remain open. No physical timing or suspend/resume test was
performed.

`runtime/with-spin.lds` also links the loops immediately before the division
runtime in the observed source-section order. The entire contiguous 472-byte
block matches the original at carrier `0x5b10`, without excluded bytes, fixed
addresses or filler. Two separate copied-source builds reproduce the block;
the runtime regression test verifies its full SHA-256 as well as the original
420-byte division-only profile. Complete byte comparisons now cover 588 of the
652 recovered function bytes; the remaining wrappers contain twelve genuine
branch-relocation bytes pending the complete SRAM link.

## Descriptor selection recovery (2026-10-28)

`descriptor.S` reconstructs the complete 88-byte selector at SRAM `0x21260`
(carrier `0x5260`). All instruction bytes match, with no relocations or excluded
fields. Its descriptor argument contains an inclusive bound at byte offset 8
and an entry-array pointer at offset 12. Bit zero selects entry zero immediately;
otherwise the lowest selected index within the bound chooses an entry at
`base + index * 48`. No match returns null. The table contents and surrounding
callers remain unresolved; no table or target address is hardcoded in the source.

Two copied-source builds reproduce identical objects and bodies. The ARM test
checks every single-bit mask for bounds 0 through 33, bit-zero priority, multiple
selected bits, and empty masks through bound 256. ARM register-shift semantics
are retained rather than replaced with undefined C shifts.

```sh
python3 tests/release/test_stock_optee_standby_descriptor.py
```

[Descriptor proof](../../../docs/board-notes/stock-optee-standby-descriptor-proof.json)
records source/reference hashes. At that recovery stage, function extents totalled
740 bytes, of which 676 compare completely and twelve actual branch-relocation
bytes in the remaining 64-byte delay wrappers await the full SRAM link.
The main carrier remains unchanged; this is not a complete standby image.

## PMIC register helpers and tables (2026-10-28)

`pmic.c` reconstructs three helpers from C: read at SRAM `0x212b8` (20 bytes),
write at `0x212cc` (20), and masked update at `0x212e0` (120). The pinned GCC 5.3
flags used for the memory helpers reproduce every instruction outside four
actual branch relocations to `standby_twi_transfer`. All four original branches
target SRAM `0x21880`; the source uses that unresolved symbol, not a fixed
executable address. No target-code arrays or post-link substitutions are used.

The update helper reads first and returns on read failure. It compares
`(old & mask)` with the **unmasked** request before deciding whether to write;
only the write combines `(old & ~mask) | (request & mask)`, truncated to a byte.
It returns the write status. An ARM test covers all 256 old bytes, all 256 byte
masks, and five requests each (327,680 cases), plus direct calls, high-bit masks
and requests, no-write paths and failure propagation. The test-only TWI backend
records transactions; it is not compiled into the production sources.

`pmic-data.c` reconstructs the 16-byte device record, sixteen 48-byte entries,
and three piecewise voltage-range tables (112 bytes). These total 896 bytes at
carrier `0x5d08..0x5d77` and `0x5dc0..0x60cf`. Every non-pointer byte matches;
the four actual `R_ARM_ABS32` relocations reference the entry array and its three
range tables. Linked ARM tests validate all sixteen selector results and range
pointers using the real recovered selector. Field names express observed consumer
behavior; original C/debug names and the PMIC part identity are not established.

The original device address is zero and must be initialized by its caller.
The table count is 16, although the recovered selector treats that bound
inclusively. Selecting bit 16 consequently returns a one-past-end pointer. This
original behavior is retained and tested without dereference; this partial
reconstruction must not be deployed as a corrected driver.

Two copied-source builds reproduce each object and the combined relocatable
object. The link uses relative input paths so GNU ld's automatically generated
`STT_FILE` symbol does not capture the build directory. The only undefined symbol
in that PMIC/data/selector-only object is `standby_twi_transfer`; the later
TWI reconstruction supplies it.

```sh
python3 tests/release/test_stock_optee_standby_pmic.py
```

[PMIC proof](../../../docs/board-notes/stock-optee-standby-pmic-proof.json) records
hashes, relocation fields and original branch/pointer targets. At this recovery
stage the TWI engine was still unresolved; see the connected recovery below.
Remaining regulator consumers, the full SRAM link and carrier integration are
unfinished. No physical PMIC/TWI, calibrated timing or suspend/resume test was run.

## Connected TWI engine (2026-10-28)

`twi.c`, `twi-transfer.S`, and `twi.h` reconstruct all five functions in the
contiguous 932-byte block at SRAM `0x21754..0x21af7` (carrier `0x5754..0x5af7`):

| Function | Bytes | Source |
|---|---:|---|
| Stop and poll idle/status/line state | 144 | ARM assembly |
| Save state, set divider and reset controller | 80 | C |
| Set divider | 24 | C |
| Restore saved divider/control | 52 | C |
| Single-register read/write transaction | 632 | ARM assembly |

The three C functions use the memory-helper compiler flags plus
`-fno-section-anchors`, so their address relocations directly name the state and
base-table symbols. Five genuine MMIO base addresses reproduce the original
20-byte controller table; a normal zero-initialized 12-byte C state replaces no
recorded executable address. No reference binary is a build input.

`twi.lds` links the five source sections in observed order, without fixed
addresses or gap fill. Both calls from transfer to stop then match their original
four-byte branch encodings. The **entire block** matches after masking only the
sixteen immediate bits in each of twelve genuine MOVW/MOVT address relocations
(mask `0x000f0fff`). All remaining bits, including opcodes, register selections,
internal branches and polling limits, match. Original address pairs refer to
state at `0x22290` and the controller table at `0x21d78`. Their final values
require the full SRAM data/BSS layout. The proof records raw byte differences;
this partial link is not accepted as an identical SRAM image.

Two separate copied-source builds reproduce the objects and linked ELF exactly,
with no undefined symbols. ARM QEMU executes the production objects against a
reactive peripheral model. A test-only SIGSEGV handler traps guest virtual MMIO
and emulates unconditional ARM word loads/stores; it leaves all other execution
to QEMU. It never maps physical hardware or changes production code. The test
covers all five controllers, delayed reset completion, state restore, read/write
success, every status-error return, all three stop failures and all seven
transfer timeouts. Polling limits execute all 327,679 iterations; no counter is
shortened. Actual PMIC read/write/update helpers also run through this engine.

The test preserves observed quirks: only operation `1` writes; other operation
values read. Transfer ignores stop errors. The final byte is copied before its
status is rejected. Status is narrowed to eight bits, but register writes and
the repeated-start address write retain their observed full-word values. Init
waits indefinitely for reset; restore requests reset without waiting. These are
reconstruction facts, not claims of robust driver behavior.

```sh
python3 tests/release/test_stock_optee_standby_twi.py
```

[TWI proof](../../../docs/board-notes/stock-optee-standby-twi-proof.json) retains
source/reference hashes, the exact immediate fields, original symbol targets,
resolved-call checks and copied-source repeatability. Remaining regulator,
DRAM/clock, entry/stack code and full SRAM data/BSS layout still prevent a complete
payload and carrier build. No physical bus timing, PMIC or suspend/resume test ran.
