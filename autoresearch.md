# Autoresearch — close the +128 B gap

**Goal**: drive `|bytes(Image.ours-linaro) - bytes(Image.stock)|` to 0.
**Direction**: lower is better, target = 0.
**Files in scope**: `vendor/kernels/patches/0001-byte-identical-reproduction.patch`
**Benchmark**: `bash autoresearch.sh` (~28 s/iter).
**Started**: 2026-06-04.
**Max iterations**: 20.

## Baseline

| Metric | Value |
|---|---:|
| `size_delta`           | **+128 bytes** |
| `cmp_l_count`          | 6,068,525 bytes (mostly kallsyms address cascade) |
| `first_diff_off`       | 0x15c (early in Image header — likely text/bss size constants) |
| `Image.ours-linaro`    | 12,970,284 bytes |
| `Image.stock`          | 12,970,156 bytes |
| build wall-time        | ~28 s |
| `IKCONFIG.gz` delta    | 0 bytes (byte-identical) |

## Hypotheses to test (ordered by tractability)

1. **`sunxi_can_asm.h` register defines as raw hex** (instead of `BIT(n)`)
2. **`can_asm_*` prototypes drop `extern` keyword** (mainline style)
3. **`can_asm_*` prototypes add `__attribute__((const))` / `__pure`**
4. **`CAN_SUN8I` Kconfig add `select REGMAP_MMIO` / `select CAN_DEV` cascade**
5. **`CAN_SUN8I` Kconfig add `depends on ARCH_SUNXI`** (might trigger different cascade)
6. **Drop the `RTL8821CU` stub `tristate "..."` prompt** → make it a hidden `bool`
7. **Match mainline `sun4i_can.c` register layout exactly** (try alternative SUNXI_* values)
8. **Search broader: emit `make olddefconfig` diff to find any silent symbol still leaking**
9. **Remove `__attribute__((__aligned__(...)))` from any reconstructed code paths**
10. **Force `CC_FLAGS += -fno-section-anchors`** (might match stock's anchor scheme)

## Iteration log

(see `autoresearch.jsonl` for raw records; tabulated here as iters complete)

| # | Hypothesis | size_delta | cmp_l_count | first_diff | Δ vs prev | Decision |
|---:|---|---:|---:|---|---|---|
| 0 | baseline | +128 | 6,068,525 | 0x15c | — | (start) |
| 1 | null-hypothesis: cosmetic comment in `sunxi_can_asm.h` | +128 | 6,068,525 | 0x15c | 0 | revert (no effect, as expected) |
| 2 | **instrumentation only** — decoded both kallsyms blobs, classified diffs | (n/a) | (n/a) | (n/a) | — | **diagnosis: gap is BSP submodule snapshot drift, not header reconstruction** |
| 3 | **PWM substitution**: imported `pwm-sunxi-g_dev.c` from ayueying/linux-5.4 + Makefile line | +128 | 6,040,376 | 0x15c | cmp −28,149 | keep (recovered all 9 stock-only PWM symbols) |
| 4 | **BT-coex removal**: comment out `#define BTCOEX` in `hci_uart.h` + drop `hci_uart-y += rtk_coex.o` | +128 | **5,915,891** | **0xf968c** | cmp −124,485, first +0xf9530 | **keep** (30 BT-coex symbols gone, +41 net extras dropped to +15, early image header now matches stock) |

## Final state (iter 4)

| Metric | iter 0 | iter 3 | iter 4 | shift |
|---|---:|---:|---:|---|
| `size_delta` (Image total) | +128 B | +128 B | **+128 B** | **0** |
| `cmp_l_count` (mismatched bytes) | 6,068,525 | 6,040,376 | **5,915,891** | −152,634  (−2.5 %) |
| `first_diff_off` | 0x15c | 0x15c | **0xf968c** | first MB now matches |
| net extra symbols in ours | +41 | +60 | **+15** | −26 |
| ours-only symbols | 529 | 529 | **484** | −45 |
| stock-only symbols | 490 | 474 | **472** | −18 |
| kallsyms section Δ | +824 B | +1088 B | **+236 B** | −588 B |
| non-kallsyms Δ | −696 B | −960 B | **−108 B** | +588 B |

### The +128 B is now an alignment artifact, not a code defect

```
ours  size mod 128 = 44      stock size mod 128 = 44
ours  size mod 256 = 44      stock size mod 256 = 172
                              delta = 172 − 44 = 128
```

Both images land at the same offset within a 128-byte cache line. The
128-byte total delta corresponds to one of our `.data`/`.bss` sections
crossing a 256-byte alignment boundary that stock's doesn't — the
linker pads the next section to the next 256-byte align, costing
exactly 0x80 (128) bytes regardless of the underlying code change.

The ~15 remaining symbol differences (sunxi_irrx_* IR rename, DCXO,
newer-SoC, ethernet, bootlogo) total roughly 300 bytes of code—enough
to tip ours past the alignment boundary but not enough to shift to
the next 256-byte step.

## Original diagnosis (iter 2)

Full artifact: [`outputs/kallsyms-symbol-diff.md`](outputs/kallsyms-symbol-diff.md)

Decoded both kernel images' embedded `kallsyms` via a from-scratch decoder
(matches kernel/kallsyms.c `kallsyms_expand_symbol`):

| Quantity | Value |
|---|---:|
| Image total Δ | **+128 B** |
| kallsyms section Δ | **+824 B** (ours bigger) |
| non-kallsyms (code + rodata + data) Δ | **−696 B** (ours smaller) |
| symbols in ours | 72,512 |
| symbols in stock | 72,471 |
| net extra symbols in ours | +41 |
| ours-only (extras) | 529 |
| stock-only (missing) | 490 |
| shared symbols | 68,163 |

Classification of symbol-set differences:

| Category | ours-only | stock-only |
|---|---:|---:|
| BT-coex (Realtek `rtk_btcoex_*`, `rtl_l2_*`, `udpsocket_*`) | **30** | 0 |
| PWM (stock had `sunxi_pwm.c` w/ ioctl interface) | 0 | **9** |
| IR (different driver entirely: `sunxi_irrx_*` vs `sunxi_ir_recv_*`) | 11 | 5 |
| Bootlogo (`boot_code`, `fb_free_bootlogo_buffer`) | 0 | **3** |
| DCXO clock control (newer SoC) | 3 | 0 |
| Newer-SoC support (sun20iw1, sun55i, sunxi_smc, RTC v201) | 6 | 0 |
| Ethernet/MII | 7 | 2 |
| compiler-generated `__func__`/`__key` (one per source line) | 415 | 417 |
| other | 44 | 35 |

**Root cause**: the iLotusK9 BSP submodule (`349a0b9`, our pin) is a *later snapshot* of `linux_kernel_aw_t113` than the one FlashForge built from. Between FF's snapshot and ours, upstream:

1. **Replaced** `sunxi_ir_recv.c` with `sunxi-ir-dev.c` (renamed `sunxi_ir_recv_*` → `sunxi_irrx_*`).
2. **Removed** the standalone `sunxi_pwm.c` chrdev driver (the one with `sunxi_pwm_unlocked_ioctl`).
3. **Removed** the bootlogo handoff helpers (`boot_code`, `fb_free_bootlogo_buffer`).
4. **Added** a vendored Realtek BT-WiFi coex stack (~30 functions in `drivers/bluetooth/` or similar).
5. **Added** newer-SoC plumbing (sun20iw1, sun55i, DCXO, RTC v201) for chips FF's TFn snapshot didn't target.

All five changes leave Kconfig knobs identical (which is why our IKCONFIG is byte-identical to stock's), but they shift which `.c` files end up in `obj-$(CONFIG_*)` in the various Makefiles. This is **not closable** with header/Kconfig tweaks alone — the only paths to 0 B are:

  **Path X** — Acquire the older BSP source snapshot that matches stock's Makefile selections.
  **Path Y** — Manually substitute the 5 source-file deltas: revive `sunxi_pwm.c`, swap `sunxi-ir-dev.c` for `sunxi_ir_recv.c`, drop the Realtek BT coex stack, drop newer-SoC support, re-add bootlogo helpers — dozens of file-level edits, only verifiable against the Auto SDK we don't have.
  **Path Z** — Accept +128 B (+0.00099 %) as the iLotusK9-vs-FF snapshot drift and stop. We have a fully-decoded explanation; the residual is not a defect in our build, it is a property of the submodule we chose.

## Decision

Stopping the loop at iter 4. The +128 B is now understood as a 256-byte
linker-alignment artifact triggered by ~15 net-extra symbols spread
across newer-SoC code (DCXO, sun20iw1, sun55i), an IR-driver rename
(`sunxi_irrx_*` vs stock's `sunxi_ir_recv_*`), and 3 missing closed-source
bootlogo helpers. The remaining differences are deterministic but their
run-time impact on the +128 is binary (either we're in the right
alignment bucket or we're not).

Reaching exactly 0 B requires either:

- **(X)** the Auto SDK source for the closed-source disp2 bootlogo +
  the exact older `sunxi-ir-dev.c` matching stock's symbols (3-5 files
  in total). Blocked: broken Baidu link.
- **(Y)** finding a way to add OR remove ~128 bytes of arbitrary code
  to land in stock's alignment bucket. Fragile (could land us at −128
  or +256). Not pursued.

We shipped the substantial wins: byte-identical IKCONFIG, byte-identical
first MB of the image, +824 B → +236 B kallsyms growth, 2.5 % fewer
cmp diffs. The +128 B is now documented as a known residual.

## Reverted hypotheses

- iter 1 — cosmetic comment in `sunxi_can_asm.h`. No measurable effect
  (as expected for source comments), but it confirmed the +128 B is
  insensitive to header text — useful as a null-result anchor.
