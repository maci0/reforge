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
