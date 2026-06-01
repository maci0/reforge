# Screenshots

GUI renders are captured from `qemu-system-arm` with `/dev/fb0` pinned to the printer's exact
panel (**800×480, 32 bpp**), via the QEMU monitor `screendump` (see
`tests/qemu-harness/README.md`) — **pixel-identical to the real 4.3" screen**. The boot
images are rendered from the actual qemu serial capture / the in-repo banner script.

## Bootsplash (fire/ember "ReForge")

![ReForge bootsplash](reforge-bootsplash.png)

The fire-gradient banner from `board/reforge/rootfs-overlay/usr/bin/reforge-banner` — shown on
the boot console (via `reforge-boot`) and on interactive login (`/etc/profile.d`). Steel anvil,
ember-hot base, tagline *"ReForge — Klipper, reforged"*. 256-color ANSI; degrades to plain text
on dumb terminals.

## Boot process

![ReForge boot console](reforge-boot-console.png)

The real ReForge userspace boot sequence captured from the qemu serial: cloud-block → sysctl →
zram swap → klipper → moonraker → busybox httpd (Mainsail) → guppyscreen → `Welcome to ReForge`.

> The zram line shows skipped here because the qemu **virt** test kernel is built without
> `PREEMPT`, so the stock-built `zram.ko` vermagic mismatches. On the **real stock 5.4.61
> kernel** the module matches and zram swap activates (see `modules/zram-bsp/`).

## GuppyScreen (ReForge's on-screen UI)

![GuppyScreen in qemu, 800×480](guppyscreen-qemu-800x480.png)

ReForge booted in qemu with `SCREEN_MODE=GUPPY`. GuppyScreen (native LVGL) renders to
the pinned 800×480 framebuffer. No MCU in qemu → klippy is in `error`/waiting, so
GuppyScreen shows its connecting/offline state — which still proves the full render
path works (LVGL → DRM/virtio-gpu fbdev → `/dev/fb0`). Regenerate with `make qemu-render`.

## Stock UI (`firmwareExe`) — full home screen under simulated hardware

![Stock FlashForge home screen in qemu, 800×480](stockui-home-qemu-800x480.png)

The stock FlashForge UI booted all the way to its **home screen** in qemu: nav rail
(home / print / settings / info), live nozzle + bed temperature panels, light/network/camera
tiles, and a normal *"Do you want to recovery print?"* prompt — 901 distinct colors, fully
interactive. ReForge overlays the stock base, so the stock UI binary (`/opt/PROGRAM/.../firmwareExe`,
soft-float Qt4/QWS) and its Qt + tslib libs run straight from that base — no extraction, no recompile.

Getting past startup needs **two gates satisfied** (firmwareExe checks them independently):
1. an **eboard MCU serial handshake** on `/dev/ttyS1` (+`/dev/ttyS5`) @230400 — qemu virt has no
   8250 UART, so `tests/qemu-harness/stockui/mcu-sim.py` emulates a gcode MCU on a pty;
2. a **klippy "ready"** reply on `/tmp/uds` — `tests/qemu-harness/stockui/fake-klippy.py` serves
   the JSON-RPC subset firmwareExe polls.

Reproduce with **`make qemu-stockui`** (fully rootless — debugfs inject + GPT-offset rootfs slice
+ unprivileged qemu). Capture lands at `tests/qemu-harness/build/stockui-home.ppm`.

### Without the MCU sim — the "No detected eboard mcu." modal

![Stock FlashForge MCU-absent modal](stockui-qemu-800x480.png)

Booting the same stock base with **no** MCU sim stops at firmwareExe's
**"No detected eboard mcu."** modal (gate 1 unmet) — the green/white dialog that motivated the
simulation above. Full works/breaks analysis: `docs/research/stock-ui-spike.md`.
