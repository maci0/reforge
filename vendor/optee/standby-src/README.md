# Standalone SRAM standby reconstruction

Coverage at 2026-10-28: **three C helpers / 116 initialized-code bytes** of the
original 8,400-byte SRAM image. Their entire function bodies match, with no
relocation exclusions. This is separate recovery work; the main OP-TEE recipe
still has no reconstructed complete standby payload or service integration.

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
