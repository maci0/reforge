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

## Finding from the dependency analysis (before building)

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
