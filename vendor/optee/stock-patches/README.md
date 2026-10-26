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
