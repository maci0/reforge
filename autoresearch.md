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

## Reverted hypotheses

(empty so far)
