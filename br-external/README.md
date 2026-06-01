# br-external/ — the ReForge firmware (Buildroot BR2_EXTERNAL tree)

This is the product core: a Buildroot external tree (name `REFORGE`) that builds the whole
rootfs. Built via `make rootfs` (→ `build/output/`).

| path | what |
|---|---|
| `configs/reforge_defconfig` | the single defconfig — full stack (python3 + klipper + moonraker + mainsail + guppyscreen + zram), glibc, Thumb-2/-Os, kernel-headers pinned to stock 5.4.61. `SCREEN_MODE` gates the on-screen GUI at runtime, so there is one image for headless and on-screen. |
| `package/` | ReForge's own Buildroot packages: `klipper`, `moonraker`, `mainsail`, `guppyscreen`, `reforge-zram`, python deps, etc. |
| `board/reforge/` | `rootfs-overlay/` (init scripts `S60klipper`…`S75guppyscreen`, `/etc/reforge/*.conf`, the fire/ember boot banner, busybox httpd config fragment), `post-build.sh`. |
| `external.desc`, `external.mk`, `Config.in` | Buildroot external-tree glue. |

The kernel + bootloader are intentionally **not** built here for P1–P3 (the image rides the
stock 5.4.61 kernel); Plan 5 adds a mainline kernel + U-Boot.
