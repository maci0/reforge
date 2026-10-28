# Standalone SRAM standby reconstruction

Coverage at 2026-10-28: **3,668 bytes of recovered function extents plus
1,004 bytes of initialized data** from the original 8,400-byte SRAM image.
Recovered modules cover memory, delays, clock selection/entry/exit, PMIC setup/
register/group operations, regulator policy, TWI, stack, division and secure WFI.
Across these extents, every bit matches outside twenty-six real MOVW/MOVT
address-immediate fields (416 bits) and four real data-pointer words (16 bytes).
**All branch encodings now compare without masks**, including the delay wrappers.
These address fields require the complete SRAM link; they are not final exceptions.
Complete function-byte comparisons cover 2,080 bytes. The connected 4,556-byte
code/data suffix has every initialized symbol at its original relative offset.
Its 16 bytes of recovered zeroed BSS are separate from initialized-data totals;
a preceding 444-byte BSS/layout gap remains unresolved.
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
resolved-call checks and copied-source repeatability. The connected recovery
below also supplies regulator and stack code. Earlier PMIC setup, DRAM/clock,
entry code and full SRAM data/BSS layout still prevent a complete payload and
carrier build. No physical bus timing, PMIC or suspend/resume test ran.

## Connected regulator and stack recovery (2026-10-28)

`regulator.S` reconstructs set/get voltage and set/get enable routines from
SRAM `0x21358..0x21753` (1,020 bytes). `regulator.h` exposes their reconstructed
interfaces. `stack.S` reconstructs the 12-byte switch and 8-byte restore routines
plus their four-byte literal at `0x21af8..0x21b0f`. The literal is expressed from
observed SRAM geometry (`0x20000 + 0x8000 - 16`), not an executable pointer or
post-link substitution. The stack helpers change SP and must be called through
assembly; a guest assembly adapter verifies switching and restoring the real SP.

`pmic-twi-runtime.lds` links the selector, C PMIC helpers, regulators, TWI engine,
stack routines, loops and published-source division runtime as one continuous
**2,696-byte block**, matching original carrier `0x5260..0x5ce7` outside only the
TWI global-address immediates already identified above. No branch bytes are
masked: previous PMIC-to-TWI calls, regulator-to-TWI/update/division calls and
all runtime/internal branches now compare completely. All four regulator bodies
and both stack bodies match every byte in this linked profile. Source sections
supply every byte in the block; no gap fill or reference payload is inserted.
Two copied-source builds reproduce every object and the linked ELF, which has
no undefined symbols. The final SRAM layout remains unresolved.

The ARM test uses the real entry/range tables and recovered division runtime.
It checks all 4,096 voltage reads and 4,096 enable reads (16 entries × 256 byte
codes each), plus piecewise gaps/endpoints, linear rounding, fixed-voltage
zero-divisor handling, no-write paths, error propagation and explicit enable/
disable encodings. Separate runs observe each original invalid-selection null
read using a SIGSEGV handler; the routines are not changed to return safe errors.
The stack test maps guest virtual SRAM only, never physical memory.

Observed behavior is preserved: linear voltage requests round up, piecewise
requests round down, linear setters do not clamp to the maximum field, and
voltage codes are not masked before merging into the output byte. With the
legacy default disable encoding, an already-clear bit can still cause a write.
Explicit enable/disable status fields compare the whole read byte. These facts
are useful for fidelity; they do not establish corrected or hardware-safe behavior.

```sh
python3 tests/release/test_stock_optee_standby_regulator.py
```

[Regulator proof](../../../docs/board-notes/stock-optee-standby-regulator-proof.json)
records full per-function hashes, the connected block comparison, exact stack
literal and source-copy repeatability. Earlier PMIC setup and DRAM/clock/entry
code, header, complete data/BSS placement and carrier integration are still open.
No physical regulator, stack bringup or suspend/resume validation was performed.

## PMIC setup, grouped control and secure WFI (2026-10-28)

`pmic-setup.c` reconstructs preparation (108 bytes), direct register-3 read
(20), and address/controller initialization (24) from C. `pmic-group.S`
reconstructs the 132-byte grouped-control routine with its original signed-byte
loads and register allocation. The C candidate for grouping was not byte-identical;
the readable ARM source supplies symbolic device/selector/update references.
`pmic-setup.h` declares the reconstructed interfaces.

Preparation writes `0xff` to registers `0x48`, `0x49`, `0x4a`, then `0x1d` to
`0x26`. It ignores the first three statuses and returns the fourth. Grouped control
considers only entry bits 0..15 whose full control-register field equals the
request; it gathers their byte masks and calls update even for empty/unmatched
selection. Its legacy request encoding can force an unchanged write. The ID
wrapper passes the full address argument with register 3. Initialization stores
the full address word before calling TWI init, and returns zero regardless of
its callee's status. These observed behaviors are preserved, not corrected.

The ARM test executes **1,048,576 grouped cases**: every 16-bit subset, four
control registers (including a nonmatching high-valued register), and four old
bytes. It uses the real selector, register-update helper and entry data with a
test-only TWI/init recorders. Additional cases check high flag bits, empty masks, errors,
preparation ordering/return behavior, ID reads, address-store ordering and all
five forwarded controller indices.

`power.S` reconstructs the adjacent 96-byte secure-WFI primitive at SRAM
`0x210e4`. Every byte matches, including its MMIO/key writes, SCR save/set/restore,
barriers and WFI. This is **static instruction verification only**: no userspace
QEMU execution is claimed for privileged CP15/WFI or the board power sequence.
The execution guest deliberately does not link or call this primitive.

`pmic-control-runtime.lds` extends the connected block to **3,076 bytes** at
carrier `0x50e4..0x5ce7`. All branch encodings match. Only eighteen real MOVW/
MOVT address-immediate fields remain masked: six refer to the original device
record at `0x21dc0`, and the previous twelve to TWI state/controller-table symbols.
All opcode/register bits remain compared. No fixed function addresses, reference
payload, gap fill or post-link edits supply the block. Two copied-source builds
reproduce every object and the linked ELF with no undefined symbols. Earlier
profiles and their individual object relocation checks remain available.

```sh
python3 tests/release/test_stock_optee_standby_pmic_setup.py
```

[Setup/WFI proof](../../../docs/board-notes/stock-optee-standby-pmic-setup-proof.json)
records source and original hashes, exact masked fields, original device target,
repeat builds and execution scope. Header/entry, earlier DRAM/clock routines,
complete data/BSS placement and carrier integration remain open. No physical PMIC,
CPU power transition or suspend/resume validation has run.

## Clock sequence and complete initialized suffix (2026-10-28)

`clock.S` reconstructs selection (96 bytes), low-power entry (208) and exit
(112) at SRAM `0x20f04..0x210a3`. `clock-data.c` reconstructs eight PLL register
addresses, six mutable eight-byte saved-clock records, the SRAM parameter-base
word and one zeroed auxiliary-state word. All 84 new initialized-data bytes match
completely. The four-byte auxiliary word and existing 12-byte TWI state form the
recovered BSS tail; their four-byte relative spacing matches the original.

Selection preserves low 29 bits and ORs `(mode << 31) | (mode << 30) | (mode << 29)`;
it is not replaced with multiplication, which differs for some non-boolean inputs.
Entry saves source/divider bytes only when a record's saved flag is zero, always
sets that flag to one, writes each control twice, and executes the observed keyed
and auxiliary-register sequence. Exit restores the auxiliary register and PLL
selection but does not restore those record fields itself. Duplicate writes and
the unused register read are retained.

The ARM guest runs the **unmodified clock and real delay objects** against two
4-KiB virtual MMIO banks. A SIGSEGV handler emulates only word loads/stores and
records every address, direction, value and order. Tests use three seeded banks,
ten mode values, mixed zero/nonzero saved flags and repeated entry, checking all
untouched words. They assert exactly 16 operations per selection, 42 per entry
and 24 per exit. Guest execution is not a measurement of physical clock/bus timing.

`clock-control-runtime.lds` links **4,556 initialized bytes** covering original
carrier `0x4f04..0x60cf`: a 3,556-byte text/literal block and all 1,000 following
data bytes. Every branch compares directly, closing the previous delay-branch
checks. Only 26 actual MOVW/MOVT address immediates and four actual ABS32 table
pointers remain normalized; opcode/register bits and every other bit match.
The table pointers additionally resolve to the exact original *relative* targets,
and all nine initialized symbols have their original relative positions. The
parameter-base word is a hardware SRAM-base value, not an executable pointer.

The partial source link starts at zero, without fixed function addresses, reference
payload or gap fill. Applying the original code-origin offset for comparison
places the recovered BSS words 444 bytes earlier than their original positions.
This is a constraint on missing declarations/alignment/linker inputs, not proof
that all 444 bytes are variables. No arbitrary BSS padding is added. Recovering
the preceding code/header and real BSS layout is required to compare absolute
addresses and emit the complete initialized image.

Two copied-source builds reproduce all objects and the linked ELF, with no
undefined symbols. Earlier profiles retain their bounded individual checks.

```sh
python3 tests/release/test_stock_optee_standby_clock.py
```

[Clock/suffix proof](../../../docs/board-notes/stock-optee-standby-clock-proof.json)
records exact fields, original targets, relative symbol positions, BSS constraint
and repeat builds. Earlier header/entry/DRAM code, full BSS and secure-OS
integration remain open. Secure WFI is still static-only; no physical clock
stability, DRAM retention or suspend/resume validation was performed.
