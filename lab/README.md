# lab/ — experiments & scratch

Throwaway / investigative work. **Not part of the ReForge product.** Nothing here is
required to build, install, or run the firmware. Keep it out of your mental model of
"what ships."

Rule of thumb: if removing a thing would not break a product build, a packaged `.tgz`,
or a documented validation run, it belongs here.

## Contents

| path | what | tracked? |
|---|---|---|
| `spike-stockui/` | Stock-UI (`firmwareExe`) feasibility spike — `extract.sh` + `analyze.sh`. | scripts tracked; `extracted/` gitignored (proprietary blobs) |
| `scratch/` | Loose junk: stray configs, extracted source tarballs, build artifacts. | gitignored entirely |

The **finding** from the stock-UI spike is product knowledge and lives in the docs:
`docs/research/stock-ui-spike.md` (GO / Option-A). Only the spike's mechanics stayed here.

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
