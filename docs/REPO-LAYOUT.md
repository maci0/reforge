# Repo layout — product vs vendor vs lab

What ships to GitHub vs what is third-party vs what is experiment/scratch. The product
tree is everything *we author* to build, package, install, test, and document ReForge.

## Top-level map

```
br-external/   firmware: Buildroot BR2_EXTERNAL tree (the product core, ours)
modules/       out-of-tree kernel modules we author (zram-bsp; f2fs-bsp for live mode; overlay-bsp, not yet wired in)
packaging/     stock-format .tgz builder + installer/uninstaller + live/ run-from-USB launcher
tests/         ALL validation
  smoke/         smoke_rootfs, smoke_guppy, repro_check, chroot_integration
  loopback-install-test.sh
  qemu-harness/  qemu-system-arm: kernel build, fb-pinned render, update/web tests
  release/       host unit and release checks (make unit, build workflows)
docs/          knowledge: architecture/build/boot/ota (diagrams) + specs/ plans/ research/ board-notes/ reverse-engineering/ screenshots/ REPO-LAYOUT.md BACKLOG.md
tools/         dev/ops tooling (not shipped in firmware)
  build/         Buildroot entry, kernel builders, stock reconstruction tools
  recovery/      golden-dump tooling + RUNBOOK
  release/       release archives, live USB images, release metadata, legacy live-trial helper
  ota/           FlashForge firmware update checker + host tests
  lint/          ShellCheck runner for tracked scripts
vendor/        third-party we DON'T author — submodules + pinned tarballs (see vendor/README.md)
  buildroot/             git submodule (Buildroot 2026.08.2)
  kernels/tina-bsp-kernel/   git submodule (Allwinner T113 BSP, 5.4.61)
  toolchains/            pinned tarballs: gcc 9.5.0 crosstool, optional Linaro 5.3.1 (not used by make rootfs)
  fetch.sh               submodules + gcc 9.5.0 (Linaro with FETCH_LINARO=1)
reference/     captured stock and Forge-X printer configs (reference/README.md)
build/         transient build output (gitignored): output/ (single full image)
lab/           tracked experiments and findings; ignored scratch (not packaged in firmware)
Makefile  pins.lock  .gitmodules  .github/   build glue, pins, submodule registry, CI
```

## Product (we author — ships)

| path | responsibility |
|---|---|
| `br-external/` | Buildroot `BR2_EXTERNAL` tree (name `REFORGE`) — defconfigs, packages, rootfs overlay, board files. **The firmware.** |
| `packaging/` | Stock-format `.tgz` builder + installer/uninstaller; `live/flashforge_init.sh` — the run-from-USB launcher (see `docs/live-mode.md`). |
| `modules/zram-bsp/` | `swapon_prio.c`, setup scripts, a standalone `build.sh` and fallback `dist/*.ko`. The image's zram modules come from the `reforge-zram` Buildroot package, which builds them from the BSP submodule. |
| `modules/f2fs-bsp/` | Live-mode modules `crc32_generic.ko` + `f2fs.ko` (build script + committed `dist/*.ko` that `make live-usb` copies), built against the BSP at the device's exact vermagic. |
| `modules/overlay-bsp/` | OverlayFS module built against the BSP (the stock kernel has `# CONFIG_OVERLAY_FS is not set`) for the [immutable-reforge plan](plans/2026-06-05-immutable-reforge.md); build recipe + on-hardware sanity check, not wired into any image. |
| `tests/` | All test **runners**: `smoke/`, `loopback-install-test.sh`, `qemu-harness/`, `release/` (see `tests/README.md`). |
| `docs/` | `specs/`, `plans/`, `research/`, `board-notes/`, `reverse-engineering/`, `screenshots/`, this file. |
| `tools/build/` | Build and stock-reconstruction tools; see the [tool index](../tools/README.md). |
| `tools/recovery/` | Golden-dump tooling + `RUNBOOK.md` (scripts only — images gitignored). |
| `tools/release/`, `tools/ota/`, `tools/lint/` | Release and live-image builders, the FlashForge update checker, ShellCheck runner (see `tools/README.md`). |
| `Makefile`, `pins.lock`, `.gitmodules`, `.github/` | Build glue, pins, submodule registry, CI no-blobs guard. |

## Vendor (third-party — pinned, not authored here)

`pins.lock` is the source of truth; `vendor/fetch.sh` reconstructs the table below.

| path | upstream | mechanism |
|---|---|---|
| `vendor/buildroot/` | Buildroot `2026.08.2` | git submodule |
| `vendor/kernels/tina-bsp-kernel/` | `iLotusK9/linux_kernel_aw_t113@5.4.61` | git submodule |
| `vendor/toolchains/gcc-9.5.0-nolibc/` | kernel.org crosstool GCC 9.5.0 | pinned tarball (sha256), `vendor/fetch.sh` |

`make rootfs` uses only the two submodules; Buildroot builds its own GCC 15 toolchain.
The GCC 9.5.0 crosstool serves the qemu test kernel (`make qemu-kernel`), the standalone
`modules/*/build.sh` scripts and `make bsp-kernel-rebuild`. `vendor/fetch.sh` fetches
only the submodules and toolchains (Linaro 5.3.1 with `FETCH_LINARO=1`).
[`vendor/README.md`](../vendor/README.md) also lists the stock-reproduction inputs:
stock-kernel patches and OP-TEE and boot0 runtime sources are tracked, while the pinned
stock U-Boot, kernel and Wi-Fi source archives are supplied by the caller and checked against
`pins.lock`. `make kernel-mainline` downloads its own Linux 7.3.5 tarball. Mainline
`linux-5.4.61` is **not** vendored (the BSP is the build source); fetch it manually only
for fallback or porting diffs.

## Lab (experiments / scratch — does NOT ship)

| path | what |
|---|---|
| `lab/` | Investigations and reproducible experiments, indexed in [lab/README.md](../lab/README.md). |
| `lab/dsp-rebrew/` | Stock DSP kernel C component reconstruction: pinned Rebrew/XCC recipe, recovered layout, complete-range proof and remaining firmware gaps. Generated binaries stay under ignored `build/`. |
| `lab/scratch/` | Loose junk. Gitignored. |

## Reference captures

[`reference/`](../reference/README.md) holds original stock firmware configs and
configs captured on a Forge-X system, with their provenance. ReForge's active
defaults live in `br-external/board/reforge/rootfs-overlay/etc/reforge/`.

## Transient build output (gitignored in place — not committed)

`build/output` (the single ReForge image),
`tests/qemu-harness/build/`, `packaging/dist/`, `tools/recovery/*.img.gz`,
`modules/zram-bsp/build-tina/`, `modules/f2fs-bsp/build/` (the `dist/*.ko` ARE committed).

## Conventions

- **Three trees: product (ours), vendor (theirs), lab (throwaway).** `tools/` + `tests/`
  are product (dev/ops + validation) but don't ship *inside* the firmware image.
- **Vendor is reproducible, never bulk-committed.** Submodules pin a commit; tarballs pin a
  sha256. A fresh clone runs `git submodule update --init --recursive`, or
  `./vendor/fetch.sh` when it also needs the toolchains.
- **Proprietary blobs never tracked.** `firmwareExe`, Qt `.so`, `/opt/PROGRAM/` — CI guard
  enforces; the spike extracts only to gitignored `lab/spike-stockui/extracted/`.
- **Archival docs are snapshots.** Keep their historical findings and decisions intact;
  correct links and runnable examples when files move. **This file is the current source of truth for layout.**
