# Board Notes — FlashForge AD5M Pro (Allwinner T113-S3)

Device/platform reference captured from the live unit (`root@192.168.0.158`, hostname
`kunos`): hardware inventory, the forge-x mod boot stack, and the raw kernel artifacts the
Plan 5 kernel + U-Boot + genimage work extracts parameters from. **Reference — not shipped.**

## Captured artifacts (this dir)

- [`partition-map.md`](partition-map.md) — **canonical eMMC partition layout**
  (GPT offsets, sizes, filesystems, mountpoints, brick-safety tier for each
  of the 7 partitions). The single source of truth for "what's at
  `mmcblk0pN`".
- [`stock-rootfs-provenance.md`](stock-rootfs-provenance.md) — **what's part of
  the Allwinner Tina SDK base vs what FlashForge added** in the stock
  `mmcblk0p6` rootfs. Per-directory breakdown of `/opt`, `/etc`, `/usr/bin`,
  etc. Reference for the Mode 3 (full-replacement) rootfs design.
- [`fw-upgrade-mechanisms.md`](fw-upgrade-mechanisms.md) — **where each of the
  five distinct stock firmware-upgrade paths is triggered from**: USB `.tgz`,
  USB bare `flashforge_init.sh`, MCU firmware (`Update` flag), host software
  subpackage, kernel/library subpackage, plus the cloud OTA flow. Maps each
  stock path to its ReForge equivalent.
- [`device-overview.md`](device-overview.md) — hardware inventory (SoC,
  DRAM, peripherals).
- `stock-kernel-config-5.4.61.txt.gz` — the **exact stock kernel `.config`** (`/proc/config.gz`,
  1017 `CONFIG_` lines). The slim-down baseline for `reforge_t113_defconfig`.
- `running-unit-probe.txt` — uname, cmdline, lsmod.

## Kernel cmdline (stock)

```
earlycon=uart8250,mmio32,0x05000000 clk_ignore_unused initcall_debug=0
console=ttyS3,115200 loglevel=4 root=/dev/mmcblk0p6 init=/init
partitions=boot-resource@mmcblk0p1:env@mmcblk0p2:env-redund@mmcblk0p3:boot@mmcblk0p4:dsp0@mmcblk0p5:rootfs@mmcblk0p6:UDISK@mmcblk0p7
cma=16M snum= mac_addr= wifi_mac= bt_mac= specialstr= gpt=1
androidboot.hardware=sun8iw20p1 boot_type=1 androidboot.boot_type=1
uboot_message=2018.05-g2a24076-dirty(04/18/2025-11:25:23)
disp_reserve=1536000,0x448ee000 androidboot.dramsize=128
```

## Derived facts

| Fact | Value | Relevant to |
|---|---|---|
| Console UART | `ttyS3` @ 115200, base `0x05000000` | kernel console, U-Boot stdout |
| Root partition | `mmcblk0p6` (rootfs), ext4 | genimage, fstab |
| Data partition | `mmcblk0p7` (UDISK / `/data`) | genimage, fstab |
| Reserved | `p5 = dsp0` — HiFi4 DSP firmware | partition map; leave intact |
| CMA | 16 MB | display/DMA; kernel `cma=` |
| DRAM | **128 MB** | U-Boot DRAM init, RAM budget |
| Display reserve | `1536000 @ 0x448ee000` | framebuffer / DRM |
| SoC id | `sun8iw20p1` | DT compatible, U-Boot board |
| Vendor U-Boot | **2018.05** (vendor fork) | we replace with mainline ≥2024.01 |
| Loaded modules | only `8821cu` (RTL8821CU wifi/BT) | mainline `CONFIG_RTW88_8821CU` replaces it (see notes) |

## Notes

- Stock kernel is essentially monolithic (one out-of-tree module). When building
  `reforge_t113_defconfig` from mainline-LTS, the captured stock `.config` is the
  authoritative list of which subsystems/drivers this board actually uses — start
  from a board-minimal config and cross-check against it, rather than shipping a
  generic sunxi defconfig.
- `8821cu` (RTL8821CU) is **Realtek's proprietary vendor driver** (origin: never
  upstreamed to mainline Linux). The Allwinner T113-Linux-Auto SDK imports the
  Realtek source into the kernel tree at `drivers/staging/rtl8821cu/` and wires it
  via `CONFIG_RTL8821CU=m`, so the kernel build produces `8821cu.ko` as an in-tree
  module (`modinfo` says `intree:Y`). FF installs it twice: a stripped copy at the
  standard kbuild path `/lib/modules/5.4.61/8821cu.ko`, and a debug-info-retaining
  flat copy at `/lib/modules/8821cu.ko` that `auto_run.sh` `insmod`s explicitly
  (the OTA only refreshes the flat copy). Our public iLotusK9 BSP snapshot **lacks**
  the `drivers/staging/rtl8821cu/` source, so our rebuild does not produce a `.ko`
  — but the **stock `.ko` loads unchanged on our rebuilt kernel** (`vermagic`
  matches: `5.4.61 SMP preempt mod_unload ARMv7 p2v8`). Full analysis:
  [`../reverse-engineering/stock-kernel-modules-packaging.md`](../reverse-engineering/stock-kernel-modules-packaging.md).
  For **mainline** (Plan 5, kernel 6.x LTS): `CONFIG_RTW88_8821CU` (rtw88 family)
  since 6.2, solid by 6.12; BT via `btusb`+`btrtl`. No vendor module needed. rtw88
  is station-mode-solid (AP/monitor weaker than vendor, irrelevant for a printer).
- The `dsp0@p5` partition holds DSP firmware; the partition map must be preserved
  by genimage so the DSP and boot chain are not disturbed.

---

## Documentation index

This dir holds **device/platform reference**. The **stock-firmware reverse-engineering finding
reports** (firmwareExe analysis + the stock Klipper pin map) live in
[`../reverse-engineering/`](../reverse-engineering/) — see its
[`README.md`](../reverse-engineering/README.md).

### Device, hardware & mod architecture (this dir)
- [device-overview.md](device-overview.md) — hardware/stack inventory + consolidated security findings.
- [forge-x-boot-architecture.md](forge-x-boot-architecture.md) — the forge-x mod boot/chroot/service stack.
- [forge-x-camera.md](forge-x-camera.md) — the mod camera (mjpg_streamer MJPEG passthrough) + how to configure it.
- [usb-serial-kmod.md](usb-serial-kmod.md) — building out-of-tree USB-serial kmods (ftdi_sio/ch341/pl2303) against the 5.4.61 BSP + sources.
- `stock-kernel-config-5.4.61.txt.gz`, `running-unit-probe.txt` — captured kernel config + unit probe.

### Related
- MCU firmware + config-baseline detail:
  [`../reverse-engineering/ad5m-mcu-firmware-and-config.md`](../reverse-engineering/ad5m-mcu-firmware-and-config.md).
