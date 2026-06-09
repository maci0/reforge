# HelixScreen qemu eval (lab — NOT shipped yet)

Chosen over KlipperScreen for the on-screen-UI eval: **HelixScreen is GuppyScreen-class**
(C++, LVGL 9, **direct framebuffer** `/dev/fb0`, libhv + spdlog) — *not* the GTK3/X11/mesa/python
stack KlipperScreen needs. So it fits ReForge's model (a single fbdev binary, no display server,
no python) and renders through the same LVGL→virtio-gpu path that the guppy `/dev/disp` fix
unblocked. Upstream: <https://github.com/prestonbrown/helixscreen> (GPL-3.0). Recipe mirrors
`xblax/flashforge_ad5m_klipper_mod` PR #367's `variant-helixscreen`.

## What's here

- `br-external/package/helixscreen/` — the Buildroot package (default **n**; only the eval enables
  it). `helixscreen.mk`: git pin `846a6e35`, `make PLATFORM_TARGET=ad5m-br`, deps
  `libevdev openssl tslib`, installs `/opt/helixscreen/{bin,ui_xml,assets}`.
  `0001-libhv-override-cppflags.patch`: the libhv `override CPPFLAGS` fix (below).
- `tests/qemu-harness/helix-render.sh` — render rig: boot HEADLESS (moonraker + fake-klippy),
  launch `helix-screen` directly (stderr→console), dump `/dev/fb0` → PNG. Mirrors `guppy-render.sh`.

## Build bring-up status (multi-submodule — in progress)

HelixScreen vendors + cross-builds several libs (libhv, wpa_supplicant, libnl, lvgl, spdlog, fmt,
sdl2). Each can trip on Buildroot cross flags. Progress:

- ✅ **libhv** — failed with `hexport.h: No such file`. Root cause: libhv's `Makefile.in` uses
  `CPPFLAGS += -I…`, which Buildroot's command-line `CPPFLAGS` overrides, dropping `-I.`. Fixed by
  `override CPPFLAGS` (same fix guppyscreen's `0002` applies). → `libhv.a` builds.
- ⏳ **wpa_supplicant** (`libwpa_client.a`, for the WiFi panel) — fails `common/ieee802_11_defs.h:
  No such file` compiling `src/common/wpa_ctrl.c`. Source IS present; the bundled wpa cross-build's
  `-Isrc` isn't reaching the compile under ReForge's `TARGET_CFLAGS`/`env -u CFLAGS` path. WiFi is
  not needed for a render/RAM eval — next step is either a `-Isrc` patch or skipping the bundled
  wpa (the Yocto path zeroes `WPA_CLIENT_LIB` but expects system libhv/spdlog too, which we don't
  have, so a targeted wpa-include fix is cleaner).
- ⬜ remaining submodules (lvgl/spdlog/fmt/sdl2) + the app link.
- ⬜ render: expect the **same `/dev/disp` early-return** as guppy (HelixScreen shares the LVGL
  fbdev lineage) — apply the guppy fix pattern if the first render is blank.

## Then

Render at 800×480 + probe RSS, compare to GuppyScreen — the actual eval question (HelixScreen is a
plausible *lighter-than-KlipperScreen* GuppyScreen alternative, so the RAM delta vs guppy matters).
