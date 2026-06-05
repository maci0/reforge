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

## Bottom line / what shipped

- `-Os`: already on the device; **applied to the virt test kernel** so it's representative
  (`7ef917e`). +3 MB free, −983 KB zImage.
- gcc-15 vs gcc-9.5: gcc-15 is ~1 MB heavier at `-O2`, irrelevant under `-Os`.
- LTO: not possible on arm32 / GCC; parked.
- Lean config: **~1.5 MB on the table**, gated on hardware validation (esp. SND). Candidate for a
  future flagged "lean device kernel" once a brick-safe test path (`kexec`/FEL, see
  [2026-06-04-brick-safe-kernel-test-paths.md](2026-06-04-brick-safe-kernel-test-paths.md)) is
  rehearsed.
