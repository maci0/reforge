# Stock AD5M TOC1 packing

`pack-stock-toc1.py` constructs the unencrypted three-member `sunxi-package` used
by the captured AD5M. It takes explicit payloads; no firmware image, reference
header, original executable or proprietary packaging tool is needed to pack.
The output must be new; an existing file is never overwritten.

```sh
python3 tools/build/pack-stock-toc1.py \
  SOURCE_BUILD/u-boot.bin SOURCE_BUILD/optee.bin SOURCE_BUILD/toc-padded.dtb \
  NEW_OUTPUT/sunxi-package.bin
```

The caller must establish source provenance of those three files. The packer
cannot infer provenance from executable bytes. OP-TEE remains unreproduced, and
the different golden 2025 backup U-Boot remains unreproduced; consequently this
recipe does not yet produce a wholly source-built, stock-identical package.

The 64-byte main and 368-byte item structures follow the published BSP's
`include/private_toc.h` (also retained in the boot0 source closure build).
This board's profile is three binary items, in order `u-boot`, `optee`, `dtb`,
unencrypted, run addresses and indices zero. Main serial/status/version/reserved
fields are zero. Main/item terminal tags are `0x3b45494d` / `0x3b454949`.
Payloads start at computed 2-KiB boundaries; the container is zero-filled to a
16-KiB boundary. Its checksum is the little-endian 32-bit word sum with the
checksum field temporarily set to `0x5f0a6c39`, modulo 2^32.

## Verification on 2026-10-28

Both golden TOCs were reconstructed from their extracted members and compared
as complete files: primary SHA-256
`9345c28b17c90b994e7688bf611ca275b5be230ce6e9a0e9e74b8c7983f1bc07`,
backup `8f6d733683e8e3bba479584983002be88fca56de01b08b4ddc8f0d84a9664849`.
Each is 1,343,488 bytes. The primary was additionally packed using source-built
U-Boot and source-built padded TOC DTB, with the same complete-file result.
**Reference OP-TEE was used only for this format validation.** No reference
payload is committed or implicitly used by the recipe.

[Proof record](../../docs/board-notes/stock-toc-format-proof.json) records member
hashes and comparison boundaries. Local outputs are retained under
`build/stock-toc-reconstruction/`. Three small tests check the wire layout,
alignment, untouched payloads, zero padding, checksum, empty-input rejection
and no-overwrite behavior:

```sh
python3 tests/release/test_stock_toc1_packer.py
```

No package has been flashed or booted on hardware.
