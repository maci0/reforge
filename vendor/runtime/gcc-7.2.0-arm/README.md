# GNU ARM integer-division runtime source

Unmodified files from GCC `releases/gcc-7.2.0`, directory `libgcc/config/arm`:
https://github.com/gcc-mirror/gcc/tree/releases/gcc-7.2.0/libgcc/config/arm

These are upstream source inputs that reproduce the target text from Linaro
GCC 7.2.1's three boot0 runtime objects. This does not identify the exact historical
Linaro source checkout or reproduce the compiler executable.

| File | SHA-256 |
|---|---|
| lib1funcs.S | `642a72ad8ce5287138b7774ea3eaf5644217dcba8b3f8ad14f228a5c87743fa7` |
| ieee754-df.S | `3ca3172d2f904a8d86850e1f9a468bce6e376291fe278ee07eef4151a8c58d0b` |
| ieee754-sf.S | `4a2f2640bd07f6af8a36c36735f8aa90e19518c5a524ee686a299f20612063a7` |
| bpabi.S | `58adbe574b287470c3292549bcfc1199e7f05d7eb16881d8f226c8d014a40587` |

Compile `lib1funcs.S` with Linaro 7.2.1's default target profile and
`-c -g -O2 -fPIC`, separately defining `L_udivsi3`, `L_divsi3`, `L_dvmd_lnx`.
The other three files are upstream includes; no floating-point routine is selected.
The target text lengths are 632, 688 and 12 bytes. All target text matches the
original toolchain objects, and linking the source-built replacements preserves
all 34,592 raw boot0 bytes. The build recipe makes a deterministic archive from
only these three newly compiled objects; the compiler-distributed `libgcc.a`
is not linked.

License: GPL-3.0-or-later with GCC Runtime Library Exception 3.1; see the retained
upstream `COPYING3` and `COPYING.RUNTIME` and individual source notices.
