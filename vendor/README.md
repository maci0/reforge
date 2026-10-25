# vendor/ — third-party trees we don't author

Upstream source trees are **git submodules** pinned to commits; toolchains are
**pinned tarballs** downloaded and checked by SHA-256. Build patches and small source
excerpts are committed as files with their provenance. Fetch the source trees and toolchains with:

```sh
./vendor/fetch.sh
```

## What's vendored, and how

| path | upstream | pinned by | mechanism |
|---|---|---|---|
| `buildroot/` | gitlab.com/buildroot.org/buildroot @ `2026.08.1` | `.gitmodules` + `pins.lock` | git submodule |
| `kernels/tina-bsp-kernel/` | github.com/iLotusK9/linux_kernel_aw_t113 branch `5.4.61` (`349a0b9`) | `.gitmodules` + `pins.lock` | git submodule |
| `toolchains/gcc-9.5.0-nolibc/` | kernel.org crosstool GCC 9.5.0 `arm-linux-gnueabi` (nolibc) | `pins.lock` sha256 | tarball, fetched + verified |
| `kernels/patches/` | local patches for the pinned BSP | [patch documentation](kernels/patches/README.md) | tracked patch files |
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
