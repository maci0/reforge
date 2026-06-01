# vendor/ — third-party trees we don't author

Everything here is upstream code/toolchains. None of it is committed as files — it's
either a **git submodule** (pinned commit) or a **pinned tarball** (downloaded + sha256
verified). A fresh clone reconstructs it all with one command:

```sh
./vendor/fetch.sh
```

## What's vendored, and how

| path | upstream | pinned by | mechanism |
|---|---|---|---|
| `buildroot/` | gitlab.com/buildroot.org/buildroot @ `2026.02.2` | `.gitmodules` + `pins.lock` | git submodule |
| `kernels/tina-bsp-kernel/` | github.com/iLotusK9/linux_kernel_aw_t113 branch `5.4.61` (`349a0b9`) | `.gitmodules` + `pins.lock` | git submodule |
| `toolchains/gcc-9.5.0-nolibc/` | kernel.org crosstool GCC 9.5.0 `arm-linux-gnueabi` (nolibc) | `pins.lock` sha256 | tarball, fetched + verified |

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
