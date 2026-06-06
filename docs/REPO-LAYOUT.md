# Repo layout — product vs vendor vs lab

What ships to GitHub vs what is third-party vs what is experiment/scratch. The product
tree is everything *we author* to build, package, install, test, and document ReForge.

## Top-level map

```
br-external/   firmware: Buildroot BR2_EXTERNAL tree (the product core, ours)
modules/       out-of-tree kernel modules we author (zram-bsp; f2fs-bsp for live mode; Plan 5 display driver)
packaging/     stock-format .tgz builder + installer/uninstaller + live/ run-from-USB launcher
tests/         ALL validation
  smoke/         smoke_rootfs, smoke_guppy, repro_check, chroot_integration
  loopback-install-test.sh
  qemu-harness/  qemu-system-arm: kernel build, fb-pinned render, update/web tests
docs/          knowledge: architecture/build/boot/ota (diagrams) + specs/ plans/ research/ board-notes/ reverse-engineering/ screenshots/ REPO-LAYOUT.md BACKLOG.md
tools/         dev/ops tooling (not shipped in firmware)
  build/         build.sh + env.sh — top-level build entry
  recovery/      golden-dump tooling + RUNBOOK
vendor/        third-party we DON'T author — submodules + pinned tarballs (see vendor/README.md)
  buildroot/             git submodule (Buildroot 2026.02.2)
  kernels/tina-bsp-kernel/   git submodule (Allwinner T113 BSP, 5.4.61)
  toolchains/            pinned crosstool tarball (gcc 9.5.0 arm-linux-gnueabi)
  fetch.sh               reconstruct everything above at pinned versions
build/         transient build output (gitignored): output/ (single full image)
lab/           experiments / scratch (does NOT ship) — see lab/README.md
Makefile  pins.lock  .gitmodules  .github/   build glue, pins, submodule registry, CI
```

## Product (we author — ships)

| path | responsibility |
|---|---|
| `br-external/` | Buildroot `BR2_EXTERNAL` tree (name `REFORGE`) — defconfigs, packages, rootfs overlay, board files. **The firmware.** |
| `packaging/` | Stock-format `.tgz` builder + installer/uninstaller; `live/flashforge_init.sh` — the run-from-USB launcher (see `docs/live-mode.md`). |
| `modules/zram-bsp/` | zram/zsmalloc loadable modules **(our build scripts + `swapon_prio.c` + setup + `dist/*.ko`)**. Builds against the BSP submodule in `vendor/`. |
| `modules/f2fs-bsp/` | Live-mode loadable modules — `crc32_generic.ko` + `f2fs.ko` (build script + `dist/*.ko`), built against the BSP at the device's exact vermagic. The 2-partition live USB layout mounts the F2FS rootfs directly off p2, so `loop.ko` is no longer built or shipped here. |
| `modules/overlay-bsp/` | OverlayFS loadable module built against the BSP (stock kernel ships `# CONFIG_OVERLAY_FS is not set`) — enables the atomic/immutable ReForge direction (`docs/plans/2026-06-05-immutable-reforge.md`); build recipe + on-HW sanity check. |
| `tests/` | All test **runners**: `smoke/`, `loopback-install-test.sh`, `qemu-harness/`. |
| `docs/` | `specs/`, `plans/`, `research/`, `board-notes/`, `reverse-engineering/`, `screenshots/`, this file. |
| `tools/build/` | `build.sh` + `env.sh` — build entry (driven by the `Makefile`). |
| `tools/recovery/` | Golden-dump tooling + `RUNBOOK.md` (scripts only — images gitignored). |
| `Makefile`, `pins.lock`, `.gitmodules`, `.github/` | Build glue, pins, submodule registry, CI no-blobs guard. |

## Vendor (third-party — pinned, not authored here)

`pins.lock` is the source of truth; `vendor/fetch.sh` reconstructs all of it.

| path | upstream | mechanism |
|---|---|---|
| `vendor/buildroot/` | Buildroot `2026.02.2` | git submodule |
| `vendor/kernels/tina-bsp-kernel/` | `iLotusK9/linux_kernel_aw_t113@5.4.61` | git submodule |
| `vendor/toolchains/gcc-9.5.0-nolibc/` | kernel.org crosstool GCC 9.5.0 | pinned tarball (sha256) |

Mainline `linux-5.4.61` is **not** vendored by default (BSP is the build source); fetch it
manually only for fallback/porting diffs. See `vendor/README.md`.

## Lab (experiments / scratch — does NOT ship)

| path | what |
|---|---|
| `lab/spike-stockui/` | Stock-UI feasibility spike scripts. Finding promoted to `docs/research/ui-camera/stock-ui-spike.md`. |
| `lab/scratch/` | Loose junk. Gitignored. |

## Transient build output (gitignored in place — not committed)

`build/output` (the single ReForge image),
`tests/qemu-harness/build/`, `packaging/dist/`, `tools/recovery/*.img.gz`,
`modules/zram-bsp/build-tina/`, `modules/f2fs-bsp/build/` (the `dist/*.ko` ARE committed).

## Conventions

- **Three trees: product (ours), vendor (theirs), lab (throwaway).** `tools/` + `tests/`
  are product (dev/ops + validation) but don't ship *inside* the firmware image.
- **Vendor is reproducible, never bulk-committed.** Submodules pin a commit; tarballs pin a
  sha256. A fresh clone runs `./vendor/fetch.sh`.
- **Proprietary blobs never tracked.** `firmwareExe`, Qt `.so`, `/opt/PROGRAM/` — CI guard
  enforces; the spike extracts only to gitignored `lab/spike-stockui/extracted/`.
- **Archival docs are snapshots.** `docs/plans/` + `docs/specs/` record paths as written;
  not rewritten on later moves. **This file is the current source of truth for layout.**
