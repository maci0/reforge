# Screenshots — captured in qemu (no device)

All captured from `qemu-system-arm` with `/dev/fb0` pinned to the printer's exact
panel (**800×480, 32 bpp**), via the QEMU monitor `screendump` (see
`validation/qemu-harness/README.md`). So these are **pixel-identical to what the real
4.3" screen would show**.

## GuppyScreen (ReForge's on-screen UI)

![GuppyScreen in qemu, 800×480](guppyscreen-qemu-800x480.png)

ReForge booted in qemu with `SCREEN_MODE=GUPPY`. GuppyScreen (native LVGL) renders to
the pinned 800×480 framebuffer. No MCU in qemu → klippy is in `error`/waiting, so
GuppyScreen shows its connecting/offline state — which still proves the full render
path works (LVGL → DRM/virtio-gpu fbdev → `/dev/fb0`). Regenerate with `make qemu-render`.

## Stock UI (`firmwareExe`) — spike result, screenshot NOT committed

The stock-UI spike (`spike-stockui/REPORT.md`) booted the stock environment in qemu and
ran FlashForge's proprietary `firmwareExe` against the same 800×480 fb. **Result: it
rendered** — Qt4/QWS initialized and the FlashForge splash drew to the framebuffer
(screendump had 97 distinct pixel values, non-blank).

The screenshot itself is **deliberately not committed**: it shows FlashForge's
proprietary UI/branding, and this repo commits **zero proprietary assets** (CI-guarded —
same policy that excludes the `firmwareExe` binary). The render is captured locally to
`validation/qemu-harness/build/stockui-screenshot.ppm` (gitignored) when you run the
spike; see `spike-stockui/REPORT.md` for the full works/breaks analysis and the
**GO / Option-A** recommendation.
</content>
