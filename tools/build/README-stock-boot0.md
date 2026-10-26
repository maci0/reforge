# Stock boot0 source reconstruction

The clean source build reproduces all executable code, board configuration, initialized data and packing bytes of the original 49,152-byte AD5M boot0. **Eleven bytes still differ:** the seven-character source commit label at `0x2f8` and its four-byte additive checksum at `0x0c`. The original source commit `5224261` has not been recovered. An exported source archive naturally generates an empty label; the recipe never substitutes the original label or alters compiled metadata.

The recipe deliberately exits unsuccessfully until the **whole file** matches. Its retained `manifest.json` lists the precise differences, actual label bytes, compiler hashes, checksum validity and whether every byte outside those two provenance fields matches. No hardware is flashed or tested by this recipe.

Base source: [szemzoa/sun8iw20_spl at aedc18e734ecc71262fb64f962f485a12e56981c](https://github.com/szemzoa/sun8iw20_spl/tree/aedc18e734ecc71262fb64f962f485a12e56981c), archive SHA-256 `2cb993eb5218ec53c9f35f8aa2435cc9e3fbee5873203149b2159509e9ef775b`.

Additional source inputs retained in the patch:

- Whole board and efuse units from [DongshanPI/100ASK_T113-Pro_TinaSDK at a4ec2a23d82a3ee0adcead212c0cb4cf472178d8](https://github.com/DongshanPI/100ASK_T113-Pro_TinaSDK/tree/a4ec2a23d82a3ee0adcead212c0cb4cf472178d8/lichee/brandy-2.0/spl). Their SHA-256 values are `e23fe799401693a0c93d1e595c2587208a96a231fa7c694bc9ab1ee0bc31b770` and `ceabd84839f88e73ee73a16bd07205fde9e08d576da519139b9722e5eeeaf402` respectively. The efuse unit uses the `drivers/sid.c` build path.
- The legacy bit-delay function and its real configuration tables from [smaeul/sun20i_d1_spl at d21a737da79521923e2f235891dab7b7fe5692ff](https://github.com/smaeul/sun20i_d1_spl/blob/d21a737da79521923e2f235891dab7b7fe5692ff/drivers/dram/sun20iw1p1/lib-dram/mctl_hal.c), file SHA-256 `b89cdc4c78736e0e626906116e680e3567b0c519064141363a088ba4de20f377`. Address-access conventions and two observed reset/indexing errors are repaired. Its unused code is discarded naturally; its configuration tables remain as in the original link.
- The held SDK's `nboot/main/boot0_main.c`, with the observed original UART/control-flow changes. The SDK archive SHA-256 is `6ed0f793436067c694bcec3538b24861b48f8d914c603f48aa5939c26f158197`.
- Recovered DRAM algorithms written as readable Thumb assembly with named registers, labels, configuration tables and real relocations. These reconstruct the verified program; they do not claim to recover every original C spelling. One retained C routine uses an explicit register preference. Source-owned plaintext diagnostic strings preserve the original messages and order.

Supply local Linaro GCC **7.2.1 2017.11** and **4.6.3 2012.02** cross prefixes. The 92-byte legacy chip-identification C unit matches with GCC 4.6.3; other C and assembly use GCC 7.2.1. The recipe pins the compiler components, their `libgcc` input and the original reference SHA-256. Compiler binaries are external build tools; this recipe does not bootstrap them from source.

```sh
tools/build/build-stock-boot0.sh \
  /path/to/sun8iw20_spl-aedc18e734ecc71262fb64f962f485a12e56981c.tar.gz \
  /path/to/gcc-linaro-7.2.1-2017.11-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi- \
  /path/to/gcc-linaro-arm-linux-gnueabi-2012.02-20120222_linux/bin/arm-linux-gnueabi- \
  /path/to/original-boot0.bin /tmp/new-boot0-build
```

The bundled extensionless `libdram` ELF is never extracted or linked. Its replacement is compiled entirely from the patched C and assembly sources. The reference is used only for comparison. The source packer implements the vendor's deterministic default-seed glibc random stream and additive checksum; it copies no stock tail bytes. Git discovery stops at the new output directory so an unrelated parent repository cannot supply a false source label.

Recovered MMC message arguments retain original runtime diagnostic IDs as explicit integers. There are no `#line` overrides or line padding.

```sh
python3 -m unittest discover -s tests/release -p test_stock_boot0_packer.py
```
