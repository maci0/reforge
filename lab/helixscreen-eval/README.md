# HelixScreen QEMU evaluation

HelixScreen is an optional LVGL 9 touchscreen UI that draws directly to
`/dev/fb0`, like GuppyScreen. It needs no display server or Python UI stack.
The [Buildroot package](../../br-external/package/helixscreen/helixscreen.mk)
is disabled in the default image. It builds and installs the main executable
and assets under `/opt/helixscreen`. The splash and watchdog helpers are outside
this build.

## Build and render

Enable `BR2_PACKAGE_HELIXSCREEN` in a separate Buildroot output directory so
the default rootfs stays available. From the repo root, after initializing the
submodules and building the [QEMU test kernel](../../tests/qemu-harness/README.md#building-the-test-kernel--make-qemu-kernel):

```sh
out="$PWD/build/output-helix"
make -C vendor/buildroot BR2_EXTERNAL="$PWD/br-external" O="$out" reforge_defconfig
make -C vendor/buildroot O="$out" menuconfig
# Search for BR2_PACKAGE_HELIXSCREEN, enable helixscreen, then save.
make -C vendor/buildroot O="$out"
ROOTFS_TAR="$out/images/rootfs.tar.xz" make qemu-helix
```

See the [QEMU harness prerequisites](../../tests/qemu-harness/README.md). The
harness substitutes a simulated Klipper connection and starts the UI through
`SCREEN_MODE=HELIX` and `S76helixscreen`. It writes a monitor screenshot
(`helix-home.ppm`) and a serial log under `tests/qemu-harness/build/`. If
ImageMagick's `magick` is installed and the guest dumps its framebuffer, the
script also writes `helix-home.png`.

The v1.0.11 ARM build rendered the first-run orientation check at 800×480 in
QEMU. This verifies startup and framebuffer output. Physical panel behavior,
helper binaries and RAM use under printer workloads remain unverified.

## Earlier QEMU memory comparison

The June 2026 run used the earlier HelixScreen pin and `MEM=256`, with the
same Moonraker and simulated Klipper processes. The test sampled process
`VmRSS` during early boot:

| UI | RSS | Screen |
|---|---:|---|
| GuppyScreen | ~8.2 MB | Home |
| HelixScreen | ~11.7 MB | First-run language picker |

HelixScreen used ~3.5 MB more (~43% above GuppyScreen). Moonraker used ~39 MB
and simulated Klipper ~7.5 MB. The guest reported ~167 MB `MemAvailable` out
of 238 MB with each UI. These samples do not establish footprint on the
128 MB printer or after loading the full UI and assets (~73 MB in that build).
The stripped executable measured 9.4 MB, and the captured wizard had 2,417 colors.
See the [screenshot from that run](../../docs/screenshots/helixscreen-qemu-800x480.png).

## Port notes

The package follows the AD5M variant from xblax's PR #367. Buildroot passes
cross-toolchain flags through the environment so nested makefiles can add
their own includes. The package prepares the extracted LVGL and libhv sources
for upstream's `git apply`, keeps libhv static, drops host-only search paths,
and builds the bundled wpa client against Buildroot's libnl. `PLATFORM_TARGET`
and `CROSS_COMPILE` select the embedded linker rules. The recipe carries the
exact fixes and the current commit pin. [HelixScreen upstream](https://github.com/prestonbrown/helixscreen).
