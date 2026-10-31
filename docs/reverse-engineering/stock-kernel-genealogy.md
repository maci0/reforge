# Stock kernel genealogy — from mainline Linux to the AD5M printer

Where the AD5M/Pro's stock kernel actually comes from: the Allwinner SoC vendor
fork, the Tina-Linux distro, the **automotive** SDK variant it was cut from, the
exact Wi-Fi driver, and which parts are public vs behind an Allwinner NDA.

Companion to [`stock-rootfs-provenance.md`](../board-notes/stock-rootfs-provenance.md)
(which splits the *userland* into Tina-vs-FlashForge) and
[`stock-kernel-byte-identical-build.md`](stock-kernel-byte-identical-build.md)
(reproducing the `uImage`). This doc is the *lineage* and the **NDA boundary**.

Everything below the "what we can prove" line is extracted directly from the
shipped artifacts (the `8821cu.ko` module, the `uImage`, the stock
`/proc/config.gz` we captured); the SDK/NDA context is cited.

## The chain

```
Linux 5.4 (mainline, kernel.org)
  └─ Allwinner sunxi vendor kernel — "linux-5.4" BSP branch for sun8iw20 (T113)
       heavily patched: DISP2, G2D, VIN, Cedar/VE, CAN, arisc, SPI-NAND, …
       └─ Tina-Linux  (Allwinner's Buildroot-derived distro; brand "KunoOS Platform")
            └─ T113-Linux-Auto-v1.1   ← the AUTOMOTIVE SDK variant
                 └─ FlashForge AD5M/Pro printer build  →  uImage, Linux 5.4.61
```

- **SoC:** Allwinner **T113-S3** = `sun8iw20` — dual Cortex-A7 (ARMv7), with
  **128 MB DDR3 in-package (SiP)**, marketed by Allwinner for **automotive and
  industrial** use (CNX Software). Public datasheet: **T113-s3 v1.6** on
  linux-sunxi.org. It is the ARM sibling of the RISC-V D1/D1-H (same `sun8iw20`
  platform, shared Tina SDK).
- **Kernel base:** Allwinner's vendor **`linux-5.4`** branch (not a mainline
  5.4.61 — a BSP fork with hundreds of out-of-tree sunxi drivers), tagged by FF's
  build at **5.4.61**, `CONFIG_ARCH_SUN8IW20=y`, `CONFIG_SUNXI_SOC_NAME="sun8iw20"`.
- **Built with:** `arm-linux-gnueabi-gcc (Linaro GCC 5.3-2016.05) 5.3.1` — the
  ancient toolchain that ships *inside* the Tina SDK (`CONFIG_CC_VERSION_TEXT`).
  This is why the stock kernel is a 2016-era-toolchain 5.4 build.

## The "automotive addon" — T113-Linux-Auto-v1.1

The SDK FlashForge cut from is literally named **`T113-Linux-Auto-v1.1`** — the
**automotive** ("Auto") Tina variant, not the generic T113 Tina4 SDK. Two
independent proofs from the shipped kernel:

1. **Build path leaked in `8821cu.ko`** (debug strings, verbatim):
   `/home/linux/work/hard_t113/T113-Linux-Auto-v1.1/kernel/linux-5.4/drivers/staging/rtl8821cu/...`
2. **CAN bus compiled in:** `CONFIG_CAN=y`, `CONFIG_CAN_RAW/BCM/GW=y`, and
   crucially **`CONFIG_CAN_SUN8I=y`** — the Allwinner on-SoC CAN controller. CAN
   is an automotive/industrial bus; the printer has no CAN, so this is inherited
   wholesale from the Auto config and never stripped (same pattern as the
   unstripped `BR2_PACKAGE_ALL` userland — see provenance doc).

Public mirror of this SDK family: the **Allwinner-Homlet** GitHub org
(`Allwinner-Homlet/T113-Linux-Auto-v1.1`) — part of **AWOL** (Allwinner Open
Linux), the no-NDA release track.

## Wi-Fi driver — exact version

The only out-of-tree module shipped (`/lib/modules/5.4.61/8821cu.ko`):

| field (`modinfo`) | value |
|---|---|
| chip | **Realtek RTL8821CU** (USB Wi-Fi + BT combo) |
| driver version | **`v5.12.0-16-g5229e7f95.20210118_COEX20200730-5151`** |
| → decoded | Realtek out-of-tree driver **v5.12.0**, git `g5229e7f95`, source snapshot **2021-01-18**, BT-coex package **2020-07-30**, chip id 5151 |
| vermagic | `5.4.61 SMP preempt mod_unload ARMv7 p2v8` |
| license | GPL · author Realtek Semiconductor Corp. |
| in-tree path | `drivers/staging/rtl8821cu/` (Realtek's GitHub `rtl8821cu`/`8821cu` tree, dropped into the BSP's `staging`) |

So the Wi-Fi stack is a **2021-01 Realtek driver**, frozen — and **byte-identical
across every stock release 3.1.3 → 5.1.7** (see the
firmware changelog (workspace `fw-archive/analysis/stock-fw-changelog.md`): `kernel-2.1.6` never moves).

## What's layered on top of base Tina (the non-mainline sunxi subsystems)

Compiled into this kernel but **absent from mainline Linux 5.4** — these are
Allwinner BSP additions that define the platform:

| subsystem | config | what it is |
|---|---|---|
| Display Engine 2.0 | `CONFIG_DISP2_SUNXI=y` (+SMBL/ENHANCE) | the `/dev/disp` framebuffer/LCD pipeline (the device the GuppyScreen render fix had to make optional) |
| 2D accelerator | `CONFIG_SUNXI_G2D[_MIXER/_ROTATE]=y` | hardware blit/rotate |
| Video capture | `CONFIG_VIDEO_SUNXI_VIN=y` | camera/VIN (the AD5M camera path) |
| CAN | `CONFIG_CAN_SUN8I=y` | automotive CAN controller (unused on the printer) |
| Cedar / VE | sunxi VE | Allwinner's video engine (decode) — **userspace lib is proprietary**, see NDA |
| arisc / cpus, SPI-NAND, sunxi DMA/TWI/PWM | various `SUNXI_*` | the standard T113 BSP peripheral set |

On top of *that*, FlashForge layered only the printer userland (firmwareExe, the
Klipper/MCU stack) — **not** kernel changes; the kernel is stock Tina-Auto.

## Public vs NDA — where the boundary is

**Publicly obtainable (GPL-mandated or AWOL open track):**

- **Kernel source** — the sun8iw20 `linux-5.4` BSP is GPL; mirrored on the
  Allwinner-Homlet GitHub (`T113-Linux-Auto-v1.1`) and reconstructable from the
  shipped config. We already byte-reproduce the `uImage` from it.
- **Realtek 8821CU driver** — GPL, Realtek's public `rtl8821cu` tree (the exact
  v5.12.0/2021-01 snapshot is identifiable from `modinfo`).
- **Tina-Linux = Buildroot** — open; the package set is standard Buildroot.
- **T113-S3 datasheet v1.6** — on linux-sunxi.org (chip-level register overview).
- Everything in the shipped image (configs, DTB, modules, build paths) is, by
  definition, extractable — which is how this doc was written.

**Behind an Allwinner NDA / closed (the `allwinnertech` partner portal track):**

- **The official full Tina SDK** — Allwinner releases two tracks: open **AWOL**
  (no NDA) and the **NDA SDK** on the `allwinnertech` developer portal (partner
  registration). The complete, current Tina tree (with the exact patch set FF
  used) lives on the NDA side; AWOL/Homlet is a community-published slice.
- **Boot chain blobs** — `boot0`/SPL and the secondary program loader are
  Allwinner-proprietary binaries (not GPL kernel); shipped as blobs, not source.
- **CedarX VPU userspace** — the video-engine *kernel* driver is in the GPL tree,
  but the **CedarX codec libraries** (userspace `libcedarc`/VE firmware) are
  Allwinner-proprietary / NDA.
- **Full T113 user manual + register spec** — the public datasheet is a brief;
  the complete user manual (and any TF-A/secure-boot docs) is NDA.
- **DSP/HiFi firmware** is shipped as an Allwinner prebuilt and loaded by U-Boot
  from p5. The FreeRTOS kernel C component now reproduces byte-identically from
  public source; the complete firmware still has unresolved source/layout gaps.
  See the [DSP recipe and proof](../../lab/dsp-rebrew/README.md).

### Bottom line

The AD5M kernel is **stock Allwinner Tina-Auto** (`T113-Linux-Auto-v1.1`,
`linux-5.4` BSP, GCC 5.3) with a **2021-01 Realtek RTL8821CU** driver — all of it
GPL-public or reconstructable from the shipped image and the AWOL/Homlet mirror.
The only genuinely closed pieces are the standard Allwinner ones (boot0/SPL,
CedarX VPU userspace, the full NDA SDK tree and user manual) — none of which
ReForge needs, because we keep the stock kernel + modules byte-identical and only
replace userland.

## What we can prove (evidence index)

- `8821cu.ko` → `modinfo` version string + `drivers/staging/rtl8821cu` build path
  (`T113-Linux-Auto-v1.1/kernel/linux-5.4`).
- `stock-kernel-config-5.4.61.txt.gz` → `ARCH_SUN8IW20`, `SUNXI_SOC_NAME`,
  `CAN_SUN8I`, `DISP2_SUNXI`, `SUNXI_G2D`, `VIDEO_SUNXI_VIN`, `CC_VERSION_TEXT`.
- `/etc/issue` → "Welcome to Allwinner KunoOS Platform" (Tina brand).
- firmware changelog → `kernel-2.1.6` (Linux 5.4.61 + this driver) byte-identical
  3.1.3 → 5.1.7.

Sources for the SDK/NDA context: [CNX Software T113-S3](https://www.cnx-software.com/2022/02/13/allwinner-t113-s3-dual-core-cortex-a7-soc-features-128mb-ddr3-targets-automotive-and-industrial-applications/),
[linux-sunxi T113-s3](https://linux-sunxi.org/T113-s3),
[T113-s3 datasheet v1.6](https://linux-sunxi.org/File:T113-s3_datasheet_v1.6.pdf),
[Allwinner-Homlet (AWOL mirror)](https://github.com/Allwinner-Homlet).
