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
configuration objects, standby-type reader and complete service binding remain
unfinished; this caller is not wired into the secure-OS build yet.
