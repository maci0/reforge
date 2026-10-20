# ReForge qemu test harness

Run + test the ReForge userland (install flow, boot, web stack, on-screen GUI) on
an x86 host with **no printer** — under `qemu-system-arm`. This documents how the
test kernel is built, how the framebuffer is pinned to the real panel, and how to
drive it.

> **Test-only.** Everything here (the kernel, the framebuffer config, the `init.c`)
> exists purely to emulate the system for testing. **None of it ships** in ReForge.
> The product runs the stock vendor kernel; this harness runs a re-configured kernel
> that boots under qemu's generic `virt` machine.

## Why a separate kernel?
The printer's stock kernel is a vendor Allwinner **T113-S3 (sun8iw20)** BSP. qemu has
**no T113/sun8iw20 machine model**, so the stock kernel cannot boot in qemu (it can't
find its UART/clocks/timer). We instead build a kernel for qemu's **`-M virt`** machine
(generic ARMv7 + virtio), from the **same 5.4.61 vendor source** so the userland ABI
matches the stock 5.4 userland (important for the firmwareExe spike).

## Building the test kernel — `make qemu-kernel`

Source: the in-repo vendor tree `vendor/kernels/tina-bsp-kernel` (Allwinner sun8iw20,
**Linux 5.4.61** — same version as stock). Toolchain: the kernel.org crosstool
**GCC 9.5** at `vendor/toolchains/gcc-9.5.0-nolibc/arm-linux-gnueabi/bin/arm-linux-gnueabi-`.
Built **out-of-tree** (`O=tests/qemu-harness/build/kbuild`) so the source stays clean.

Config = `multi_v7_defconfig` + the fragment in `configs/virt.fragment`:

**Disable (the critical fix):**
- `ARCH_SUNXI` — **this is the fix.** `multi_v7_defconfig` pulls in Allwinner's legacy
  sun4i/sun9i clock drivers (`drivers/clk/sunxi/clk-mod0.c`), which **don't compile**
  against the vendor's patched `clk-factors` infra (`struct factors_data` lost its
  `getter` member, `sunxi_factors_register_critical` undeclared, etc.). A `virt` kernel
  needs **zero** sunxi drivers, so disabling `ARCH_SUNXI` drops the broken code entirely.
- Also `CLK_SUNXI`, `SUNXI_CCU`, `COMMON_CLK_SUNXI`, `CLK_SUNXI_*` (mostly auto-off via
  the `ARCH_SUNXI=n` dependency chain).

**Enable:**
- `ARCH_VIRT` + `ARCH_MULTI_V7` (qemu virt machine)
- `VIRTIO`, `VIRTIO_PCI`, `VIRTIO_MMIO`, `VIRTIO_BLK`, `VIRTIO_NET`, `VIRTIO_INPUT`
- `DRM`, `DRM_VIRTIO_GPU`, **`DRM_FBDEV_EMULATION`** (this is what creates `/dev/fb0`)
- `EXT4_FS`, `DEVTMPFS`(+`_MOUNT`), `BLK_DEV_INITRD`
- `SERIAL_AMBA_PL011`(+`_CONSOLE`) — the virt machine's console (`ttyAMA0`)

Output: `tests/qemu-harness/build/zImage` (gitignored). Build ≈ 25 min.

If the vendor source is ever truly unbuildable for virt, the script falls back to
**mainline `linux-5.4.61`** (`vendor/kernels/linux-5.4.61`) — same version, clean.
**Never** mainline 6.x (wrong ABI for the spike).

## Framebuffer — pinned to the real panel (800×480×32)

The AD5M Pro panel (measured on the live unit): **800×480 visible, 32 bpp (xRGB8888),
virtual 800×960**. The harness reproduces exactly that so GuppyScreen/firmwareExe render
pixel-identical.

**Method that works:** virtio-gpu + DRM fbdev emulation:
```
qemu-system-arm -M virt,highmem=off ... -device virtio-gpu-pci,xres=800,yres=480
```
With `DRM_VIRTIO_GPU` + `DRM_FBDEV_EMULATION` in the kernel, this registers
`/dev/fb0` as `virtio_gpudrmfb` at exactly **800×480×32**:
```
virtio_gpu virtio1: fb0: virtio_gpudrmfb frame buffer device
/sys/class/graphics/fb0/virtual_size   -> 800,480
/sys/class/graphics/fb0/bits_per_pixel -> 32
```

**The `highmem=off` gotcha (essential):** without it, qemu `-M virt` puts the PCIe ECAM
window at a 64-bit address (>4 GiB). The 32-bit ARM `pci-host-generic` driver in 5.4
**can't claim it** → `probe of ...pcie failed with error -16 (-EBUSY)` → the whole PCI
bus fails → no virtio-gpu → **no fb0**. `highmem=off` relocates ECAM to a 32-bit address
(`0x3f000000`), PCI enumerates, and the GPU appears.

**What does NOT work (don't bother):**
- `video=simplefb:800x480-32` — qemu virt provides no simple-framebuffer (simplefb needs
  a real fb region pre-set by firmware). Produces **no** `/dev/fb0`.
- `-device ramfb` — does nothing without EDK2/UEFI pflash firmware to back it.

## Running things — `run-qemu.sh`

```
tests/qemu-harness/run-qemu.sh <root-image-or-initramfs> [OPTIONS] [-- EXTRA_QEMU_ARGS...]
```
- `<root>`: an `.ext4` (booted as a virtio-blk root, `/dev/vda`) or a `.cpio[.gz]` initramfs (auto-detected).
- `--usb <file>`: attach a 2nd virtio-blk drive (`/dev/vdb`) carrying a file (e.g. a `.tgz` "USB stick" for the update test).
- `--vnc`: `-display vnc=:0` + a QEMU monitor unix socket (`build/qemu-monitor-<pid>.sock`) so you can `screendump` the framebuffer (for GUI render checks).
- `--timeout N` (default 120s; `0` = no timeout), `--log <file>`, `--dry-run`.
- `-- ...`: pass extra args straight to qemu (e.g. a user-net port-forward).

It always uses the proven args: `-M virt,highmem=off -cpu cortex-a7 -m 256
-device virtio-gpu-pci,xres=800,yres=480` + virtio-net + virtio HID.

**Grab a screenshot of the fb** (with `--vnc`): send `screendump out.ppm` to the monitor socket.

**Live web stack** (reach Moonraker from the host): add a port-forward —
```
run-qemu.sh root.ext4 -- -netdev user,id=n1,net=10.0.3.0/24,hostfwd=tcp::17125-:7125 \
                          -device virtio-net-pci,netdev=n1
curl http://127.0.0.1:17125/server/info
```
(Use a **separate slirp subnet** for the forwarded NIC — sharing `10.0.2.0/24` with the
default NIC causes routing conflicts where TCP connects but HTTP hangs.)

## Make targets
| target | what |
|---|---|
| `make qemu-kernel` | build the virt test kernel (`build/zImage`) |
| `make qemu-smoke` | boot a tiny initramfs, assert fb0 = 800×480×32 |
| `sudo make qemu-stock-rootfs` | extract stock rootfs (`mmcblk0p6`) from the golden dump → `build/stock-rootfs.ext4` (loop-mounts → sudo) |
| `sudo make qemu-update` | install ReForge into an ext4 + boot it under the test kernel → assert Moonraker live (LIVE) or services-started (FLOOR) |

## Files
- `build-test-kernel.sh` — builds the kernel (+ a static `init.c` initramfs for the smoke).
- `configs/virt.fragment`, `configs/qemu-virt-fb.fragment` — the config deltas documented above.
- `configs/init.c` — minimal raw-ARM-syscall init for the smoke (no libc).
- `extract-stock-rootfs.sh`, `run-qemu.sh`, `update-process-test.sh` — see above.
- `build/` — all build artifacts (zImage, ext4 images, logs). **gitignored.**

## Storage device names (real-hw fidelity)

Harness storage is built through `lib/` so tests model the real eMMC/USB device names
instead of virtio `vda`:
- `lib/emmc.sh` — `emmc_build` / `emmc_build_p6` wrap a rootfs (+ optional `/data`) in a
  production-shape GPT eMMC via `lib/build-emmc-image.sh`, so it enumerates as
  **`/dev/mmcblk0p1..p7`** (boot `${EMMC_ROOT}` = `/dev/mmcblk0p6`) exactly like the onboard
  eMMC; `usb_args` attaches the live USB as **`/dev/sda`**.
- `lib/common.sh` — `mkext4` builds ext4 with `orphan_file` disabled so the BSP 5.4 guest
  kernel can mount it (e2fsprogs ≥ 1.47 defaults that feature on, and 5.4 rejects it).

On the eMMC model: the `live-*` / `pid1-pivot` / `overlayfs-spike` / `stock-preinit` set,
plus `stockui-realklippy`, `stockui-render`, `serve-webui`, `shots-capture`.

Deliberately still on virtio (`/dev/vda`): the render/probe rigs that attach a 2nd disk the
guest addresses as `/dev/vdb` (`mem-probe`, `guppy-render`, `run-qemu`, `ota-test`) — moving
the rootfs to eMMC would shift that disk to `vda` and need in-guest ref surgery for no
functional gain; `shots-reforge` (its committed screenshots stay cleanest booting its own
rootfs as root); `vmtune-bench` (per-mode disk copies); and `ota-klipper-e2e` (a delicate
multi-stage OTA test whose pass depends on klippy reaching `klippy_identified` inside a tight
window — the extra eMMC boot-time variance made it flaky, so it stays on the faster virtio
boot). Every `mke2fs` in the suite still routes through the `orphan_file`-disable flag.

## Known limits (honest)
- **Motion/print sim is opt-in.** Most rigs start klippy with no MCU (`klippy_state` waiting);
  the dedicated `stockui-realklippy` rig runs real klippy against a Linux **host MCU** and
  reaches `ready` (both MCUs configured), driving the stock UI. Full motion/print is still
  out of scope.
- Stock-firmware *full* boot under qemu is out of scope (needs the T113 machine model);
  the update test installs via filesystem ops + boots the ReForge stack instead.
</content>

## Screenshots
Captured GUI renders (GuppyScreen; firmwareExe result) are in [`docs/screenshots/`](../../docs/screenshots/README.md) — all at the pinned 800x480, pixel-identical to the real panel.

## Forge-X API probe

`python3 tests/qemu-harness/board_mcu.py --self-test` checks the simulated
N32G455 wire protocol without a guest. `tests/qemu-harness/api-probe-forgex.sh`
boots working copies of `build/forgex-rootfs.ext4` and `build/forgex-data.ext4`
with `build/zImage`, waits for Klippy readiness, and captures read-only API
responses under `build/api-probe-forgex/`. Those source images are local fixtures,
not distributed firmware. The probe terminates only its own QEMU process.

Set `PHOBOS_BIN` to an absolute static ARM binary path to also run Phobos on
guest port 7126 with a private database. Host forwards bind
to loopback; `HOST_PORT`, `KLIPPY_PORT`, and `PHOBOS_HOST_PORT` select their ports.
