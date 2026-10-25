# tests/ — validation

All ReForge tests. Most run on an x86 host with **no printer**.

| path | what | how |
|---|---|---|
| `smoke/` | quick host-side checks: `smoke_rootfs` (base rootfs branded ReForge), `smoke_guppy` (full stack present — klippy/moonraker/mainsail/httpd/guppyscreen), `repro_check` (reproducible build), `chroot_integration` (live Moonraker API + busybox httpd serves Mainsail, under qemu-user) | `make smoke` / `make smoke-guppy` / `make repro` / `make integration` |
| `loopback-install-test.sh` | installs ReForge into a scratch `/data` on the host, asserts the one-symlink footprint | `make validate-loopback` (sudo) |
| `qemu-harness/` | full `qemu-system-arm` harness: virt test kernel, 800×480 fb pinned to the panel, install/boot/web/render/memory tests | see `qemu-harness/README.md` |
| `release/` | Host checks for boot helpers, services, OTA layout, configs, and console splash behavior (including real terminal output). | `make unit`; additional release checks are called by their build workflows |

Smoke/integration use `qemu-arm-static` (no sudo). The qemu-harness boots a real kernel
(sudo for loop mounts). Nothing here ships in the firmware.

Klipper lazy-import patch regression (pass an unpatched or pre-0007 v0.11.0 source tree):

```sh
python3 tests/release/test_klipper_lazy_imports.py build/output/build/klipper-e02b725602067a2cd098a62be9a4bb10fc74a9bd
```

This applies patch 0007 to temporary copies, checks that module loading avoids
`multiprocessing`, and exercises each deferred process entry point with a stub API.

Moonraker lazy update-backend regression (pass a pinned source tree before patch 0003):

```sh
python3 tests/release/test_moonraker_lazy_imports.py build/output/build/moonraker-b559b9a81161f958a43c2f527b6ad96f73310d5d
```

This applies patch 0003 to a temporary copy and checks ZIP/web startup, on-demand
Git/Python/system backend selection, and rejection of ZIP updaters by Git recovery.
Printer services and deployment side effects are stubbed.

Check both Klipper package selections with `tests/release/klipper-packages-test.sh`.
The v0.13 lazy-import check uses the same runner with its patch as the second argument:

```sh
python3 tests/release/test_klipper_lazy_imports.py path/to/klipper-v0.13.0 \
    br-external/package/klipper13/0002-defer-multiprocessing-imports.patch
```
