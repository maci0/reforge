# Repo layout — product vs lab

What ships to GitHub vs what is experiment/scratch. The product tree is everything you
need to build, package, install, validate, and document ReForge. `lab/` is throwaway.

## Product (ships)

| path | responsibility |
|---|---|
| `br-external/` | Buildroot `BR2_EXTERNAL` tree (name `REFORGE`) — defconfigs, packages, rootfs overlay, board files. **The firmware.** |
| `packaging/` | Stock-format `.tgz` builder (`build-tgz.sh`) + installer (`flashforge_init.sh`) + uninstaller. |
| `modules/zram-bsp/` | zram/zsmalloc loadable modules for the stock 5.4.61 kernel + `swapon_prio` + setup scripts (sources + built `dist/*.ko`). |
| `validation/` | Test **runners**: loopback install test + qemu-system-arm harness (kernel build, fb-pinned render, update-process, web-reachability). |
| `recovery/` | Golden-dump tooling + `RUNBOOK.md` (scripts only — images are gitignored). |
| `scripts/` | Smoke / repro / chroot-integration test scripts. |
| `build_scripts/` | `build.sh` + `env.sh` — top-level build entry. |
| `docs/` | Design specs, plans, research findings, board notes, screenshots, this file. |
| `Makefile`, `pins.lock`, `.gitmodules`, `.github/` | Build glue, pinned versions, submodules, CI (incl. the no-blobs guard). |

## Lab (experiments / scratch — does NOT ship)

| path | what |
|---|---|
| `lab/spike-stockui/` | Stock-UI feasibility spike scripts. Finding promoted to `docs/research/stock-ui-spike.md`. |
| `lab/scratch/` | Loose junk (stray configs, extracted tarballs, build artifacts). Gitignored. |

## Transient build output (non-product, gitignored in place — not moved to lab/)

`output/`, `output-guppy/`, `validation/qemu-harness/build/`, `packaging/dist/`,
`recovery/*.img.gz`, `modules/zram-bsp/{tina-bsp-kernel,gcc-*,linux-5.4.61*,build-tina}/`.

## Conventions

- **Classify by nature, not by directory.** A test runner is product even if it exercises
  experimental kernels; a downloaded toolchain is transient even though the product needs
  it to build. Findings (knowledge) are product; the mechanics that produced them may be lab.
- **Proprietary blobs never tracked.** `firmwareExe`, Qt `.so`, `/opt/PROGRAM/` — CI
  no-blobs guard enforces it. The spike extracts them only to the gitignored
  `lab/spike-stockui/extracted/`.
- **Archival docs are snapshots.** Plan/spec files under `docs/plans/` and `docs/*-design.md`
  record paths as they were when written (e.g. `spike-stockui/` pre-reorg). They are not
  rewritten on later moves; this file is the current source of truth for layout.
