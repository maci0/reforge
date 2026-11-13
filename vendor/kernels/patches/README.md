# `vendor/kernels/patches/`

Historical out-of-band patch for an early stock-kernel attempt. It was
applied to the BSP submodule (`vendor/kernels/tina-bsp-kernel`) at build
time and reverted afterward so the submodule stayed at `349a0b9`. That
apply-and-revert flow is not the current stock build.

## Current stock build

[`tools/build/build-bsp-kernel-stock.sh`](../../../tools/build/build-bsp-kernel-stock.sh)
does not patch or reset the submodule. The caller passes hash-pinned kernel
and Wi-Fi source archives plus the original Image and Wi-Fi module. The
script checks those hashes, extracts into a fresh output directory, applies
[`../stock-patches/`](../stock-patches/), and builds inside `bwrap` so the
historical SDK paths exist only in that namespace. Current recipe and
result: [`stock bringup recipe`](../../../docs/board-notes/stock-bringup-rebuild.md#current-kernel-and-wi-fi-reproduction-command).

## `0001-byte-identical-reproduction.patch` (historical)

The June 2026 attempt that used this patch, against the submodule, reached
**+128 B (+0.00099 %)** of stock's `Image`. That delta belongs to that
attempt. It is not the result of the current builder.

What the patch does (5 items, see in-patch commentary for details):

1. Wires up `CONFIG_CAN_SUN8I` (Kconfig + Makefile) so the orphan
   `drivers/net/can/sunxi_can.c` + `sunxi_can_asm.S` actually build.
2. Adds a reconstructed `drivers/net/can/sunxi_can_asm.h` (30
   `SUNXI_*` register/bit defines from mainline `sun4i_can.c`,
   12 `can_asm_*` prototypes inferred from `sunxi_can.c` call sites).
3. Adds a stub `drivers/staging/rtl8821cu/Kconfig` so the captured
   stock `.config`'s `CONFIG_RTL8821CU=m` resolves at the right
   IKCONFIG position. No Makefile target — no module produced.
4. Hides 14 newer Kconfig symbols (BT/wireless/audio-V2/pinctrl/rpmsg)
   that the iLotusK9 BSP added after FF's snapshot, via
   `depends on FORCE_HIDE_NEWER_BSP` (undefined symbol = always-false).
5. Forces `CONFIG_PLUGIN_HOSTCC=""` so `CONFIG_GCC_PLUGINS` auto-vanishes
   (matches stock's no-g++ build host).

Full analysis + reproduction steps:
[`../../../docs/research/kernel/2026-06-04-byte-identical-kernel-reproduction.md`](../../../docs/research/kernel/2026-06-04-byte-identical-kernel-reproduction.md).

## Convention for this historical patch

- The file is a unified diff generated via `git -C <submodule> diff` over
  the modified files plus `git diff --no-index /dev/null <new-file>` for
  each new file.
- It applied with `git apply --check` against the pinned submodule commit
  `349a0b9fe63a03ea21198d104e5e9e01e7c068a6`. The old workflow reverted
  the submodule from an `EXIT` trap. The current builder does not do that.
