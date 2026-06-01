# Repo layout — product vs lab

What ships to GitHub vs what is experiment/scratch. The product tree is everything you
need to build, package, install, test, and document ReForge. `lab/` is throwaway.

## Top-level map

```
br-external/   firmware: Buildroot BR2_EXTERNAL tree (the product core)
buildroot/     upstream Buildroot (git submodule, pinned)
modules/       out-of-tree kernel modules (zram-bsp; Plan 5 display driver lands here)
packaging/     stock-format .tgz builder + installer/uninstaller
tests/         ALL validation
  smoke/         smoke_rootfs, smoke_guppy, repro_check, chroot_integration
  loopback-install-test.sh
  qemu-harness/  qemu-system-arm: kernel build, fb-pinned render, update/web tests
docs/          knowledge
  specs/         design specs (dated)
  plans/         implementation plans (dated, archival)
  research/      findings (incl. stock-ui-spike GO/Option-A)
  board-notes/   hardware probes
  screenshots/   qemu-captured renders
  REPO-LAYOUT.md (this file)
tools/         dev/ops tooling (not shipped in firmware)
  build/         build.sh + env.sh — top-level build entry
  recovery/      golden-dump tooling + RUNBOOK (scripts tracked; images gitignored)
lab/           experiments / scratch (does NOT ship) — see lab/README.md
Makefile  pins.lock  .gitmodules  .github/   build glue, pins, submodules, CI
```

## Product (ships)

| path | responsibility |
|---|---|
| `br-external/` | Buildroot `BR2_EXTERNAL` tree (name `REFORGE`) — defconfigs, packages, rootfs overlay, board files. **The firmware.** |
| `packaging/` | Stock-format `.tgz` builder (`build-tgz.sh`) + installer (`flashforge_init.sh`) + uninstaller. |
| `modules/zram-bsp/` | zram/zsmalloc loadable modules for the stock 5.4.61 kernel + `swapon_prio` + setup scripts (sources + built `dist/*.ko`). |
| `tests/` | All test **runners**: `smoke/` quick checks, `loopback-install-test.sh`, and the `qemu-harness/` (kernel build, fb-pinned render, update-process, web-reachability). |
| `docs/` | `specs/` design, `plans/` archival plans, `research/` findings, `board-notes/`, `screenshots/`, this file. |
| `tools/build/` | `build.sh` + `env.sh` — top-level build entry (driven by the `Makefile`). |
| `tools/recovery/` | Golden-dump tooling + `RUNBOOK.md` (scripts only — images are gitignored). |
| `Makefile`, `pins.lock`, `.gitmodules`, `.github/` | Build glue, pinned versions, submodules, CI (incl. the no-blobs guard). |

The `Makefile` is the single entry point and centralizes every script path — `make help`
lists targets. Moving a runner only needs the matching Makefile line updated.

## Lab (experiments / scratch — does NOT ship)

| path | what |
|---|---|
| `lab/spike-stockui/` | Stock-UI feasibility spike scripts. Finding promoted to `docs/research/stock-ui-spike.md`. |
| `lab/scratch/` | Loose junk (stray configs, extracted tarballs, build artifacts). Gitignored. |

## Transient build output (non-product, gitignored in place — not moved to lab/)

`output/`, `output-guppy/`, `tests/qemu-harness/build/`, `packaging/dist/`,
`tools/recovery/*.img.gz`, `modules/zram-bsp/{tina-bsp-kernel,gcc-*,linux-5.4.61*,build-tina}/`.

## Conventions

- **Classify by nature, not by directory.** A test runner is product even if it exercises
  experimental kernels; a downloaded toolchain is transient even though the product needs
  it to build. Findings (knowledge) are product; the mechanics that produced them may be lab.
- **`tests/` = all validation, `tools/` = dev/ops helpers.** Neither ships *inside* the
  firmware image; both are part of the product repo. `lab/` is the only non-shipping tree.
- **Proprietary blobs never tracked.** `firmwareExe`, Qt `.so`, `/opt/PROGRAM/` — CI
  no-blobs guard enforces it. The spike extracts them only to the gitignored
  `lab/spike-stockui/extracted/`.
- **Archival docs are snapshots.** Files under `docs/plans/` and `docs/specs/` record paths
  as they were when written (e.g. `scripts/`, `validation/`, `spike-stockui/` pre-reorg).
  They are not rewritten on later moves; **this file is the current source of truth for layout.**
