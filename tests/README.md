# tests/ — validation

All ReForge tests. Most run on an x86 host with **no printer**.

| path | what | how |
|---|---|---|
| `smoke/` | quick host-side checks: `smoke_rootfs` (base rootfs branded ReForge), `smoke_guppy` (full stack present — klippy/moonraker/mainsail/httpd/guppyscreen), `repro_check` (reproducible build), `chroot_integration` (live Moonraker API + busybox httpd serves Mainsail, under qemu-user) | `make smoke` / `make smoke-guppy` / `make repro` / `make integration` |
| `loopback-install-test.sh` | legacy install-layout assertions; see limitation below | `make validate-loopback` (sudo) |
| `qemu-harness/` | full `qemu-system-arm` harness: virt test kernel, 800×480 fb pinned to the panel, install/boot/web/render/memory tests | see `qemu-harness/README.md` |
| `release/` | Host checks for boot helpers, services, OTA layout, configs, and console splash behavior (including real terminal output). | `make unit`; additional release checks are called by their build workflows |

Smoke/integration use `qemu-arm-static` (no sudo). The qemu-harness boots a real kernel;
most of its gates are rootless (`mke2fs -d` / `debugfs`), while `make qemu-update` and
`make validate-loopback` need sudo for loop mounts. `.github/workflows/build.yml` runs
`make lint`, `make unit`, and the `no-blobs` path check on every push and pull request.
`make rootfs`, `make smoke`, `make smoke-guppy`, `make integration`, and the release
slicer dry-run run in the `rootfs` job. `make repro` runs only on the weekly schedule
or a manual dispatch. No `qemu-*` target runs in CI. Nothing here ships in the firmware.

## Loopback install test

`make validate-loopback` still checks `${MOUNT_DIR}/.reforge`, while the current
installer writes `${MOUNT_DIR}/.mod/.reforge`. Its assertions cannot validate the
current install. Its host-footprint checks require two named host paths to be
absent (`/etc/init.d/S01reforge` and `/opt/reforge`); they are not an exhaustive
write audit. Use `make qemu-update` for the current install layout.

## Package patch checks

Klipper lazy-import patch regression. The runner always applies the patch, so
pass an unpatched v0.11.0 tree. A Buildroot package tree under
`build/output/build/klipper-*` is already patched and will fail the apply.
`KLIPPER_SRC` is that unpatched tree:

```sh
python3 tests/release/test_klipper_lazy_imports.py "$KLIPPER_SRC"
```

This applies patch 0007 to temporary copies, checks that module loading avoids
`multiprocessing`, and exercises each deferred process entry point with a stub API.

Moonraker lazy update-backend regression. Pass a pinned source tree from before
patch 0003. A Buildroot package tree under `build/output/build/moonraker-*` is
already patched. `MOONRAKER_SRC` is that unpatched tree:

```sh
python3 tests/release/test_moonraker_lazy_imports.py "$MOONRAKER_SRC"
```

This applies patch 0003 to a temporary copy and checks ZIP/web startup, on-demand
Git/Python/system backend selection, and rejection of ZIP updaters by Git recovery.
Printer services and deployment side effects are stubbed.

Check both Klipper package selections with `tests/release/klipper-packages-test.sh`.
The v0.13 lazy-import check uses the same runner with its patch as the second argument:

```sh
python3 tests/release/test_klipper_lazy_imports.py path/to/klipper-v0.13-ad5m \
    br-external/package/klipper13/0002-defer-multiprocessing-imports.patch
```

`python3 tests/release/test_mcu_firmware.py` checks MCU packaging rejection paths
without hardware; it is also part of `make unit`. Actual `klipper13` builds run
the same checker against both compiled images before installing them.

`python3 tests/release/test_stock_boot_extract.py` checks bootloader reference
extraction with synthetic plain/gzip images and rejects malformed checksums,
ranges, overlaps and existing output directories. It runs in `make unit`.
The [stock bringup audit](../docs/board-notes/stock-bringup-rebuild.md#verified-byte-identical-primary-u-boot)
records the U-Boot comparison. The primary 2023 image now matches in full
(966,656 bytes). The golden backup, a different build dated 2025-04-18, is
still unreproduced.

`python3 tests/release/test_stock_uboot.py` ensures a build cannot overwrite its
original reference through an existing output directory and checks 16-KiB
packing, checksums, DTB identity and overflow rejection; it runs in `make unit`.
