# KlipperScreen feasibility notes

ReForge ships GuppyScreen. The KlipperScreen study looked at running a GTK3
and Python UI with an X11 or Wayland stack on the 128 MB AD5M. No ReForge build,
QEMU render or RAM measurement was completed. The touchscreen evaluation moved
to [HelixScreen](../helixscreen-eval/README.md).

## Existing AD5M build

The xblax `flashforge_ad5m_klipper_mod` project supplies
`variant-klipperscreen`. It uses Xorg on the framebuffer and Mesa's software
GL. The project warns that this variant uses more RAM than the default.

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


## QEMU port notes

The proposed QEMU port would replace the Allwinner Xorg driver with
`xf86-video-fbdev`, render a GTK demo first, then run KlipperScreen against
the same simulated Klipper and Moonraker stack as GuppyScreen. The comparison
would capture the 800×480 framebuffer and sample each UI's RSS.

The earlier Wayland proposal used cage with wlroots and Pixman. The Buildroot
recipe examined then required EGL, GLES and GBM, so QEMU without virgl would
need software GL. GTK Broadway renders to a browser, outside the framebuffer
comparison.
