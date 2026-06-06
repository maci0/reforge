# Reproducing the stock FlashForge AD5M Pro eMMC image with Allwinner Tina/T113 BSP

**Scope:** READ-ONLY analysis of the stock golden eMMC image + the vendored Tina BSP kernel,
to determine whether a ~1:1 reproduction is feasible and to document how FlashForge most
likely built the stock image.

**Target SoC:** Allwinner T113-S3 (`sun8iw20p1`, die-compatible with R528). Dual Cortex-A7
+ HiFi4 (Xtensa LX7) DSP + RISC-V (E907) — only the A7 + DSP are used by stock.

**Artifacts inspected (by path/hash, no blobs copied):**

| artifact | path | note |
|---|---|---|
| golden image (gz) | `tools/recovery/golden.img.gz` | sha256 `880edd11d9ee45bb05dfc9fd19bd37ba8ccb505f2eb37177e92baa9891e7ead7`, 7 818 182 656 B uncompressed |
| golden image (raw) | `tests/qemu-harness/build/golden-raw.img` | decompressed, read via `sfdisk -d` + byte-offset `dd` |
| clean p6 rootfs | `tests/qemu-harness/build/stock-clean-rootfs.ext4` | read via `debugfs`/`dumpe2fs` |
| Tina BSP kernel | `vendor/kernels/tina-bsp-kernel/` | Linux 5.4.61, `arch/arm/configs/sun8iw20p1smp_t113_auto_defconfig` |

All offsets below are 512-byte sectors unless stated; sector size = 512.

---

## 1. Partition / image structure (GPT)

`sfdisk -d tests/qemu-harness/build/golden-raw.img`:

```
label: gpt
label-id: AB6F3888-569A-4926-9668-80941DCB40BC
first-lba: 73728   last-lba: 15269854   table-length: 7   sector-size: 512
```

| # | name | start (sec) | size (sec) | byte offset | size | type GUID | contents (verified) |
|---|---|---|---|---|---|---|---|
| p1 | boot-resource | 73728 | 68876 | 0x2400000 (37 748 736) | 33.6 MiB | EBD0A0A2 (Linux) | **FAT16** ("Volumn") — uImage, sunxi.dtb, logos, fonts, battery icons |
| p2 | env | 142604 | 2048 | 73 013 248 | 1.0 MiB | EBD0A0A2 | U-Boot environment (plaintext key=val) |
| p3 | env-redund | 144652 | 2048 | 74 061 824 | 1.0 MiB | EBD0A0A2 | redundant copy of p2 (identical env) |
| p4 | boot | 146700 | 70400 | 75 110 400 | 34.4 MiB | EBD0A0A2 | **Android boot image** (`ANDROID!`) — kernel+ramdisk |
| p5 | dsp0 | 217100 | 2048 | 111 155 200 | 1.0 MiB | EBD0A0A2 | **Xtensa ELF** — HiFi4 DSP firmware |
| p6 | rootfs | 219148 | 2621440 | 112 203 776 | 1.25 GiB | EBD0A0A2 | **ext4** rootfs (Buildroot + FF app) |
| p7 | UDISK | 2840588 | 12429267 | 1 454 380 ... | ~5.93 GiB | EBD0A0A2 | user `/data` (ext4) |

Notes:
- All seven partitions use type GUID `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7` (generic "Linux
  filesystem"), partition GUIDs are sequential (`...8B2E45`, `...46`, `...47` …) and
  `attrs="GUID:63"` (Allwinner sets bit 63). This sequential, hand-assigned scheme is the
  fingerprint of the **Allwinner `sunxi-pack` partition builder** generating the GPT from a
  `sys_partition.fex`, not of `parted`/`fdisk`.
- `first-lba = 73728` (= 36 MiB): the first 36 MiB ahead of p1 is **reserved for the
  bootloader package** (boot0/SPL + dual U-Boot/TOC1 — see section 2).
- p2 == p3: the env strings match; both carry the same `bootcmd`. This is U-Boot's
  redundant-env (CONFIG_ENV_OFFSET_REDUND) scheme, written once by the packer.

### p1 boot-resource (FAT16, label "Volumn")

`mdir`/`mcopy` (mtools, `MTOOLS_SKIP_CHECK=1`) listing:

```
font32.sft  357443      fastbootlogo.bmp 1152054   font24.sft 344813
uImage      5195072     sunxi.dtb  55093           bootlogo.bmp 1152054
magic.bin   512         lcd_compatible_index.txt 16
wavefile/   (default_5_8.awf, vcom.bin, default.awf)
bat/        (bat0..bat10.bmp, battery.bmp, battery_charge.bmp, bempty.bmp, low_pwr.bmp)
```

- `uImage` = **legacy U-Boot uImage**: `Linux-5.4.61, Linux/ARM, OS Kernel Image (Not
  compressed), 5195008 bytes, Wed Aug 23 07:33:45 2023, Load 0x40008000, Entry 0x40008000`.
  This is the kernel U-Boot actually boots (env `boot_uImage`). The p4 Android image is the
  secondary/recovery copy.
- `sunxi.dtb` 55 093 B — compatible `allwinner,r528` / `arm,sun8iw20p1` (T113 reuses the R528
  DT base). Runtime device tree.
- `magic.bin` (512 B): `a1sp9maK` + ASCII token `de37ee6c-6dc4-4d74-86f0-db32116efb53e0e4`
  (FlashForge device/board magic).
- `bootlogo.bmp` / `fastbootlogo.bmp` = 1152054 B = 800x480x3 + 54 (panel res). FF splash.

### p4 boot (Android boot image)

First bytes `41 4E 44 52 4F 49 44 21` = `ANDROID!`. `file`: *Android bootimg, kernel
(0x40008000), ramdisk (0x41000000), page size 2048*, board `sun8i_arm`. Kernel banner:

```
Linux version 5.4.61 (root@linux-virtual-machine)
  (arm-linux-gnueabi-gcc (Linaro GCC 5.3-2016.05) 5.3.1 20160412, GNU ld 2.25.0 Linaro 2016_02)
  #52 SMP PREEMPT Wed Aug 23 15:33:33 CST 2023
```

Leaked compiled-in build path:

```
/home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4/...
```

→ FF built from the **`T113-Linux-Auto-v1.1` BSP** (Tina/longan "auto" T113 release),
kernel `linux-5.4`, **Linaro arm-linux-gnueabi GCC 5.3**. Same tree vendored at
`vendor/kernels/tina-bsp-kernel/`.

### p5 dsp0 (HiFi4 DSP firmware)

`file`: *ELF 32-bit LSB, Tensilica Xtensa, statically linked, stripped*. Strings:
`AW-SOUND-CORE version:...`, `HW_VERSION="LX7.1.4"`, `#Xtensa Compiler Version 14.04 :
arch/sun8iw20/init-sun8iw20.c`, `RELEASE_VERSION="14.04"`. Allwinner HiFi4/LX7 DSP audio
firmware — **proprietary prebuilt**, loaded by U-Boot (`boot_dsp0`). Not buildable from BSP.

### p6 rootfs (ext4)

`dumpe2fs`: ext4, block 4096, 327680 blocks (1.25 GiB), 81920 inodes, **UUID
`57f8f4bc-abf4-655f-bf67-946fc0f9f25b`** (the fixed mke2fs hash-seed UUID → deterministic
packer build, not on-device mkfs). Root dir:

```
bin dev etc lib lib32 media mnt proc root run sbin sys tmp usr var      <- Buildroot base
init -> bin/busybox   linuxrc   lost+found
opt   system   data   Settings                                          <- FF additions
```

- `/usr/lib/os-release` -> `NAME=Buildroot VERSION=2019.02.1-svn19 ID=buildroot`. Base rootfs
  is **Buildroot 2019.02.1** (Tina's Buildroot target), *not* OpenWrt.
- `/init -> bin/busybox`, `/etc/inittab`, `/etc/init.d/S01..S80` (syslogd, klogd, udev,
  urandom, dbus, network, **postgresql**, telnet, dnsmasq) + custom `rcS`. Busybox-init.
- `/etc/fstab` mounts virtual FS only; real root via kernel cmdline `root=/dev/mmcblk0p6`.
- **FF app layer** in `/opt` (section 5): `PROGRAM/`, `klipper/`, `qt-4.8.6/`,
  `Python-3.7.11/`, `ffmpeg-4.0.2/`, `mjpg-streamer/`, `x264/`, `mencoder`, `cloud/`,
  `tslib-1.12/`, `libffi-3.4.4`, `openssl-1.0.2d`, `nim/`, keys (`private.pem`, `key.pub`,
  `key.priv`, `cacert.pem`).

### p7 UDISK

ext4 user-data mounted at `/data` (`/dev/mmcblk0p7 on /data`). Empty at pack time.

---

## 2. U-Boot / bootloader

The 36 MiB pre-p1 reserved zone holds the standard sunxi boot package:

- **boot0 / SPL** at byte 0x2000 (sector 16, eMMC 8 KB boot offset): magic `eGON.BT0`,
  strings `HELLO! BOOT0 is starting!`, `SUNXI SD/MMC`, `u-boot`. Two copies (redundancy).
- **U-Boot in TOC1.** Magic `TOC1` at byte 13 272 349 and 17 483 854 — two redundant
  Allwinner **TOC1** secure-boot packages, each bundling `u-boot`+`optee`+`monitor`+dtb+scp.

**Two distinct U-Boot builds present** (`strings -t`):

```
@13303528:  U-Boot 2018.05 (Aug 25 2023 - 17:05:54 +0800) Allwinner Technology
@17515089:  U-Boot 2018.05-g2a24076-dirty (Apr 18 2025 - 11:25:23 +0800) Allwinner Technology
```

- First (Aug 2023, clean) = **factory** U-Boot, matches the Aug 2023 kernel.
- Second (Apr 2025, `-g2a24076-dirty`) = **later rebuild** flashed by a firmware update
  (git `2a24076`, dirty tree). Both U-Boot **2018.05** (Allwinner brandy-2.0). One per TOC1
  slot = normal redundant/A-B bootloader layout the packer writes.

**Boot flow (p2/p3 env, verbatim):**

```
earlycon=uart8250,mmio32,0x05000000   console=ttyS3,115200   loglevel=4   cma=16M
mmc_root=/dev/mmcblk0p6   init=/init   dsp0_partition=dsp0
setargs_mmc=setenv bootargs earlycon=... console=... root=${mmc_root} init=${init} ... gpt=1
boot_dsp0=sunxi_flash read 43000000 ${dsp0_partition};bootr 43000000 0 0
boot_uImage=part list mmc 0;fatload mmc 0:1 0x43000000 uImage;
            fatload mmc 0:1 0x44864e70 sunxi.dtb;fdt resize;bootm 0x43000000 - 0x44864e70
boot_normal=sunxi_flash read 43000000 boot;bootm 43000000     <- boots p4 Android image
bootdelay=3
bootcmd=run setargs_mmc boot_dsp0 boot_uImage
```

Runtime: U-Boot sets `root=/dev/mmcblk0p6`, **loads+starts the DSP** from p5 via `bootr`
(boot-remote/remoteproc), then **`fatload`s `uImage`+`sunxi.dtb` from p1 FAT** and `bootm`s.
The p4 boot partition (`boot_normal`) is the recovery fallback. Real root = p6 ext4.

---

## 3. TinaSDK build path

The vendored tree is the **kernel only**; U-Boot, boot0, Buildroot target and the
`pack`/`dragon` tooling live in the full Tina/longan SDK (not vendored). Pinned from evidence:

**Toolchain & build system**
- Kernel: Linux 5.4.61, arm, **Linaro GCC 5.3-2016.05** (arm-linux-gnueabi). In-tree
  defconfig **`sun8iw20p1smp_t113_auto_defconfig`** (265 lines; `CONFIG_ARCH_SUN8IW20=y`,
  `# CONFIG_LOCALVERSION_AUTO is not set`, `CONFIG_SND_SUNXI_SOC_SUN8IW20_CODEC=y`,
  `CONFIG_MMC_SUNXI=y`, `CONFIG_EXT4_FS=y`). `t113_auto` name + `T113-Linux-Auto-v1.1` path =
  same release. Siblings: `..._t113_recovery_defconfig` (4104 lines, recovery kernel),
  `..._auto_nand_defconfig`.
- Rootfs: **Buildroot 2019.02.1** (Tina Buildroot target), busybox init.
- U-Boot: Allwinner **u-boot-2018.05 (brandy-2.0)**, board `sun8iw20p1`.
- DSP: Allwinner HiFi4 prebuilt (Xtensa 14.04).

**Allwinner image-pack flow (`sunxi-pack`/`dragonsecboot`):**

```
device/config/chips/sun8iw20p1/configs/<board>/
   sys_config.fex      -> board pinmux/clock -> compiled into sunxi.dtb
   sys_partition.fex   -> THE partition table (name/size/downloadfile per partition)
   env.cfg             -> U-Boot env -> p2/p3
   image.cfg           -> which .fex into sys.img, GPT vs MBR, image name
out image/:
   boot0_sdcard.fex (-> sector 16)   u-boot.fex/toc1.fex (-> reserve, dual)
   boot.fex (-> p4)   boot-resource.fex (FAT -> p1)   dsp0.fex (-> p5)   rootfs.fex (-> p6)
pack (update_mbr + dragonsecboot + env writer) -> sys.img / full eMMC
```

The packer produces the sequential partition GUIDs, `attrs=GUID:63`, the 36 MiB reserve, the
redundant env + redundant TOC1, and the deterministic ext4 UUID. `sys_partition.fex` is the
single source of the 7-partition layout (boot-resource 33.6M / env 1M / env-redund 1M / boot
34.4M / dsp0 1M / rootfs 1.3G / UDISK fill).

---

## 4. Reproduction assessment

**Bit-identical: NO.** Blockers:
- Vendor-signed **boot0 + U-Boot/TOC1** (two builds incl. Apr-2025 `-dirty`) — no exact
  brandy rev / signing keys / build host.
- **HiFi4 DSP blob** (p5, AW-SOUND-CORE Xtensa) — proprietary, no source.
- **FF proprietary app** — `firmwareExe` (Qt 4.8.6), `ffstartup-arm`, signing keys, closed
  library/control MCU payloads.
- Build timestamps/host paths baked into uImage/U-Boot (Aug 23 2023, `linux-virtual-machine`,
  `/home/linux/work/hard_t113_s3/...`).

**Reproducible from source (functionally equivalent):**
- Kernel uImage/zImage from `vendor/kernels/tina-bsp-kernel` + `sun8iw20p1smp_t113_auto_defconfig`
  + Linaro GCC 5.3 -> boot-compatible 5.4.61.
- `sunxi.dtb` from the matching sys_config/DT.
- ext4 **rootfs** (deterministic UUID achievable) — Buildroot 2019.02.1 base + FF `/opt`
  grafted from the public community rootfs (`Adventurer5M-factory.tar.xz`, pinned).
- The **GPT + layout** (write our own `sys_partition.fex` mirroring section 1).
- p1 **boot-resource FAT** (rebuild with mtools).
- U-Boot env (p2/p3) verbatim from section 2.

**FF additions over stock Tina (the delta to graft):** the 7-partition GPT sizing/names;
`/opt/PROGRAM` (firmwareExe + version tree); `/opt/klipper`; qt-4.8.6 / Python-3.7.11 /
ffmpeg / mjpg-streamer / x264 / mencoder; `cloud/`; signing keys; `/Settings`; branded
logos + battery-icon set; `postgresql` in init.

**Step-by-step (functional stock-equivalent via Tina):**
1. Get full Tina/longan SDK for `sun8iw20p1` (T113 "auto"); `lunch` the FF/T113 board.
2. Build kernel with `sun8iw20p1smp_t113_auto_defconfig` (Linaro GCC 5.3) -> uImage + sunxi.dtb.
3. Build/keep U-Boot 2018.05 brandy + boot0 (or **graft** factory boot0 + both TOC1 U-Boots
   byte-for-byte, since vendor-signed).
4. Assemble p1 boot-resource FAT (mtools): uImage, sunxi.dtb, logos, fonts, bat/, wavefile/,
   magic.bin, lcd_compatible_index.txt.
5. Build ext4 rootfs: Buildroot 2019.02.1 base + extract pinned `Adventurer5M-factory.tar.xz`
   -> graft `/opt`, `/etc/init.d`, `/Settings`. mke2fs fixed UUID `57f8f4bc-...`.
6. Write `sys_partition.fex` matching section 1 + `env.cfg` reproducing section 2 env.
7. **Graft** `dsp0.fex` (HiFi4 blob) from the dump.
8. `pack` -> sys.img; verify GPT via `sfdisk -d` vs section 1; boot in qemu harness.

Net: a **functional bootable stock-equivalent** is achievable; ~3 components
(boot0/U-Boot, DSP blob, FF Qt app) must be grafted from the dump / pinned community
artifacts rather than rebuilt from source.

---

## 5. How FlashForge built it (inferred)

1. **Base:** Allwinner **Tina / `T113-Linux-Auto-v1.1` BSP** — Linux 5.4.61
   (`sun8iw20p1smp_t113_auto_defconfig`, Linaro GCC 5.3), U-Boot 2018.05 brandy-2.0,
   **Buildroot 2019.02.1** target, HiFi4 DSP prebuilt. Built on `linux-virtual-machine` host
   under `/home/linux/work/hard_t113_s3/...`.
2. **Board bring-up:** custom `sys_config.fex` (panel 800x480, T113 pinmux), a
   `sys_partition.fex` defining the 7-partition GPT, `env.cfg` with the `boot_dsp0`+`boot_uImage`
   flow.
3. **App layer over Buildroot rootfs:** `/opt/PROGRAM` orchestrated by `ffstartup-arm`
   (2.78 MB launcher, mtime 2020) per `/opt/PROGRAM/ffstartup.cfg`:
   ```
   [startup]
   AppName = ./software/%VERSION%/firmwareExe      AppArgs = -1;-D;-qws   (Qt/QWS GUI)
   Kernel=kernel  Control=control  Library=library  Software=software
   [env]  EnvFile = ./library/%VERSION%/env.cfg
   ```
   **Version map confirmed directly from the rootfs** (`/opt/PROGRAM/<comp>/<ver>` dirs):
   kernel **2.1.6**, control **2.2.3** (MCU: Mainboard.bin/Eboard.hex), library **2.5.0**,
   software **5.1.4** (firmwareExe + klipper cfg). These are FF *application* axes, independent
   of the Linux 5.4.61 kernel. `software/5.1.4/`: firmwareExe, client, network, ntpclient, rcS,
   run.sh, auto_run.sh, md5sum.list, firstVersion, zip. Plus `/opt/klipper` (klippy/, src/,
   config/, start.sh, usb_map.sh, pycmd.py).
4. **Pack:** `sunxi-pack`/`dragonsecboot` glues boot0 + dual-TOC1 U-Boot + boot-resource.fex
   + boot.fex + dsp0.fex + rootfs.fex into the GPT `sys.img` (7 818 182 656 B eMMC), writing
   redundant env + sequential partition GUIDs.
5. **OTA overlay model** (`Adventurer5MPro-<ver>.tgz`, ~66 MB): FF ships only **incremental
   overlays** — software/library/kernel/control tar.xz + framebuffer splashes — that
   `flashforge_init.sh` `tar -x`'s onto the existing rootfs and bumps `/opt/PROGRAM/<comp>/<ver>`.
   No mkfs/dd; base FS + bootloader + partition table are factory-programmed, never shipped.
   The coexisting **Apr-2025 `-dirty` U-Boot** (section 2) is one such later update.
   Cross-ref: `docs/research/kernel/2026-06-01-stock-recovery-images.md`.

---

## Concrete evidence index

- GPT: `sfdisk -d`, 7 parts, type `EBD0A0A2-...-72699C7`, `attrs=GUID:63`, label-id `AB6F3888-...`.
- Kernel: `Linux version 5.4.61 ... Linaro GCC 5.3 ... #52 ... Wed Aug 23 15:33:33 CST 2023`;
  path `/home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4`.
- uImage (p1): `u-boot legacy uImage, Linux-5.4.61, Load 0x40008000, Wed Aug 23 07:33:45 2023`.
- DTB compatible: `allwinner,r528` / `arm,sun8iw20p1`.
- U-Boot: `U-Boot 2018.05 (Aug 25 2023 ...)` @13303528 and `U-Boot 2018.05-g2a24076-dirty
  (Apr 18 2025 ...)` @17515089; boot0 `eGON.BT0` @0x2000; `TOC1` @13272349 / @17483854.
- env: `bootcmd=run setargs_mmc boot_dsp0 boot_uImage`; `root=/dev/mmcblk0p6`; `init=/init`.
- rootfs: ext4 UUID `57f8f4bc-abf4-655f-bf67-946fc0f9f25b`; os-release Buildroot 2019.02.1.
- DSP (p5): Xtensa ELF, `AW-SOUND-CORE`, `HW_VERSION="LX7.1.4"`, Xtensa compiler 14.04.
- FF versions: `/opt/PROGRAM/{kernel 2.1.6, control 2.2.3, library 2.5.0, software 5.1.4}`,
  `ffstartup.cfg` AppName `./software/%VERSION%/firmwareExe`.
- BSP defconfig: `vendor/kernels/tina-bsp-kernel/arch/arm/configs/sun8iw20p1smp_t113_auto_defconfig`.
