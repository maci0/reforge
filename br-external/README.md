# br-external/ — the ReForge firmware (Buildroot BR2_EXTERNAL tree)

This is the product core: a Buildroot external tree (name `REFORGE`) that builds the whole
rootfs. Built via `make rootfs` (→ `build/output/`).

| path | what |
|---|---|
| `configs/reforge_defconfig` | the single defconfig — full stack (python3 + klipper + moonraker + mainsail + guppyscreen + zram), glibc, Thumb-2/-Os, kernel-headers pinned to stock 5.4.61. `SCREEN_MODE` gates the on-screen GUI at runtime, so there is one image for headless and on-screen. |
| `package/` | ReForge's own Buildroot packages: `klipper` (v0.11, default), `klipper13` (optional v0.13 host + MCU firmware), `moonraker`, `mainsail`, `guppyscreen`, `helixscreen` (lab), `dinit`, `reforge-zram`, python deps. |
| `board/reforge/` | `rootfs-overlay/` (init scripts `S00cloudblock`…`S99ok`, staged `etc/dinit.d/`, `/etc/reforge/*.conf`, the fire/ember boot banner), `post-build.sh` (assembles `/mod`), kernel configs (`linux.config` device, `linux-virt.config` qemu, `linux-mainline-t113.config`), `board.dts`, and `stock/` + `virt/` board data. |
| `external.desc`, `external.mk`, `Config.in` | Buildroot external-tree glue. |
| [`local.mk`](local.mk) | BSP source override, device/virt kernel selection and OpenSSL version override. |
| [`patches/`](patches/) | Buildroot global patch directory, including versioned OpenSSL source hashes. |

The printer keeps the stock 5.4.61 kernel and bootloader. The rootfs image does
not install a kernel or bootloader. Default `make rootfs` still builds the BSP
kernel (`BR2_LINUX_KERNEL=y`, device `linux.config`, Tina source via `local.mk`)
with Buildroot's internal toolchain, because `reforge-zram` depends on that
`linux` package. The resulting `zImage` stays a build artifact; it is not copied
onto the printer. Userspace is GCC 15, glibc, Thumb-2, `-Os`, and this path does
not need `./vendor/fetch.sh`. `make kernel` / `make kernel-virt` build only that
BSP kernel (device config and qemu test config). `make kernel-mainline` builds a
separate size-proxy mainline kernel and is never flashed. No U-Boot package is
selected.
