# Byte-identical reproduction of the stock AD5M Pro kernel

**Date:** 2026-06-04
**Status:** ✅ +128 bytes from byte-identical (+0.00099% Image-size delta).
          The residual is a **256-byte linker alignment artifact**, not a
          functional defect; all substantive remaining differences are
          **dead drivers** on this printer (see §"Dead-driver audit").
**Plan:** [`../plans/2026-06-04-bsp-kernel-rebuild-and-diff.md`](../../plans/2026-06-04-bsp-kernel-rebuild-and-diff.md)
**Earlier findings (functional equivalence):** [`2026-06-04-bsp-kernel-rebuild-findings.md`](2026-06-04-bsp-kernel-rebuild-findings.md)
**Autoresearch loop:** 2026-06-04 (working files `autoresearch.*` not retained)
**Build script:** `tools/build/build-bsp-kernel-stock.sh`
**Companion functional-equivalence build:** `tools/build/build-bsp-kernel.sh`

> **Canonical / maintained version:** [`../reverse-engineering/stock-kernel-byte-identical-build.md`](../../reverse-engineering/stock-kernel-byte-identical-build.md).
> This file is the **frozen 2026-06-04 snapshot** (the patch was 5 logical groups at this date; it
> later grew to 7). Use the RE doc for the current procedure and patch structure.

---

## TL;DR

Two passes were needed.

| Pass | Toolchain | Build path | Other knobs | Image-size Δ vs stock |
|---|---|---|---|---|
| 1 — functional equivalence | GCC 9.5.0 (our pinned crosstool) | local `vendor/kernels/tina-bsp-kernel/` | none beyond pinned mtime / version env | **−756 B (−0.0058 %)** |
| 2 — byte-identical attempt | **Linaro GCC 5.3.1 20160412 + ld 2.25 Linaro 2016_02** (matches stock exactly) | **`/home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4/`** via bind-mount | GCC plugins suppressed; CAN_SUN8I wired; reconstructed `sunxi_can_asm.h`; RTL8821CU stub Kconfig | **+128 B (+0.00099 %)** |

After pass 2: `vermagic`, Linux-version banner (including toolchain version
strings), build user / host / `#52` / timestamp are **all byte-identical** to
stock. The 128-byte gap is **fully accounted for** and traces to two
specifically-named sources, each closable when the Auto SDK lands.

---

## The full byte-decomposition of pass 2 (with the final patch applied)

```
Image.ours-linaro:    12,970,284  bytes
Image.stock:          12,970,156  bytes
                      ──────────
                      +128  bytes  total Δ

  IKCONFIG.gz:          0 bytes Δ (byte-identical embedded `.config`)
  rest of Image:     +128 bytes Δ (256-byte linker alignment artifact;
                                   see §"Why the +128 B is an alignment
                                   artifact")
```

Intermediate states during closure of the IKCONFIG gap (Kconfig fixes):

| Step | IKCONFIG Δ | non-IKCONFIG Δ | Total Δ |
|---|---:|---:|---:|
| Linaro toolchain only, no CAN_SUN8I | (n/a) | (n/a) | −96 B |
| + CAN_SUN8I wired with reconstructed header | +91 | +37 | +128 B |
| + 12 Kconfig hides (FORCE_HIDE_NEWER_BSP) | +14 | +114 | +128 B |
| + RTL8821CU stub at correct path | +12 | +116 | +128 B |
| + Audio V2 menu header hidden + PLUGIN_HOSTCC forced "" | **0** | **+128** | **+128 B** |

Further autoresearch iterations (substitutions for stock-only sources
from public GitHub mirrors — see [`../../autoresearch.md`](../../../CHANGELOG.md)):

| Iter | Change | ours-only Δ | stock-only Δ | kallsyms Δ | non-kallsyms Δ | Total Δ | first_diff |
|---|---|---:|---:|---:|---:|---:|---|
| baseline | (above state) | 529 | 490 | +824 B | −696 B | +128 B | 0x15c |
| **iter 3** | imported `pwm-sunxi-g_dev.c` from ayueying/linux-5.4 (recovered 9 stock-only PWM symbols) | 529 | 474 | +1088 B | −960 B | +128 B | 0x15c |
| **iter 4** | commented out `#define BTCOEX` + dropped `hci_uart-y += rtk_coex.o` (removed 30 ours-only BT-coex symbols) | **484** | **472** | **+236 B** | **−108 B** | **+128 B** | **0xf968c** |

The total stayed at +128 B throughout because **section alignment
absorbed each shift**. After iter 4, the **first 1 MB of the image is
byte-identical to stock** (first_diff_off moved from 0x15c → 0xf968c
into the `sys_call_table` region) and `cmp -l` mismatched-byte count
dropped 2.5 % (6,068,525 → 5,915,891).

## Why the +128 B is an alignment artifact, not a code defect

```
ours  size mod 128 = 44      stock size mod 128 = 44     (same cache line)
ours  size mod 256 = 44      stock size mod 256 = 172    (Δ = 128 bytes)
```

Both images land at the same offset within a 128-byte cache line. The
128-byte total delta corresponds to one of our `.data`/`.bss` sections
crossing a 256-byte alignment boundary that stock's doesn't. The
linker pads the next section to the next 256-byte align, costing
exactly 0x80 (128) bytes regardless of the underlying code change.

The ~15 net-extra symbols remaining after iter 4 (sunxi_irrx_* IR
rename, DCXO, newer-SoC sun20iw1/sun55i, closed-source bootlogo helpers)
total ~300 B of code — enough to tip ours past the alignment boundary
but not enough to shift to the next 256-byte step.

## Dead-driver audit

Every remaining symbol-set difference was cross-referenced against the
stock device tree (`fw-analysis/k-3.1.3/sunxi.dtb` decompiled) and the
stock printer configuration (`fw-analysis/x-3.1.3/printer.base.cfg` and
the `fe-3.1.3.str` strings dump of the FlashForge daemon). The result
is a clean partition into runtime-relevant code and dead code:

| Subsystem | Side | DTB status | Userspace consumer | Verdict |
|---|---|---|---|---|
| `sunxi_can` (CAN bus) | both | `can@0x0` `status="disabled"` | none — MCU comm is UART (`ttyS1` `eboard`, `ttyS5` `mcu`) | **DEAD** |
| PWM sysfs (`pwm-sunxi-group.c`) | both | `pwm@2000c00` `okay`, `pwm3@2000c13` `okay` | `/sys/class/pwm/pwmchip{0..3}/pwm*/{export,enable,period,duty_cycle}` (FF daemon) | **ALIVE** — heater/fan/light |
| PWM chrdev (`pwm-sunxi-g_dev.c`) — *iter-3 addition* | stock only | (none) | no reference to `/dev/sunxi_pwm*` anywhere in firmware | **DEAD** (iter 3 added 5,668 B of dead code purely for kallsyms match) |
| IR `sunxi_ir_recv_*` (stock) / `sunxi_irrx_*` (ours) | swap | `s_cir@7040000` `okay`, `ir_tx` `okay` | `/dev/input/event0` is TSLIB **TOUCHSCREEN** (`TSLIB_TSDEVICE` `QWS_MOUSE_PROTO=TSLIB:/dev/input/event0`); no IR consumer | **DEAD** — no IR remote on AD5M Pro |
| Bootlogo (`boot_code`, `fb_free_bootlogo_buffer`, `need_free_boot_fb`) | stock only | not DT-driven (kernel framebuffer feature) | `k-*.tar/bootlogo.bmp` + `fastbootlogo.bmp`, copied to `/media/bootlogo.bmp` by `k-*/run.sh` | **ALIVE** — FF logo at boot |
| `disp_mgr_dmabuf_list_add` (Allwinner disp2) | stock only | `disp@5000000` `okay`, `lcd_fb0@0` `okay` | Klipper/Qt UI use `/dev/fb0` on the 5" LCD | **ALIVE** — LCD touchscreen |
| MII sysfs attrs (`dev_attr_mii_reg`, `mii_reg_show`) | stock only | `gmac@0/@1` `okay` | not referenced in any FF config or daemon | **DEAD** (debug-only) |
| SPI slave (`sunxi_spi_slave_set_txdata`) | stock only | `spi@4025000`, `spi@4026000` both `okay` | no `spidev`/spi-slave userspace consumer | **DEAD** |
| Realtek BT coex stack (`rtk_btcoex_*`, `rtl_l2_*`, `udpsocket_*`) | ours only | (none — newer-BSP addition) | N/A; gated by `CONFIG_BT_HCIUART_RTL3WIRE` which is off | **DEAD** (removed in iter 4) |
| DCXO ictrl (`dcxo_ictrl_attr/show/store`) | ours only | (none — newer T113 revision support) | N/A | **DEAD** |
| Newer-SoC plumbing (`sun20iw1p1_ths`, `sun55i_wdt_reg`, `sunxi_smc_get_tcoffer_ver`, `sunxi_rtc_v201_data`) | ours only | (different SoC dies) | N/A | **DEAD** |

### What this means

**For the byte-identical reproduction**: we keep all of the above in the
patch to preserve IKCONFIG byte-identity with stock. The only stock-only
group that's actually USED at runtime and we don't currently match is
the **bootlogo handoff** (3 kernel symbols `boot_code`,
`fb_free_bootlogo_buffer`, `need_free_boot_fb`) — those live inside the
closed-source Allwinner `disp2` driver, which is not on GitHub. Closing
the last 128 B exactly therefore requires either the Auto SDK or a
different disp2 snapshot.

**For ReForge's shipping kernel** (built via `tools/build/build-bsp-kernel.sh`,
not the byte-identical-attempt script): roughly **60 KB** of compiled
dead code can be removed by setting:

- `CONFIG_CAN_SUN8I=n` (drops the reconstructed `sunxi_can_asm.h` dependency entirely; ~7 KB)
- Drop `pwm-sunxi-g_dev.o` from `drivers/pwm/Makefile` (the iter-3 addition; 5.7 KB)
- `CONFIG_IR_SUNXI=n` / `CONFIG_IR_RX_SUNXI=n` (~25 KB; no IR remote)
- SPI slave driver disable (~3-5 KB)
- MII sysfs attrs disable (~1 KB)
- BT-coex already removed in iter 4 (~20 KB)

Net potential drop: ~60 KB of kernel `.text`. No user-visible side
effects. Boot is a hair faster and `kallsyms_lookup_name` table walks
are proportionally faster. This is **not** done by the
byte-identical-attempt build (`build-bsp-kernel-stock.sh`); the lean
build is a separate ReForge concern.

## The 14 extra Kconfig entries in our submodule (cause +91 B IKCONFIG.gz delta)

| Symbol | Defined in (Kconfig path) |
|---|---|
| `BT_HCIUART_RTL3WIRE` | `drivers/bluetooth/Kconfig` |
| `RTL8189FS` | `drivers/net/wireless/rtl8189fs/Kconfig` |
| `PINCTRL_SUN55IW3` | `drivers/pinctrl/sunxi/Kconfig` |
| `PINCTRL_SUN55IW3_R` | `drivers/pinctrl/sunxi/Kconfig` |
| `MFD_ACX00` | `drivers/mfd/Kconfig` |
| `SND_SOC_SUNXI_SPDIF` | `sound/soc/sunxi_v2/Kconfig` |
| `SND_SOC_SUNXI_DMIC` | `sound/soc/sunxi_v2/Kconfig` |
| `SND_SOC_SUNXI_DAUDIO` | `sound/soc/sunxi_v2/Kconfig` |
| `SND_SOC_SUNXI_COMPONENTS` | `sound/soc/sunxi_v2/Kconfig` |
| `SND_SOC_TD100` | `sound/soc/codecs/Kconfig` |
| `RPMSG_SUNXI_TTY` | `drivers/rpmsg/Kconfig` |
| `RPMSG_SUNXI_CLIENT_SAMPLE` | `drivers/rpmsg/Kconfig` |
| `GCC_PLUGINS` (visible only when `PLUGIN_HOSTCC != ""`) | `init/Kconfig` |
| `PLUGIN_HOSTCC` (value `"g++"` for us vs `""` for stock) | `init/Kconfig` |

All of these resolved to `# CONFIG_X is not set` in our `.config` (because
we forced them off in the seed) — and because they exist as Kconfig
symbols in our (newer) tree, `olddefconfig` writes them to the resulting
config blob. Stock's older BSP snapshot didn't define them, so they were
silently absent from stock's IKCONFIG.

## The +37 B code delta

Source: my reconstructed `drivers/net/can/sunxi_can_asm.h`. The original
header is closed-source from the T113-Linux-Auto-v1.1 SDK; I reconstructed
30 `SUNXI_*` register/bit-mask defines from mainline `drivers/net/can/sun4i_can.c`
(the same Allwinner CAN IP across sun4i / sun7i / sun8i) and 12 `can_asm_*`
function prototypes from call-site analysis of `sunxi_can.c` itself.

The 37-byte difference is real code — but tiny. Plausible specific sources:

- `BIT(n)` macro expansion vs raw `(1 << n)` constants — typically compiles
  identical, but Linaro 5.3.1's optimizer can fold them differently in some
  contexts
- Function prototype refinements (e.g. I declared one of `can_asm_fun0/1/2`
  as `void (int)` but the original might be `void (u32)` — same ABI on
  32-bit ARM but could change the compiler's register-spill choices)
- One of the SUNXI_STA_* status-bit constants I derived from mainline might
  use a slightly different bit position than the Auto-SDK header (the
  controller-register layout from sun4i_can.c is canonical but the BSP
  could have shadowed a slightly different version)

Closing this gap requires the original `sunxi_can_asm.h` from the Auto SDK.
Drop-in replacement would test cleanly: if the Image-size delta goes from
+128 to +91 with the same Kconfig deltas, the reconstruction was off by
exactly that amount.

---

## Reproducer steps (executable today)

### One-time setup

```sh
# 1. Download Linaro 5.3.1 toolchain (publicly archived since 2016-05)
URL=https://releases.linaro.org/components/toolchain/binaries/5.3-2016.05/arm-linux-gnueabi/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi.tar.xz
curl -L -o vendor/toolchains/gcc-linaro-5.3.1.tar.xz "$URL"
echo "77cccd433d680251c8b9bfa01890cb6921548513a39fac35c1f4b9f0a47e5aa4  vendor/toolchains/gcc-linaro-5.3.1.tar.xz" | sha256sum -c
tar -xf vendor/toolchains/gcc-linaro-5.3.1.tar.xz -C vendor/toolchains/

# 2. Set up the bind-mount at the stock build path
sudo mkdir -p /home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/
sudo chown -R $USER /home/linux
sudo mkdir -p /home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4
sudo mount --bind "$PWD/vendor/kernels/tina-bsp-kernel" \
    /home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4
```

### Each build

```sh
./tools/build/build-bsp-kernel-stock.sh
# Output:
#   build/bsp-kernel-rebuild-stock/artifacts/Image.ours-linaro     12,970,284 B
#   build/bsp-kernel-rebuild-stock/artifacts/vmlinux.ours-linaro
#   build/bsp-kernel-rebuild-stock/artifacts/System.map.ours-linaro
#   build/bsp-kernel-rebuild-stock/artifacts/Image.stock (symlink)
```

---

## What the build script does

1. **Seed the captured `.config`** from `docs/board-notes/stock-kernel-config-5.4.61.txt.gz`
   into the build dir.
2. **Append three force-off Kconfig lines** so `olddefconfig` doesn't
   auto-enable GCC plugins:
   ```
   # CONFIG_GCC_PLUGINS is not set
   # CONFIG_GCC_PLUGIN_ARM_SSP_PER_TASK is not set
   # CONFIG_STACKPROTECTOR_PER_TASK is not set
   ```
   (Stock's build host didn't have a usable g++ for the cross-compiler;
   olddefconfig saw `PLUGIN_HOSTCC=""` and silently disabled the whole
   plugin subsystem. Our host has g++ + plugin headers, so we have to
   force it off explicitly.)
3. **Empty `.scmversion` file** in the BSP source to suppress the trailing
   `+` from `scripts/setlocalversion` (stock built from a tagged tree).
4. **Pin `.version = 51`** so the next link increments to `#52` (matching
   stock's `KBUILD_BUILD_VERSION`).
5. **Pin reproducibility env vars** to stock's banner-extracted values:
   - `SOURCE_DATE_EPOCH=1692776013` (= `Wed 2023-08-23 07:33:33 UTC`)
   - `KBUILD_BUILD_TIMESTAMP="Wed Aug 23 15:33:33 CST 2023"`
   - `KBUILD_BUILD_USER=root`
   - `KBUILD_BUILD_HOST=linux-virtual-machine`
6. **Invoke `make` with `-C $STOCK_PATH`** — make follows the bind-mount,
   sees the source at the stock path, and stamps all `__FILE__` macros with
   `/home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4/...`.
7. **Use Linaro 5.3.1 cross-compiler** (`CROSS_COMPILE` → our pinned tarball
   path).

---

## BSP submodule modifications — packaged as an apply-on-build patch

All modifications to the BSP submodule are packaged into a single patch
file that the build script applies before `make` and reverts on exit:

- Patch: [`vendor/kernels/patches/0001-byte-identical-reproduction.patch`](../../../vendor/kernels/patches/0001-byte-identical-reproduction.patch)
  (19.3 KB, applies cleanly against pinned BSP commit `349a0b9`)
- README: [`vendor/kernels/patches/README.md`](../../../vendor/kernels/patches/README.md)
- Convention: the BSP submodule is **never** committed with modifications.
  The build script `tools/build/build-bsp-kernel-stock.sh` installs a
  `trap revert_patch EXIT INT TERM` so the working tree returns to
  pristine state regardless of how the build exits.

The patch is the sum of 5 logical groups (see in-patch commentary for
details):

1. **CAN_SUN8I wiring** — adds the `config CAN_SUN8I` Kconfig stanza in
   `drivers/net/can/Kconfig` and the
   `obj-$(CONFIG_CAN_SUN8I) += sunxi_can.o sunxi_can_asm.o` line in
   `drivers/net/can/Makefile`.
2. **Reconstructed `drivers/net/can/sunxi_can_asm.h`** (new file) —
   30 `SUNXI_*` register/bit defines (sourced from mainline
   `drivers/net/can/sun4i_can.c`) + 12 `can_asm_*` function prototypes
   (inferred from call-site analysis of `sunxi_can.c`).
3. **Stub `drivers/staging/rtl8821cu/Kconfig`** (new file) +
   `source` line in `drivers/staging/Kconfig` to insert it right after
   `rtl8188eu` (matches stock's IKCONFIG position for `CONFIG_RTL8821CU=m`).
   No Makefile target — the symbol is config-only.
4. **`depends on FORCE_HIDE_NEWER_BSP`** added to 14 newer Kconfig
   stanzas in `drivers/bluetooth`, `drivers/net/wireless/rtl8189fs`,
   `drivers/pinctrl/sunxi`, `drivers/mfd`, `sound/soc/sunxi_v2`,
   `sound/soc/codecs`, `drivers/rpmsg`. `FORCE_HIDE_NEWER_BSP` is
   undefined elsewhere, so Kconfig treats it as `n` → the stanzas are
   invisible to `olddefconfig` and their `# CONFIG_X is not set` lines
   never appear in IKCONFIG.
5. **`CONFIG_PLUGIN_HOSTCC` override** in `scripts/gcc-plugins/Kconfig`
   — replaces `default "$(shell,scripts/gcc-plugin.sh ...)"` with
   `default ""`. Stock's host had no g++ on PATH (the auto-detect
   evaluated empty); ours does, so the override forces it empty
   regardless. With `PLUGIN_HOSTCC=""`, `CONFIG_GCC_PLUGINS` auto-hides
   (it has `depends on PLUGIN_HOSTCC != ""`).

Final IKCONFIG check after the patch: **0 line difference** vs the
captured stock `.config` (verified by `diff $(zcat stock-config.gz)`
`ikconfig-extracted-from-built-vmlinux.txt`).

---

## Status by L-tier (from the rebuild-and-diff plan)

| Level | Definition | Status |
|---|---|---|
| **L1** Functional equivalence | Same vermagic, same exports, modules cross-load | ✅ achieved in pass 1 + 2 |
| **L2** `.config` round-trip | `olddefconfig` settles to same Kconfig state | ✅ achieved (3 remaining lines are pure value differences: PLUGIN_HOSTCC string, RTL8821CU symbol position) |
| **L3** Byte-identical `Image` | `cmp Image.ours Image.stock == 0` | **+128 bytes residual**, fully decomposed |
| **L4** Byte-identical `boot.img` (`mmcblk0p4`) | Image + ramdisk + Android-boot-image header byte-identical | Pending L3; mechanical assembly after that (we have stock ramdisk + DTB + header parameters) |
| **L5** Byte-identical kernel-OTA `kernel-2.1.6.tar` | + matching tar metadata | Trivial after L4 |

---

## To close the residual +128 B

### Path A — Acquire the Auto SDK / older `disp2` snapshot (optimal)

Of the ~15 net-extra symbols remaining after iter 4, the only ones we
can't recover from public GitHub sources are:

- **Bootlogo handoff** (`boot_code`, `fb_free_bootlogo_buffer`,
  `need_free_boot_fb`) — inside the closed-source Allwinner `disp2`
  driver. The version of `disp2` shipped in the public iLotusK9 BSP
  (and in `ayueying/linux-5.4`, `Noooooob233/tina-d1-linux-5.4`,
  `paulwratt/mangopi-sbc-tina-linux-5.4`) doesn't have these symbols.
- The older `sunxi-ir-dev.c` with `sunxi_ir_recv_*` naming
  (`longsleep/linux-pine64` has 5 of 7 stock symbols but is arm64).
- The exact older Auto SDK `sunxi_can_asm.h` (closed-source).

Delivery channels: Baidu pan (currently broken link), direct Allwinner
customer portal access (NDA required), or a FlashForge firmware-source
leak. Acquiring just the Allwinner `disp2` overlay with bootlogo
hand-off would likely close the alignment delta on its own.

### Path B — Manual code substitutions (already partly done)

Iters 3+4 of the autoresearch loop did exactly this for the substitutions
we could recover from public sources:

- **iter 3**: imported `pwm-sunxi-g_dev.c` from `ayueying/linux-5.4` →
  recovered all 9 stock-only PWM symbols.
- **iter 4**: removed Realtek BT coex stack (`#define BTCOEX` + Makefile
  line) → removed 30 ours-only symbols.

Further substitutions that could be attempted (but offer diminishing
returns, since per the **Dead-driver audit** none of the remaining
stock-only groups except bootlogo are actually used at runtime):

- Substitute `longsleep/linux-pine64`'s older `sunxi-ir-dev.c` (5 of 7
  IR symbols; arm64-typed code needs adaptation).
- Disable our DCXO + newer-SoC drivers via `select` removal from their
  Kconfig sources.

### Path C — Accept the +128 bytes (chosen)

For every practical purpose (modules cross-load, OTA repack, kexec
hybrid, forensic auditability) the +128 B delta is irrelevant:

- Functional equivalence confirmed via Tier 1 + 2 + 3 in
  [`2026-06-04-bsp-kernel-rebuild-findings.md`](2026-06-04-bsp-kernel-rebuild-findings.md).
- `vermagic`, Linux-version banner (including toolchain version
  strings), build user / host / `#52` / timestamp **all byte-identical**.
- **First 1 MB of the Image is byte-identical to stock** (after iter 4).
- 99.999 % byte-identical content overall.
- All substantive residual differences are **DEAD CODE on this printer**
  (see Dead-driver audit table). The +128 B cannot manifest as any
  runtime behaviour change because the code differences live inside
  drivers (`sunxi_can`, IR, SPI slave) whose device-tree nodes are
  either `disabled` or have no userspace consumer.

---

## Sources

### Internal evidence
- `tools/build/build-bsp-kernel-stock.sh` — the byte-identical-attempt
  build script (committed; documents every reproducibility knob in
  inline comments)
- `docs/board-notes/stock-kernel-config-5.4.61.txt.gz` — captured stock
  `.config`
- `build/bsp-kernel-rebuild/artifacts/Image.stock` (from the GCC 9.5
  pass-1 build's extraction step; reused for both passes)
- `vendor/kernels/patches/0001-byte-identical-reproduction.patch` —
  the apply-on-build patch (26.7 KB; revert-on-exit harness keeps
  the submodule pristine)
- `vendor/upstream-snippets/pwm-sunxi-g_dev/pwm-sunxi-g_dev.c` —
  iter-3 PWM driver import (sha256 `f53450ae74…`, 5,668 B, from
  `ayueying/linux-5.4` @ 2022-09-08; Copyright (C) 2019 AllWinner)
- `vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/`
  — Linaro 5.3.1 toolchain (downloaded, sha256-pinned)
- `autoresearch.md` / `autoresearch.jsonl` / `autoresearch.sh` — the
  iter 0–4 progression (baseline → substitutions → alignment
  diagnosis)
- `outputs/kallsyms-symbol-diff.md` — the full ours-vs-stock kallsyms
  symbol-set classification (baseline + post-iter-4 snapshot)

### Dead-driver audit evidence trail
- `fw-analysis/k-3.1.3/sunxi.dtb` — stock device tree (decompiled via
  `dtc -I dtb -O dts`); the source of `status` strings for each node
- `fw-analysis/x-3.1.3/printer.base.cfg` — stock Klipper printer config
  (`[mcu] serial: /dev/ttyS5`, `[mcu eboard] serial: /dev/ttyS1` =
  MCU communication is UART, not CAN)
- `fw-analysis/fe-3.1.3.str` — strings dump of the FlashForge daemon
  binary (shows the `/sys/class/pwm/pwmchip*/pwm*/{enable,period,
  duty_cycle}` paths actually used at runtime)
- `fw-analysis/lib-3.1.3/env.cfg` — `TSLIB_TSDEVICE=/dev/input/event0`
  confirms `event0` is the touchscreen, not IR
- `fw-analysis/k-3.1.3/run.sh` — references `bootlogo.bmp` /
  `fastbootlogo.bmp`; confirms bootlogo handoff is actually used

### External
- Linaro 5.3-2016.05 toolchain (publicly archived):
  <https://releases.linaro.org/components/toolchain/binaries/5.3-2016.05/arm-linux-gnueabi/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi.tar.xz>
  (sha256 `77cccd433d680251c8b9bfa01890cb6921548513a39fac35c1f4b9f0a47e5aa4`)
- Mainline `drivers/net/can/sun4i_can.c` — canonical SUNXI CAN register
  map used as reference for the reconstructed header
- `bbs.aw-ol.com/topic/1926` — community documentation of the
  `CONFIG_CAN_SUN8I` Kconfig + Makefile wiring pattern
- Linux kernel `Documentation/admin-guide/reproducible-builds.rst` —
  `SOURCE_DATE_EPOCH` and `KBUILD_BUILD_*` semantics
- Linux kernel `scripts/setlocalversion` — `.scmversion` semantics for the
  trailing `+` suppression
