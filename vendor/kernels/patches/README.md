# `vendor/kernels/patches/`

Out-of-band patches applied to the BSP kernel submodule
(`vendor/kernels/tina-bsp-kernel`) **at build time only**. The patches
are never committed into the submodule itself — the submodule is kept
pristine at its pinned commit (`349a0b9`). Build scripts apply the
relevant patch, build, then revert via an `EXIT` trap so the working
tree stays clean.

## `0001-byte-identical-reproduction.patch`

Used by [`tools/build/build-bsp-kernel-stock.sh`](../../../tools/build/build-bsp-kernel-stock.sh)
for the byte-identical-attempt reproduction of stock FlashForge's
AD5M Pro kernel. Reaches **+128 B (+0.00099 %) of stock's `Image`**
without the (NDA-only) Allwinner T113-Linux-Auto-v1.1 SDK overlay.

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
[`../../../docs/research/2026-06-04-byte-identical-kernel-reproduction.md`](../../../docs/research/2026-06-04-byte-identical-kernel-reproduction.md).

## Convention

- Patch files are unified `diff` format generated via
  `git -C <submodule> diff` over the modified files plus
  `git diff --no-index /dev/null <new-file>` for each new file.
- Build scripts that apply a patch MUST install an `EXIT` trap that
  reverts the submodule. The build script in this repo is the example.
- Patches are **idempotent** — they `apply --check` cleanly against
  the pinned submodule commit, and the trap reverts to that pristine
  state.
- The submodule itself stays at its pinned commit
  (`349a0b9fe63a03ea21198d104e5e9e01e7c068a6`); no commits added to it.
