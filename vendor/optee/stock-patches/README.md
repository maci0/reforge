# OP-TEE reconstruction research

This profile builds from source but **does not reproduce the original secure OS**. It is separate from the production firmware build. Its standby code, secure-service integration and several reconstructed function shapes remain incomplete; it is not ready for deployment.

Run `tools/build/build-stock-optee.sh SOURCE_TAR NEW_OUTPUT_DIR [ORIGINAL_OPTEE_REFERENCE]`. The optional original executable is hash-checked before building and used only for comparison; none of its bytes enter compilation. Comparison requires full byte identity, allows no exceptions, and currently exits 1 while retaining the built artifacts and report.

The source archive is [official OP-TEE 3.7.0](https://github.com/OP-TEE/optee_os/commit/a2fa5018cb595a9cd9ab62e82c7485ca57a62084), SHA-256 `1662d74cd682ebfe1d52b3ced8a61c2d490a12a011b9c4255a73bd6b460e1b58`. The build uses the pinned Linaro 5.3.1 toolchain, the source commit's timestamp and an explicit `3.7.0-reforge-reconstruction` version label. It does not claim the original vendor's `553fe17e2-dirty` source identity.

The first two patches are published upstream implementations, unchanged:

- [SM4](https://github.com/OP-TEE/optee_os/commit/ade6f848e084d7c63f1e3866d7c059b8a9f9e834).
- [SM3](https://github.com/OP-TEE/optee_os/commit/47645577).

The third patch contains reconstructed T113 C and a platform-specific boot hook. The current profile has nine platform/helper functions matching every original byte outside genuine object relocation fields (620 bytes in total); the CPU-interface initializer and early CPU-reset routine also match all their bytes without relocations. Other bodies are semantic drafts and remain unverified. No original opcodes, target objects, post-link metadata replacements or empty vendor-service implementations are used. Explicit diagnostic arguments preserve observed runtime error reports, rather than manufacturing source-line padding.

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
The verified platform/helper total is now ten bodies / 792 bytes outside genuine
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
