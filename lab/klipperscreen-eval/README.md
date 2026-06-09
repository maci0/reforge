# KlipperScreen qemu eval (lab — NOT shipped)

KlipperScreen was **excluded from ReForge by design** (RAM/OOM on 128 MB; GTK/Python
vs GuppyScreen's single LVGL binary — see `docs/specs/2026-05-31-reforge-firmware-design.md`
§4 and `br-external/package/guppyscreen/Config.in`). This lab exists only to **evaluate it
in qemu**: see it render, measure its real RAM, and compare to GuppyScreen — to check whether
the 128 MB rejection still holds. Nothing here ships in the default image.

## Why it's not trivial

KlipperScreen is Python3 + GTK3 (PyGObject). GTK3 needs a display server. On the AD5M panel
that would be a Wayland compositor on the framebuffer; in qemu we drive the **virtio-gpu**
device, which exposes **DRM/KMS** (`CONFIG_DRM_VIRTIO_GPU=y` in the virt test kernel) but **no
GL/virgl**. So the render path is all-software:

```
virtio-gpu DRM/KMS
  └─ cage (kiosk wlroots compositor)   WLR_RENDERER=pixman  (software, no GLES/EGL)
       └─ GTK3 (wayland backend)        GDK_RENDERING=image / cairo (software)
            └─ KlipperScreen (python3 + pygobject)
```

## Plan (de-risk before committing the full build)

1. **Stack only** — build `cage + wlroots(+pixman) + libgtk3 + python-gobject` and prove a
   compositor paints `/dev/dri/card0` in qemu with a trivial GTK app (`gtk3-demo` or a 5-line
   PyGObject window). This is the uncertain part; validate it cheaply first.
2. **KlipperScreen** — add the app + its Python deps (jinja2, requests, websocket-client,
   netifaces, …) once step 1 renders. Point it at the same fake-klippy/Moonraker rig the
   GuppyScreen harness uses.
3. **Compare** — capture the render at 800×480 + probe RSS (`mem-probe`-style) vs GuppyScreen.

## Files

- `klipperscreen-eval.fragment` — defconfig delta adding the GUI stack (applied on top of
  `reforge_defconfig` for the eval image; never merged into the default).
- `stack-render-test.sh` — step-1 harness: boot the eval image, start cage + a GTK probe on
  virtio-gpu DRM, screendump. (added once the stack builds)

## How forge-x / zmod actually build it (the proven recipe)

forge-x (`DrA1ex/ff5m`) **extends zmod**; the base klipper-mod (`xblax/flashforge_ad5m_klipper_mod`,
Buildroot, same AD5M / 128 MB) ships a `variant-klipperscreen` and it is **not GL-heavy** — my
wlroots/LLVM framing below was wrong (that's the *Wayland* path, which nobody uses here). The
real stack is plain **X11 on the framebuffer with software mesa**:

- **mesa3d SWRAST** — `BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_SWRAST` + `_OPENGL_GLX` + `_NEEDS_X11`,
  `BR2_PACKAGE_PROVIDES_LIBGL="mesa3d"`. Software GL, **no LLVM/llvmpipe**, just to satisfy
  libgtk3-x11's `libGL` link dep. GTK renders 2D via cairo.
- **Xorg** — `XSERVER_XORG_SERVER` (modular) + `XLIB_LIBX11`, driver `xf86-video-fbturbo`
  (Allwinner; **use generic `xf86-video-fbdev` for qemu** — fbturbo wants the Allwinner G2D /
  `/dev/disp` that virtio-gpu lacks), input `xf86-input-evdev` + `tslib`. `xorg.conf`:
  `Driver "fbturbo"`, `Option "fbdev" "/dev/fb0"`.
- **GTK** — `libgtk3` + `LIBGTK3_X11` (not broadway).
- **KlipperScreen package** — git pin `6b6f63b6639e5b85a2b3f4b0b0cd7677ac9cda3d`, deps
  `python-{jinja2,requests,mpv,gobject,pycairo,websocket-client,psutil}` + `libevdev` +
  `iwd`+`dbus` (network panel) + `host-librsvg`; an `svg2png` post-patch converts assets to PNG
  (no runtime librsvg); installs to `/opt/klipperscreen`, run as `python3 screen.py`.
- **Launch** — `S40xorg` (`Xorg :0.0 vt01 -s 0 -noreset`) → `S35tslib` → `S80klipperscreen`
  (`DISPLAY=:0`, splash `xzcat …img.xz > /dev/fb0`, then `python3 /opt/klipperscreen/screen.py`).

The xblax docs flag the KlipperScreen variant as the RAM-heavy one ("check the default variant if
you hit resource exhaustion") — but it **does run on the 128 MB device**. So the eval is now: copy
this proven recipe into a ReForge lab image (swap fbturbo→fbdev for qemu), render it, and measure
RSS vs GuppyScreen.

## (superseded) earlier dependency guess — wlroots/LLVM

Every "real display" path for KlipperScreen in qemu pulls in a GL provider:

- **Wayland (cage/wlroots):** wlroots in this Buildroot **hard-depends on EGL + GLES + GBM**
  (`WLROOTS_RENDERERS = gles2`, `WLROOTS_DEPENDENCIES += mesa3d vulkan-loader`). virtio-gpu has
  no virgl, so that means **mesa3d software GL (swrast, or llvmpipe → LLVM)** — a multi-hour build.
- **X11 (Xorg + xf86-video-fbdev):** the parts exist, but libgtk3's Config gates the X11 GDK
  backend behind *"needs an OpenGL provider"* too — so still mesa3d.
- **Broadway (GTK→HTML):** the only no-GL option, but it renders to a *browser*, not `/dev/fb0`,
  so it can't produce the 800×480 framebuffer screenshot the comparison wants.

So even just to *see* KlipperScreen in qemu we must build **Xorg/Wayland + mesa3d (software GL) +
GTK3 + PyGObject + the KlipperScreen Python deps**. That is the whole point the design made when
it chose GuppyScreen — a **single LVGL binary writing `/dev/fb0`, no display server, no GL** —
for the 128 MB device. The dependency gap alone is strong evidence the 128 MB rejection still holds.

**Open question for the human:** is it worth the multi-hour mesa3d/Xorg/GTK3 build (plus likely
render-debug, software GL on virtio-gpu is finicky) to get a concrete **RAM number + screenshot**,
or does the dependency analysis above already answer the "is it viable on 128 MB" question?

Status: scaffold + dependency analysis done; full build gated on the human's call (cost vs value).
