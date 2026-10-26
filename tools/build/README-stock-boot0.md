# Stock boot0 source reconstruction

This research build compiles the recovered T113 boot0/SPL source and strictly compares it with the original AD5M reference. It currently **fails the comparison**: several DRAM routines and original source metadata remain unresolved. Artifacts, build logs, compiler hashes and the difference count remain in the new output directory. Nothing is flashed.

Source archive: [szemzoa/sun8iw20_spl at aedc18e734ecc71262fb64f962f485a12e56981c](https://github.com/szemzoa/sun8iw20_spl/tree/aedc18e734ecc71262fb64f962f485a12e56981c), SHA-256 `2cb993eb5218ec53c9f35f8aa2435cc9e3fbee5873203149b2159509e9ef775b`.

Supply local Linaro GCC **7.2.1 2017.11** and **4.6.3 2012.02** cross prefixes. The small legacy chip-identification C unit matches the stock code with GCC 4.6.3; the remaining code uses GCC 7.2.1. The recipe pins the compiler components and the original reference SHA-256. Compiler binaries are external build tools; this recipe does not bootstrap them from source.

```sh
tools/build/build-stock-boot0.sh \
  /path/to/sun8iw20_spl-aedc18e734ecc71262fb64f962f485a12e56981c.tar.gz \
  /path/to/gcc-linaro-7.2.1-2017.11-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi- \
  /path/to/gcc-linaro-arm-linux-gnueabi-2012.02-20120222_linux/bin/arm-linux-gnueabi- \
  /path/to/original-boot0.bin /tmp/new-boot0-build
```

The archive's bundled extensionless `libdram` ELF is rejected from extraction. Its replacement is compiled from the patched C sources. The reference is used only for identity checks and the final comparison. The packer implements the vendor's deterministic default-seed glibc random stream and additive checksum from source; it does not copy stock tail bytes.

```sh
python3 -m unittest discover -s tests/release -p test_stock_boot0_packer.py
```

Recovered MMC error-message arguments retain the original runtime diagnostic IDs as explicit integer arguments. They do not use `#line` directives or claim that the reconstructed C has the original source layout.
