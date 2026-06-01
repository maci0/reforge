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

## Stock UI (`firmwareExe`) — spike result, screenshot NOT committed

The stock-UI spike (`docs/research/stock-ui-spike.md`) booted the stock environment in qemu and
ran FlashForge's proprietary `firmwareExe` against the same 800×480 fb. **Result: it
rendered** — Qt4/QWS initialized and the FlashForge splash drew to the framebuffer
(screendump had 97 distinct pixel values, non-blank).

The screenshot itself is **deliberately not committed**: it shows FlashForge's
proprietary UI/branding, and this repo commits **zero proprietary assets** (CI-guarded —
same policy that excludes the `firmwareExe` binary). The render is captured locally to
`tests/qemu-harness/build/stockui-screenshot.ppm` (gitignored) when you run the
spike; see `docs/research/stock-ui-spike.md` for the full works/breaks analysis and the
**GO / Option-A** recommendation.
</content>
