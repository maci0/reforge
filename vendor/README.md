# vendor/ — third-party trees we don't author

Upstream source trees are **git submodules** pinned to commits; toolchains are
**pinned tarballs** downloaded and checked by SHA-256. Build patches and small source
excerpts are committed as files with their provenance. A normal rootfs needs only
the submodules (`git submodule update --init --recursive`) and builds with Buildroot's
internal toolchain. `./vendor/fetch.sh` also downloads the optional external GCC 9.5
crosstool (and Linaro 5.3.1 when `FETCH_LINARO=1`). On a clean clone that script writes
its tarball under `vendor/toolchains/` without creating the directory, so create it first:

```sh
mkdir -p vendor/toolchains
./vendor/fetch.sh
```

## What's vendored, and how

| path | upstream | pinned by | mechanism |
|---|---|---|---|
| `buildroot/` | gitlab.com/buildroot.org/buildroot @ `2026.08.1` | `.gitmodules` + `pins.lock` | git submodule |
| `kernels/tina-bsp-kernel/` | github.com/iLotusK9/linux_kernel_aw_t113 branch `5.4.61` (`349a0b9`) | `.gitmodules` + `pins.lock` | git submodule |
| `toolchains/gcc-9.5.0-nolibc/` | kernel.org crosstool GCC 9.5.0 `arm-linux-gnueabi` (nolibc) | `pins.lock` sha256 | tarball, fetched + verified |
| `toolchains/gcc-linaro-5.3.1-…/` | Linaro GCC 5.3-2016.05, the compiler stock FlashForge used | `pins.lock` sha256 | tarball, fetched only with `FETCH_LINARO=1` (stock-reproduction builds) |
| `kernels/patches/` | local patches for the pinned BSP | [patch documentation](kernels/patches/README.md) | tracked patch files |
| `kernels/stock-patches/` | patches for the stock-kernel reproduction (`tools/build/build-bsp-kernel-stock.sh`) | `pins.lock` (`stock-kernel`, `stock-rtl8821cu`) | tracked patch files. The caller supplies the hash-pinned kernel and Wi-Fi source archives; the script checks them and does not download them. Recipe: [current command](../docs/board-notes/stock-bringup-rebuild.md#current-kernel-and-wi-fi-reproduction-command) |
| `kernels/linux-7.3/` | kernel.org Linux 7.3 | `pins.lock` (`linux-mainline`) sha256 | tarball, fetched by `make kernel-mainline`; gitignored |
| `optee/` | OP-TEE 3.7.0 reconstruction research and standby sources | [OP-TEE research](optee/stock-patches/README.md), [standby](optee/standby-src/README.md), [host helpers](optee/standby-host-src/README.md) | tracked sources and patches; not part of the shipping image |
| `runtime/gcc-7.2.0-arm/` | unmodified GCC 7.2.0 `libgcc/config/arm` files | [runtime source](runtime/gcc-7.2.0-arm/README.md) | tracked source for the boot0 reproduction |
| `upstream-snippets/` | individual upstream source excerpts | [PWM source provenance](upstream-snippets/pwm-sunxi-g_dev/README.md) | tracked source with its original license header |

The BSP (`tina-bsp-kernel`) is the **layout-exact** stock-kernel source — the build target
for both the zram modules (`modules/zram-bsp/`) and the qemu virt test kernel
(`tests/qemu-harness/`). Upstream mainline `linux-5.4.61` Oopsed (vendor `struct page`
layout differs), so we build against the BSP, not mainline.

## Why the toolchain isn't a submodule

It's a **binary tarball**, not a git repo — there's nothing to submodule. We pin it by the
**sha256 of the exact artifact we build with** (in `pins.lock`), which is stronger than
trusting a mutable mirror: `fetch.sh` downloads from the URL and refuses to proceed if the
hash doesn't match.

## Not vendored by default: upstream mainline linux-5.4.61

Only needed as (a) a last-resort qemu-kernel fallback if the BSP is ever unbuildable, or
(b) a reference to diff against the BSP when porting. Fetch it manually into
`vendor/kernels/linux-5.4.61.tar.xz` from kernel.org if you need it; nothing requires it
for a normal build.

## Gitignore

`buildroot/` and `kernels/tina-bsp-kernel/` are tracked **as submodule gitlinks** (their
working trees are managed by their own git). The toolchain extract, any fetched mainline
tarball, and downloaded archives are gitignored — see the repo-root `.gitignore`.
