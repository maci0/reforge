# Board Notes — FlashForge AD5M Pro (Allwinner T113-S3)

Reference data captured from the live unit (`root@192.168.0.158`, hostname `kunos`)
for the Plan 5 (P4) kernel + U-Boot + genimage work. **Reference for parameter
extraction — not shipped.**

## Captured artifacts (this dir)

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
- `8821cu` (RTL8821CU) is out-of-tree in the stock BSP, but **mainline covers it**:
  `CONFIG_RTW88_8821CU` (rtw88 family) since kernel 6.2, flaky early but solid by
  6.12 (our target LTS); BT via `btusb`+`btrtl`. **No vendor module needed.** rtw88
  is station-mode-solid (AP/monitor weaker than vendor, irrelevant for a printer).
- The `dsp0@p5` partition holds DSP firmware; the partition map must be preserved
  by genimage so the DSP and boot chain are not disturbed.
</content>
