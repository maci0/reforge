# lab/ — experiments & scratch

Investigations, experiments, and their findings. Tracked scripts and notes are published
with this repository; they are not packaged into the firmware. Keep generated output
ignored next to the experiment that produces it.

## Contents

| path | what | tracked? |
|---|---|---|
| `spike-stockui/` | Stock-UI (`firmwareExe`) feasibility spike — `extract.sh` + `analyze.sh`. | scripts tracked; `extracted/` gitignored (proprietary blobs) |
| [toolchain-memory/](toolchain-memory/README.md) | Compiler config fragments for the memory experiments. | fragments and notes tracked |
| [mem-experiment/](mem-experiment/) | Size and allocator build variants. | scripts tracked |
| [ad5m-vs-pro/](ad5m-vs-pro/findings.md) | AD5M / Pro hardware and config comparison. | findings tracked |
| [dsp-rebrew/](dsp-rebrew/README.md) | Byte-identical stock DSP kernel C component: pinned XCC/Rebrew recipe, recovered layout and complete-range proof; full firmware remains open. | source, configuration and proof tracked; generated binaries ignored |
| [stock-image-repro/](stock-image-repro/findings.md) | Stock eMMC image reproduction investigation. | findings tracked |
| [helixscreen-eval/](helixscreen-eval/README.md) | HelixScreen port and evaluation notes. | notes tracked |
| [klipperscreen-eval/](klipperscreen-eval/README.md) | KlipperScreen evaluation plan. | notes tracked |
| [venc/](venc/README.md) | Video encoder experiments using the vendor SDK. | source tracked; SDK and device libraries ignored |
| [venc-scratch/](venc-scratch/README.md) | Encoder register and memory probes. | source tracked; generated output ignored |
| [venc-vendor/](venc-vendor/README.md) | Vendor encoder API investigation. | source and findings tracked |
| [ve-kmod/](ve-kmod/README.md) | Video engine diagnostic kernel modules. | source tracked; build output ignored |
| `scratch/` | Loose junk: stray configs, extracted source tarballs, build artifacts. | gitignored entirely |

The **finding** from the stock-UI spike is product knowledge and lives in the docs:
[`docs/research/ui-camera/2026-06-01-stock-ui-spike.md`](../docs/research/ui-camera/2026-06-01-stock-ui-spike.md)
(GO / Option-A). Only the spike's mechanics stayed here.

## What is NOT here (but is also non-product / transient)

Heavy build output stays next to the thing that produces it and is gitignored in place —
not moved here:

- `build/output/` — buildroot output (the single ReForge image)
- `tests/qemu-harness/build/` — test kernel, ext4 images, logs
- `packaging/dist/` — built `.tgz`
- `tools/recovery/*.img.gz` — golden dumps
- `vendor/kernels/`, `vendor/toolchains/` — BSP/mainline kernel sources + crosstool (downloaded)
- `modules/zram-bsp/build-tina/` — zram BSP kernel build output

See `docs/REPO-LAYOUT.md` for the full product-vs-lab map.
