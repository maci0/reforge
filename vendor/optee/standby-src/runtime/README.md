# Standalone ARM division runtime

The complete **420-byte** runtime block at original SRAM
`0x21b44..0x21ce8` / OP-TEE carrier `0x5b44..0x5ce8` is reproduced from source,
including resolved branches. No bytes are excluded from the comparison.

Upstream input: [U-Boot v2018.05 `arch/arm/lib/lib1funcs.S`](https://github.com/u-boot/u-boot/blob/v2018.05/arch/arm/lib/lib1funcs.S),
SHA-256 `f7a729a1f16ce16de2e2a55781be5c8609fb71556eb96e0b1545af3842649097`.
The held SDK file is byte-identical to this public file. It retains Nicolas
Pitre/FSF attribution, SPDX GPL-2.0+ and the included license text. The upstream
file is unmodified; `standby-div0.patch` carries the one source change separately.

The recovered profile differs from generic U-Boot in two explicit ways:

- The small ABI headers declare ARM-state returns and word-aligned entry points.
  They support this standalone source file, not a general U-Boot configuration.
- The source patch removes the division-zero callback. The original handler
  saves LR, returns quotient zero and restores PC; it does not call `__div0`.
  This preserves the original behavior, including remainder equal to dividend
  when a quotient/remainder helper sees divisor zero.

The linked profile contains the 12-byte zero handler, 156-byte unsigned divider,
204-byte signed divider and two 24-byte AAPCS quotient/remainder wrappers.
`runtime.lds` selects those source sections in the observed order and omits
unused modulo-only sections. It supplies no original absolute function addresses,
size padding or imported target bytes. The original source package/header
identity is not established by this byte-equivalent adaptation.

```sh
standby_cross="$PWD/vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-"
standby_runtime="$PWD/vendor/optee/standby-src/runtime"
standby_out=$(mktemp -d)
cp "$standby_runtime/lib1funcs.S" "$standby_out/"
patch --batch --fuzz=0 -d "$standby_out" -p1 -i "$standby_runtime/standby-div0.patch"
"${standby_cross}gcc" -c -marm -march=armv7-a -D__ASSEMBLY__ -D__UBOOT__ \
  -D__LINUX_ARM_ARCH__=7 -I"$standby_runtime/abi" \
  "$standby_out/lib1funcs.S" -o "$standby_out/runtime.o"
"${standby_cross}ld" -T "$standby_runtime/runtime.lds" \
  "$standby_out/runtime.o" -o "$standby_out/runtime.elf"
"${standby_cross}objcopy" -O binary -j .text \
  "$standby_out/runtime.elf" "$standby_out/runtime.bin"
python3 tests/release/test_stock_optee_standby_runtime.py
```

Two fresh copied-source builds reproduce identical complete objects and the
linked block SHA-256
`cc0b4d9fa3eae69b01e64d454781d3e3f13de1dc691cfa919b4615d0cbea31b4`.
The linked block has no undefined symbols or imported compiler runtime.
Sixteen ARM QEMU cases check direct quotient and two-register quotient/remainder
results: zero, smaller/equal operands, powers of two, general divisors, unsigned
maximum, negative signs, signed-minimum overflow and original zero-divisor
behavior. Assembly adapters in the test capture the AAPCS multi-register results.
[Proof](../../../../docs/board-notes/stock-optee-standby-runtime-proof.json) records
hashes and scope. The full unit suite passes with the pinned boot0 compiler
supplied; no skips are reported.

This remains partial SRAM recovery. The 8,400-byte standby image, its entry,
other DRAM/clock/PMIC/TWI code, data/link layout and secure-OS integration remain
unfinished. No suspend/resume or printer-hardware execution was performed.
