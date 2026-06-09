# HelixScreen qemu eval (lab — NOT shipped yet)

> **STATUS (2026-06-09): builds + renders in qemu.** `make rootfs` with
> `BR2_PACKAGE_HELIXSCREEN=y` produces a 9.4 MB stripped `helix-screen` + assets;
> `tests/qemu-harness/helix-render.sh` boots it and it paints its first-run
> language-setup wizard at 800×480 (2417 colours) — see
> `docs/screenshots/helixscreen-qemu-800x480.png`. No `/dev/disp` issue (its LVGL
> fbdev backend paints `/dev/fb0` directly). The build was a real port — the
> blockers + their fixes are baked into `br-external/package/helixscreen/`
> (POST_PATCH git-init of the LVGL/libhv submodules so HelixScreen's `git apply`
> patching works, host-contamination guards for spdlog/libusb, libhv forced
> static, env flag-passing). Still TODO before any ship decision: RAM probe vs
> GuppyScreen, the splash/watchdog helper binaries (separate link issue), strip/
> size review, and a real `SCREEN_MODE=HELIX` boot path.


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

## RAM: HelixScreen vs GuppyScreen (the eval's core question)

Measured in qemu (`MEM=256`, identical fake-klippy + Moonraker stack, the
`RAMPROBE` blocks in `helix-render.sh` / `guppy-render.sh`), per-process `VmRSS`:

| UI            | UI process RSS | notes |
|---------------|---------------:|-------|
| **GuppyScreen** | **~8.2 MB**  | home screen |
| **HelixScreen** | **~11.7 MB** | first-run language wizard |

GuppyScreen is **~3.5 MB (~43%) lighter**, but both are tiny LVGL/fbdev C++
binaries — neither is anywhere near the GTK3/Python/Xorg weight that got
KlipperScreen excluded. The shared stack dominates either way (Moonraker python3
~39 MB + fake-klippy ~7.5 MB). With both UIs `MemAvailable` was ~167 MB of 238 MB,
i.e. ~67 MB used — fits the 128 MB device comfortably (plus zram swap).

Caveat: these are early-boot RSS (Helix on its first-run wizard); a fully-loaded
printer UI + the 73 MB of Helix assets paged in would push both higher, but the
relative ordering (Helix a few MB heavier) should hold. So **HelixScreen is a
viable GuppyScreen alternative on RAM** — the choice is about features/UX, not a
128 MB blocker.

## Reality check: this is a package PORT, not a quick eval

HelixScreen vendors + cross-builds ~7 libs and 3 binaries (main / watchdog / splash), each with
its own flag handling. The reference (xblax PR #367) builds it as a whole Buildroot **variant**;
porting it into ReForge's Buildroot surfaces a chain of cross-build issues. The **key unlock** was
realising ReForge passes `CFLAGS/CPPFLAGS` as make **command-line** vars, which clobber every
component's `+= -I` — fixed by passing them as **env** vars in `helixscreen.mk` (the package now
uses `$(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) $(MAKE) …`). That un-clobbered all the good
includes at once — but also un-dropped a **bad hardcoded host path** (`-isystem /usr/include/libusb-1.0`)
the reference's clobber had been silently hiding. After disabling that (ad5m has no libusb —
backlight is `/dev/disp`), the next layer appears (watchdog's `mk/watchdog.mk` not propagating
`SPDLOG_INC`, splash `-D` redefinition conflicts). It does **not converge quickly** — each fix
reveals 2-3 more component issues.

**Two ways forward:**
1. **Finish the source port** — dedicated effort: make each component (`mk/{watchdog,splash}.mk`)
   carry `SPDLOG_INC`/`LIBHV_INC`, resolve the `-D` conflicts, then link + the likely `/dev/disp`
   render fix (same as guppy). Tractable (the reference proves it builds), but it's a real port.
2. **Eval via the prebuilt binary** — for the *render + RAM* question we don't need to build from
   source: drop the xblax `variant-helixscreen` image's prebuilt `/opt/helixscreen/bin/helix-screen`
   + assets into the rig and run it. Fast path to the actual comparison vs GuppyScreen.

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
