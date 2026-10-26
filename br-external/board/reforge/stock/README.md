# Recovered stock AD5M Pro board configuration

These are non-executable configuration sources recovered from the original
board artifacts, not a replacement for ReForge's normal board configuration.
No target binary code is stored here.

- `kernel.dts`: stock FAT p1 `sunxi.dtb`, corroborated by the independent
  AceOfBase dump. Compiles to SHA-256
  `27501dc48c5ad4c71e3a12742e3ef2a162d6a2d8285bbbac82488c7fade79e21`.
- `toc.dts`: the primary TOC board variant. Its only difference is LCD PWM6
  instead of the kernel DTB's PWM7. Unpadded SHA-256
  `c6984cf79fc07fa5ad898f6828f13b4689809b9d3cdf6301444ee69a6a15103d`.
- `u-boot-control.dts`: the primary 2023 U-Boot control tree, SHA-256
  `488d06dfbab38e7e6d06ec9354e2fdb4d8ceadfa89b082641c1d2073a37c6731`.
- `environment.txt`: ordered stock environment records. The 128-KiB redundant
  slot uses little-endian CRC32, active flag 1 and zero padding; the remainder
  of each 1-MiB partition is zero. Both generated partitions have SHA-256
  `6c8985dc584a50782267ff6a01fa8e886901ab5e48c550a0a2055dfd806628d7`.

Compile and strictly verify them without reading a firmware image:

```sh
python3 tools/build/build-stock-board-data.py build/stock-board-data
```

The command requires `dtc`, records source/tool identities and rejects any
artifact whose full hash differs. It never flashes or changes a device.
Reference locations and independent-dump provenance are documented in
[`stock-boot-artifacts.json`](../../../../docs/board-notes/stock-boot-artifacts.json).
