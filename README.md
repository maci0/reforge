# ReForge

A from-scratch, mainline-based firmware stack for the **FlashForge Adventurer 5M Pro**
(Allwinner T113-S3 / sun8iw20, Cortex-A7). Fresh upstream Buildroot (glibc) + latest
pinned Klipper / Moonraker / Mainsail / GuppyScreen, built to run on the stock vendor
kernel today and a mainline kernel + self-ported T113 display driver later.

![ReForge bootsplash](docs/screenshots/reforge-bootsplash.png)

(See [`docs/screenshots/`](docs/screenshots/README.md) for the boot console + on-screen UI.)

> **Status:** core stack builds, boots, and serves Moonraker live under qemu (no device
> required). zram compressed swap works on the stock kernel. Stock-UI (`firmwareExe`)
> against upstream Klipper is feasibility-confirmed. MCU firmware (Plan 4) and the full
> mainline image + display driver (Plan 5) are not started.

## Layout

Three trees — **product** (what we author), **vendor** (third-party, pinned), **lab**
(throwaway). Full map: [`docs/REPO-LAYOUT.md`](docs/REPO-LAYOUT.md).

```
br-external/  the firmware (Buildroot BR2_EXTERNAL tree)
modules/      out-of-tree kernel modules (zram)
packaging/    stock-format .tgz installer
tests/        qemu harness + smoke + loopback install test
tools/        build entry + golden-dump recovery
docs/         specs, plans, research, board notes, screenshots
vendor/       buildroot + BSP kernel (submodules) + toolchain (pinned tarball)
lab/          experiments / scratch (not shipped)
```

## Quick start

```sh
# 1. Get the pinned third-party trees (submodules + verified toolchain tarball)
./vendor/fetch.sh

# 2. Build the single ReForge image (klipper + moonraker + mainsail +
#    guppyscreen + zram). SCREEN_MODE picks headless vs on-screen at runtime.
make rootfs              # reforge_defconfig -> build/output/

# 3. Package the stock-format updater
make tgz                 # -> packaging/dist/reforge-<ver>.tgz
```

`pins.lock` is the authoritative version manifest; `vendor/fetch.sh` reconstructs all
third-party trees at exactly those pins. Build paths are driven by the `Makefile`
(`make help` lists targets).

## How it works (diagrams)

| doc | what |
|---|---|
| [Architecture](docs/architecture.md) | the overlay-on-stock chroot model + the runtime stack + data flow |
| [Build process](docs/build-process.md) | pins → vendor fetch → Buildroot → image → `.tgz` |
| [Boot flow](docs/boot-flow.md) | power-on → `reforge-boot` → service chain → up (with `SKIP_MOD`) |
| [Updates / OTA](docs/ota.md) | git-free in-place updates + the last-known-good rollback (designed) |

![ReForge boot console](docs/screenshots/reforge-boot-console.png)

## Test without a printer

The qemu harness boots a virt-machine kernel (built from the same BSP source) with the
framebuffer pinned to the real 800×480 panel, and exercises install, boot, the web stack,
and the on-screen GUI — all on an x86 host. See
[`tests/qemu-harness/README.md`](tests/qemu-harness/README.md).

```sh
make qemu-kernel         # build the virt test kernel (heavy, one-time)
make qemu-update         # install ReForge into an ext4 + boot it, assert Moonraker live
make qemu-render         # capture the GuppyScreen render at 800x480
```

## Recovery

The printer's stock state can be dumped and restored via the tooling in
[`tools/recovery/`](tools/recovery/RUNBOOK.md). Golden images are large and **never
committed** (gitignored).

## Policy

This repo commits **zero proprietary FlashForge assets** (`firmwareExe`, Qt blobs,
`/opt/PROGRAM/` contents) — a CI guard enforces it. Stock-UI investigation extracts those
only into a gitignored scratch area.
