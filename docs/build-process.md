# ReForge build process

How sources become the firmware image. Everything is **pinned** (`pins.lock`) and reproducible:
`vendor/fetch.sh` reconstructs the third-party trees, `make rootfs` builds the rootfs via
Buildroot, and `make tgz` packages the USB installer.

## Pipeline

```mermaid
flowchart TB
    PINS["pins.lock<br/>(authoritative versions)"] --> FETCH

    subgraph vendor["vendor/ (third-party, pinned)"]
        BR["buildroot<br/>(submodule, 2026.02.2)"]
        BSP["kernels/tina-bsp-kernel<br/>(submodule, T113 5.4.61)"]
        TC["toolchains/gcc-9.5.0<br/>(tarball, sha256 — kernel-module crosstool ONLY)"]
    end
    FETCH["./vendor/fetch.sh"] --> vendor

    subgraph src["source we author"]
        EXT["br-external/<br/>configs · packages · rootfs-overlay · board"]
        PATCH["package patches<br/>(klipper ×6, moonraker ×2, guppyscreen ×3)"]
    end

    BR --> MK["make rootfs<br/>(tools/build/build.sh)"]
    EXT --> MK
    PATCH --> MK
    MK -->|"BR2_EXTERNAL=br-external<br/>reforge_defconfig<br/>Buildroot-internal gcc 15.2 · Thumb-2 / -Os / glibc"| BUILD

    subgraph BUILD["Buildroot build"]
        direction LR
        PY["python3"] --- KLP["klipper +<br/>NEON c_helper.so"] --- MOO["moonraker"]
        MAIN["mainsail (SPA)"] --- GUP["guppyscreen"] --- ZR["reforge-zram"]
    end

    BUILD --> OUT["build/output/images/<br/>rootfs.tar(.xz)"]
    OUT --> TGZ["make tgz<br/>(packaging/build-tgz.sh)"]
    TGZ --> DIST(["packaging/dist/<br/>reforge-<ver>.tgz  (USB installer)"])

    BSP --> ZMOD["modules/zram-bsp/build.sh<br/>→ dist/*.ko (vermagic-matched)"]
    TC --> ZMOD
    ZMOD -. shipped in overlay .-> ZR
```

## Steps

| command | does | output |
|---|---|---|
| `./vendor/fetch.sh` | init submodules (buildroot, BSP kernel) + download+verify the toolchain | `vendor/*` |
| `make defconfig` | apply `reforge_defconfig` to Buildroot | `build/output/.config` |
| `make rootfs` | full Buildroot build (toolchain + all packages) | `build/output/images/rootfs.tar(.xz)` |
| `make kernel` | build the in-tree Tina BSP 5.4.61 kernel (device config, `-Os`) via Buildroot's own gcc-15 toolchain — additive to the standalone `build-bsp-kernel*.sh` scripts | `build/output/images/zImage` |
| `make kernel-virt` | same BSP source, qemu-`virt` config — the bootable test kernel for the harness | `build/output/images/zImage` |
| `make tgz` | wrap the rootfs as a stock-format USB installer | `packaging/dist/reforge-<ver>.tgz` |
| (in `modules/zram-bsp/`) `build.sh` | build zram/zsmalloc `.ko` against the BSP kernel (gcc 9.5 crosstool, vermagic-matched) | `dist/*.ko` (shipped in the overlay) |

The single `reforge_defconfig` builds the **whole stack** (klipper + moonraker + mainsail +
guppyscreen + zram, plus `dinit` — shipped as a future-`switch_root` init building block, not
yet wired); `SCREEN_MODE` picks headless vs on-screen at runtime, so there is one image.

## Consumers of the build

```mermaid
flowchart LR
    OUT["build/output<br/>(rootfs.tar.xz)"] --> H1["tests: qemu harness<br/>(virt kernel from BSP, boot/render/web)"]
    OUT --> H2["tests: smoke / integration<br/>(qemu-user)"]
    OUT --> H3["tools/release/build-release.sh<br/>→ per-component OTA zips (shipped)"]
    OUT --> H4["packaging → USB .tgz"]
```

- **Tests** (`tests/`) boot the rootfs under `qemu-system-arm` (a virt-machine kernel built from
  the same BSP source) or `qemu-arm-static` — no printer. See `tests/README.md`.
- **OTA release** (implemented): `build-release.sh` slices the same `build/output` into per-component
  zips — see [`docs/ota.md`](ota.md).

## Reproducibility

`BR2_REPRODUCIBLE=y` + the pinned `pins.lock` + submodule commits make builds deterministic;
`make repro` does a twin-build diff. Kernel headers are pinned to the stock 5.4.61 ABI so the
glibc userland's "min kernel" note matches the device (else the loader aborts `FATAL: kernel too
old`).
