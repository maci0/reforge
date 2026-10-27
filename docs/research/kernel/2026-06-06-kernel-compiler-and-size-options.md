# Kernel build options: compiler, `-Os`, LTO, and config-stripping for RAM

**Date:** 2026-06-06
**Status:** snapshot — measured under qemu `-M virt` (gcc-15) and via `size vmlinux` (device config).
**TL;DR:** `-Os` is the only real lever on this 5.4 arm32 kernel and it's already shipping on the
device. gcc-15 codegen is ~1 MB heavier than gcc-9.5 at `-O2` but that's moot once `-Os` is on.
Kernel LTO is unavailable for our arch. Stripping unused built-in subsystems (BT/SND/CAN/…) would
free a further **~1.5 MB**, but it's unvalidated on hardware.

All numbers are the buildroot-integrated Tina BSP 5.4.61 (`vendor/kernels/tina-bsp-kernel`),
built with the buildroot **gcc-15.2** native toolchain unless noted.

---

## 1. Compiler: gcc 9.5 vs gcc 15.2 (qemu virt, `-m 128`)

Same Tina BSP source + virt-class config, both booted `-M virt,highmem=off -cpu cortex-a7 -m 128`
to userspace; numbers from the kernel's own early `Memory:` line. gcc-9.5 = `build-test-kernel.sh`
(multi_v7+virt, `-O2`); gcc-15 = buildroot `make kernel-virt` (`-O2` at the time of this run).

| metric (`-m 128`, 131072K) | gcc 9.5 | gcc 15.2 | Δ |
|---|---|---|---|
| available RAM | 106,364K | 105,360K | **−1,004K (~−1 MB)** |
| kernel code (.text, section-mapped) | 12,288K (12 MB) | 13,312K (13 MB) | **+1,024K** |
| rodata | 5,232K | 5,088K | −144K |
| reserved | 24,708K | 25,712K | +1,004K |
| zImage on disk (compressed) | 9,126,400 B | 9,064,960 B | **−61 KB** |

**Finding:** gcc-15's kernel `.text` is ~1 MB larger than gcc-9.5's at `-O2` (crosses an ARM
1 MB-section boundary, so it shows as a clean +1 MB in `reserved`). Counterintuitively the gcc-15
**zImage is 61 KB smaller** — it compresses better but maps a larger code segment in RAM. Disk
size ≠ memory footprint. The effect is understated here: the gcc-15 virt config had *fewer*
drivers (ATA dropped, see §4) yet still produced bigger `.text` → pure codegen bloat is >1 MB.

This regression is a **non-issue in practice** because the device ships `-Os` (§2).

---

## 2. `-Os` sweep — the one real lever

Available size knobs on 5.4 arm32: `CC_OPTIMIZE_FOR_SIZE` (`-Os`) and `TRIM_UNUSED_KSYMS`.
gc-sections (`LD_DEAD_CODE_DATA_ELIMINATION`) is **not wired for arm32** in this tree
(`HAVE_LD_DEAD_CODE_DATA_ELIMINATION` absent from `arch/arm/Kconfig`). Swept on the virt kernel
(gcc-15), `-m 128`:

| variant | available | kernel code | rodata | zImage |
|---|---|---|---|---|
| `-O2` (baseline) | 105,360K | 13,312K | 5,088K | 9,064,960 |
| **`-Os`** | **108,436K** | **10,240K** | 5,072K | 8,081,920 |
| `-Os` + trim_ksyms | 108,436K | 10,240K | 4,816K | 7,991,808 |
| `-O2` + trim_ksyms | 105,360K | 13,312K | 4,832K | 8,974,848 |

**`-Os`:** kernel code **13,312K → 10,240K (−3 MB)**, free RAM **+3,076K (~+3 MB)**, zImage −983 KB.
Booted clean to userspace, no codegen regression. Recovers the gcc-15 vs gcc-9.5 gap *and* beats
gcc-9.5 by ~2 MB.

**`TRIM_UNUSED_KSYMS`:** shrinks only the ksymtab in rodata (~−256K). Sub-MB, so it doesn't move
the section-mapped free-RAM figure — but it's free.

**Key insight:** the device kernel (`linux.config`) **already ships `-Os`** — FlashForge built it
that way. The `-O2` bloat above was an artifact of the **virt test config**, which inherited
`multi_v7_defconfig`'s `-O2`. Fix applied: `linux-virt.config` set to `-Os` + `TRIM_UNUSED_KSYMS`
so the test kernel matches how the device is actually built (commit `7ef917e`).

`TRIM_UNUSED_KSYMS` is **deliberately left OFF on the device** kernel: it's modular and loads
**out-of-tree** modules (prebuilt zram, `RTL8821CU=m`). trim_ksyms strips exports not referenced by
built-in/in-tree code → would trim a symbol an external module needs → `unknown symbol` at load.
Safe on the monolithic virt kernel only.

---

## 3. Kernel LTO — unavailable for our arch (dead end)

Asked: install Clang + enable `ARCH_SUPPORTS_LTO_CLANG`?

- **GCC kernel LTO never existed mainline.** Out-of-tree Andi Kleen patches only; dead.
- The 5.4 BSP **backported the `LTO_CLANG` Kconfig**, but `config LTO_CLANG depends on
  ARCH_SUPPORTS_LTO_CLANG`, and in this tree only **arm64 and x86_64 select it** — never 32-bit
  arm. Our SoC is **Cortex-A7 = armv7 = 32-bit arm**, so the choice is unreachable.
- `ARCH_SUPPORTS_LTO_CLANG` is a kernel-internal `select`'d symbol, not something you "install."
  Enabling it means **patching `arch/arm/Kconfig`** to claim arm32 supports a Clang-built kernel +
  integrated-assembler + LLD — which mainline arm32 never has (asm/integrated-as gaps), and the BSP
  sunxi/wcn drivers are full of GCC-isms.
- Toolchain is **already present** (`/usr/bin/clang` 22.1.6, `ld.lld`, `llvm-ar`) — not the blocker.
  And clang 22 vs a 2020 5.4 tree (which gates `CLANG_VERSION >= 100000`, i.e. expects clang ~10–11)
  is a fatal version skew on its own.

**Verdict:** LTO stays off. Even if forced, payoff is a few % of `.text` vs the **3 MB** `-Os`
already banks for free. Only opens up on a hypothetical future 64-bit SoC.

---

## 4. Config-stripping the device kernel — predicted ~1.5 MB (UNVALIDATED)

For RAM, only **built-in (`=y`)** options matter — `=m` modules cost nothing until loaded. Audited
`linux.config` for heavyweight `=y` subsystems the AD5M doesn't use, built baseline vs lean device
vmlinux (gcc-15, `-Os` both), compared `size vmlinux`:

| section | baseline | lean | Δ |
|---|---|---|---|
| .text | 7,568,726 | 6,752,724 | −816 KB (−10.8%) |
| .data | 2,838,604 | 2,119,456 | −719 KB (−25.3%) |
| .bss | 186,824 | 177,352 | −9 KB |
| **total** | 10,594,154 | 9,049,532 | **−1,544,622 (−1.54 MB)** |

Lean = dropped `BT` + `CAN` + `PROFILING` + `MAGIC_SYSRQ` + `SOUND`/`SND` + `IPV6` + `KALLSYMS_ALL`
(all confirmed removed by `olddefconfig`). Kernel maps text+data+bss into **reserved RAM**, so this
predicts **~1.5 MB freed** on the 128 MB box (the `Memory: reserved` line would drop by ~that, minus
ARM 1 MB-section rounding).

Likely attribution (not isolated per-option):
- **.data −719 KB** dominated by **`KALLSYMS_ALL`** (drops all *data* symbols from the in-RAM
  symtab — oops still resolves function names, so **safe + free**) + SND tables.
- **.text −816 KB** dominated by **SND/SOUND** + the BT stack.

Risk ranking of the drops:
- **Low risk:** `KALLSYMS_ALL`→`KALLSYMS`, `PROFILING`, `MAGIC_SYSRQ`, `CAN` (MCUs are serial-UART),
  `BT` (no Bluetooth feature; wifi is the separate `rtl8821cu` driver, independent of the BT core).
- **Medium:** `IPV6` (fine if LAN is v4-only; Moonraker/Mainsail work on v4).
- **Verify-first:** `SOUND`/`SND` (24 `=y` sub-options) is the **biggest single win** but only safe
  if the printer beeper is PWM/GPIO, not the SoC audio codec — confirm before dropping.

**Must keep:** MEDIA/V4L2/`USB_VIDEO_CLASS` (the UVC camera is built-in `=y`), `CFG80211`/`WLAN`
(wifi), `THERMAL` (T113 SoC throttle), `WATCHDOG`, `MTD_UBI` (NAND boot partition), `MMC`/`EXT4`.

**Critical caveat:** the device config **cannot boot under qemu `-M virt`** (sunxi platform), so all
of §4 is `size`-predicted only and **unvalidated on hardware**. Any of these drops needs a real
flash-test (risk: no-boot / no-display / no-wifi / no-camera) before shipping. Not applied — measured
on a throwaway `.config`.

---

## 5. Mainline 7.0.11 — what a comparable kernel would weigh, and its size levers

Question: build mainline **7.0.11** with a config comparable to our stock kernel and sweep the size
knobs (including anything the newer gcc/kernel unlocks). Built out-of-tree (`O=`) from
`linux-7.0.11` with the buildroot **gcc-15.2** + binutils **2.44** toolchain. Metric is
`size vmlinux` (text+data+bss = the static RAM the kernel maps into `reserved`); runtime `Memory:`
line shown where the config boots qemu `-M virt`.

### The trap: `multi_v7_defconfig` is the wrong baseline
`multi_v7_defconfig` is a **boot-any-ARMv7-board** config — it enables ~30 *other-vendor* SoC
platforms (`ARCH_BCM`, `EXYNOS`, `OMAP`, `TEGRA`, `QCOM`, `ROCKCHIP`, `STM32`, `AT91`, `ASPEED`, …;
163 `ARCH_*=y` lines) plus all their clk/pinctrl/dma/soc/peripheral drivers. Our stock kernel is
**single-board** (sun8iw20 only). The fair proxy is **`sunxi_defconfig`** (Allwinner-only) — and even
that still covers every Allwinner family (A10…H6), so it's broader than a true T113-only config.

### Results (vmlinux total = text+data+bss)

| 7.0.11 config | total vmlinux | runtime `Memory:` avail (`-m 128`) | note |
|---|---|---|---|
| `multi_v7` -O2 | 29.88M | 96,756K | all-vendor baseline (wrong) |
| `multi_v7` -O2 +gc | 29.46M | — | gc-sections −0.42M |
| `multi_v7` -Os+trim | 26.06M | 99,784K | |
| **`sunxi` -O2** | **13.31M** | (no virt boot) | **−16.5M vs multi_v7** |
| `sunxi` -Os+trim+drops | 10.87M | — | |
| **`sunxi` -Os+gc+trim+drops** | **10.00M** | — | fully tuned |
| *our 5.4 stock device (ref)* | *10.59M* | — | |
| *our 5.4 device lean (ref, §4)* | *9.05M* | — | |

### Lever ranking
1. **Config scope (`multi_v7`→`sunxi`): −16.5 MB.** Dominates everything — that 16 MB is
   other-vendor platform/driver code our single-board stock never carried. Answers the "what else can
   we strip" question: the platforms themselves.
2. **`-Os`: ~−2.5–3 MB.**
3. **lean subsystem drops** (BT/SND/CAN/IPV6/`KALLSYMS_ALL`, as §4): ~−1.5 MB.
4. **gc-sections (`LD_DEAD_CODE_DATA_ELIMINATION`): −0.4 MB (multi_v7) to −0.87 MB (lean sunxi).**
   **New on 7.0 arm32** (`arch/arm/Kconfig` selects `HAVE_LD_DEAD_CODE_DATA_ELIMINATION if
   LD_VERSION >= 23600 || LD_IS_LLD` — our ld 2.44 qualifies; 5.4-arm32 lacked it entirely). Gotcha:
   `depends on EXPERT`, so `scripts/config -e` is silently reverted by `olddefconfig` unless
   `EXPERT=y` is set first. GCC-compatible — this is the arm32 substitute for LTO.

### Stock-equivalent config migrated to 7.0 + all size knobs
Rather than a generic defconfig, take **our actual stock `linux.config`** (the SDK/BSP feature set),
migrate it onto 7.0.11 with `make ARCH=arm olddefconfig`, then flip every size-trimming knob
(`-Os`, gc-sections, `TRIM_UNUSED_KSYMS`) while keeping the stock feature set (no subsystem drops, so
it stays "comparable to stock"). Saved config:
[`configs/2026-06-06-linux-7.0.11-stocklike.config`](configs/2026-06-06-linux-7.0.11-stocklike.config).

| kernel | .text | .data | .bss | total |
|---|---|---|---|---|
| our 5.4 stock device (ref) | 7.57M | 2.84M | 0.19M | **10.59M** |
| 7.0 stocklike A (migrated, `-Os`) | 8.50M | 3.04M | 0.12M | **11.65M** |
| 7.0 stocklike B (+EXPERT+gc+trim) | 7.38M | 2.55M | 0.11M | **10.04M** |

- Size knobs (gc + trim on top of stock's existing `-Os`): **11.65M → 10.04M = −1.61 MB (−14%)**.
- Tuned 7.0 stocklike (**10.04M**) lands **~0.55 MB under our 5.4 stock** (10.59M); its `.text`
  (7.38M) is basically identical to 5.4's (7.57M) despite a 6-years-newer kernel — `TRIM_UNUSED_KSYMS`
  is what pulls `.data` below 5.4. Matches the `sunxi_defconfig`-tuned figure (10.0M).
- **Migration caveat:** `olddefconfig` dropped **167** of our stock `=y` symbols — all BSP-only vendor
  drivers with no mainline name match (`PINCTRL_SUNXI`, `MMC_SUNXI_V4P*`, `SERIAL_SUNXI`,
  `RTC_DRV_SUNXI`, `DISP2_SUNXI`, `SND_SUN8IW20_CODEC`, cedar/VE, …). Mainline equivalents
  (`sun4i/sun6i/sun8i/sun20i-*`) weren't auto-enabled, so stocklike is a **size proxy at the floor**,
  not a bootable T113 kernel. Since the driver-complete `sunxi_defconfig` tunes to ~the same 10.0M,
  the mainline sunxi drivers add little → a *functional* tuned 7.0 T113 kernel ≈ **10–11 MB ≈ our
  5.4 stock**.

### LTO still out, even on 7.0
`ARCH_SUPPORTS_LTO_CLANG` is selected only by **arm64 / x86_64 / riscv / loongarch / um** in 7.0 —
**never 32-bit arm**. clang 22 being contemporary with 7.0 removes the version-skew that also killed
it on 5.4, but the arch gate is unchanged. Full Clang LTO remains unavailable on our Cortex-A7.

### Takeaway
A fully-tuned **7.0.11 sunxi kernel (10.0 MB) reaches size parity with — actually slightly under —
our 5.4 BSP stock (10.6 MB)**, despite being 6 years newer. The "newer = bloated" impression is
entirely a `multi_v7` artifact; scope to one vendor + `-Os` + gc + lean drops and 7.0 is competitive.
Size-only study: `sunxi_defconfig` doesn't boot qemu-virt, and a real T113 boot still needs a board
DTS (see [2026-06-01-t113-mainline-kernel-support.md](2026-06-01-t113-mainline-kernel-support.md)).

### Update 2026-10-27: ported to mainline 7.3

Reran the stocklike migration on **`linux-7.3`** (mainline, released 2026-10-18) and, as the
matched baseline, on `linux-7.0.11` again. The Buildroot toolchain has moved to **gcc 15.3.0 +
binutils 2.45.1** since §5, so the June figures are not a valid baseline on their own. Both
tarballs checked against kernel.org `sha256sums.asc` (HTTPS; PGP signature not checked). Same
steps as §5 (`olddefconfig` from `br-external/board/reforge/linux.config`, `-d DEBUG_INFO_BTF -d
WERROR`, then B adds `EXPERT`, `-Os`, gc-sections, `TRIM_UNUSED_KSYMS`), `size vmlinux`:

| kernel (gcc 15.3 / ld 2.45.1) | .text | .data | .bss | total |
|---|---|---|---|---|
| 7.0.11 stocklike A | 8,497,039 | 3,035,688 | 118,172 | **11,650,899** |
| 7.0.11 stocklike B | 7,383,468 | 2,544,800 | 113,116 | **10,041,384** |
| 7.3 stocklike A | 8,677,990 | 3,251,712 | 107,492 | **12,037,194** |
| 7.3 stocklike B | 7,537,955 | 2,594,360 | 101,092 | **10,233,407** |

- 7.0.11 on the new toolchain reproduces the §5 figures (11.65M / 10.04M), so the toolchain bump
  did not move kernel size.
- **7.3 B = 10.23M: +192 KB (+1.9%) over 7.0.11 B**, still ~0.36 MB under the 5.4 stock
  device kernel (10.59M). A grows more (+386 KB); gc-sections + trim absorb half of it.
- Migration dropped **174** stock `=y` symbols (7.0.11: 167). The 7 extra are upstream Kconfig
  changes, not lost features: `PROC_SYSCTL` folded into `SYSCTL` (still `=y`, `/proc/sys`
  intact); `OABI_COMPAT` now `depends on CPU_SA110 || CPU_SA1100`; `CRYPTO_DRBG_MENU`,
  `CRYPTO_DRBG_HMAC`, `CRYPTO_RNG_DEFAULT` removed (`CRYPTO_DRBG` still `=y`); `MDIO_BUS` and
  `CRYPTO_MICHAEL_MIC` removed as symbols (mac80211 carries Michael MIC in `net/mac80211/wpa.c`).
- Unchanged in 7.3: `HAVE_LD_DEAD_CODE_DATA_ELIMINATION` gate (`arch/arm/Kconfig:128`);
  `ARCH_SUPPORTS_LTO_CLANG` still selected only by arm64, x86, riscv, loongarch, um.
- Same caveat as §5: a size proxy, not a bootable T113 kernel. Saved config:
  [`configs/2026-10-27-linux-7.3-stocklike.config`](configs/2026-10-27-linux-7.3-stocklike.config).

---

## Bottom line / what shipped

- `-Os`: already on the device; **applied to the virt test kernel** so it's representative
  (`7ef917e`). +3 MB free, −983 KB zImage.
- gcc-15 vs gcc-9.5: gcc-15 is ~1 MB heavier at `-O2`, irrelevant under `-Os`.
- LTO: not possible on arm32 / GCC; parked.
- Lean config: **~1.5 MB on the table**, gated on hardware validation (esp. SND). Candidate for a
  future flagged "lean device kernel" once a brick-safe test path (`kexec`/FEL, see
  [2026-06-04-brick-safe-kernel-test-paths.md](2026-06-04-brick-safe-kernel-test-paths.md)) is
  rehearsed.
- Mainline 7.0.11 (§5): a tuned **`sunxi` -Os+gc+trim+drops kernel = 10.0 MB**, ~parity with our 5.4
  stock. Biggest lever by far is **config scope** (`multi_v7`→`sunxi` = −16.5 MB), not opt flags.
  gc-sections is new+usable on 7.0 arm32 (−0.4–0.9 MB); Clang LTO still arm32-unsupported. Confirms
  a future 6.x/7.x move (Plan 5) is size-viable on the 128 MB box.
