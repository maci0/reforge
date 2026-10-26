# OP-TEE reconstruction research

This profile builds from source but **does not reproduce the original secure OS**. It is separate from the production firmware build. Its vendor header, secure-service integration and several reconstructed function shapes remain incomplete; it is not ready for deployment.

Run `tools/build/build-stock-optee.sh SOURCE_TAR NEW_OUTPUT_DIR [ORIGINAL_OPTEE_REFERENCE]`. The optional original executable is hash-checked before building and used only for comparison; none of its bytes enter compilation. Comparison requires full byte identity, allows no exceptions, and currently exits 1 while retaining the built artifacts and report.

The source archive is [official OP-TEE 3.7.0](https://github.com/OP-TEE/optee_os/commit/a2fa5018cb595a9cd9ab62e82c7485ca57a62084), SHA-256 `1662d74cd682ebfe1d52b3ced8a61c2d490a12a011b9c4255a73bd6b460e1b58`. The build uses the pinned Linaro 5.3.1 toolchain, the source commit's timestamp and an explicit `3.7.0-reforge-reconstruction` version label. It does not claim the original vendor's `553fe17e2-dirty` source identity.

The first two patches are published upstream implementations, unchanged:

- [SM4](https://github.com/OP-TEE/optee_os/commit/ade6f848e084d7c63f1e3866d7c059b8a9f9e834).
- [SM3](https://github.com/OP-TEE/optee_os/commit/47645577).

The third patch contains reconstructed T113 C and a platform-specific boot hook. Eight platform/helper functions have matched every original byte outside genuine object relocation fields; the CPU-interface initializer also matches all 28 bytes without relocations. Other bodies are semantic drafts and remain unverified. No original opcodes, target objects, post-link metadata replacements or empty vendor-service implementations are used. Explicit diagnostic arguments preserve observed runtime error reports, rather than manufacturing source-line padding.

The memory profile uses the observed `0x41b00000` secure OS, `0x41c00000` TA region and two MiB of shared memory at `0x41900000`. Original image strings establish enabled statistics and stack-canary support. Remaining configuration choices and reconstructed service behavior need continued binary verification.

Validation on 2026-10-26: two clean source compilations produced the same 246,276-byte `tee.bin`, SHA-256 `b7e0fd01d5328c778d2d6efed097cf9569c61068d1bc98db9e25465581e2f173`. The original is 300,248 bytes; 239,073 positions differ in their shared extent. These are comparison results, not a stock-equivalence claim. No hardware execution was performed.
