# Building a USB-serial kernel module for the AD5M (T113-S3, kernel 5.4.61)

How to build out-of-tree USB-serial drivers (`usbserial.ko` + `ftdi_sio.ko`/`ch341.ko`/
`pl2303.ko`/`cdc-acm`) against the stock Tina 5.4.61 BSP kernel and load them on the printer —
e.g. to attach an FTDI/CH340/PL2303 USB-serial device (Palette 2, a second MCU, an ESP, etc).
The stock kernel ships **`CONFIG_USB_ACM=y`** built-in but **`CONFIG_USB_SERIAL` is not enabled**,
so the generic USB-serial subdrivers must be cross-built as modules.

## Sources

- **Primary guide** (verbatim recipe below): Carlos Felicio, *Enabling Serial over USB on the
  Flashforge Adventurer 5M (Pro)* — <https://carlosfelic.io/misc/enabling-serial-over-usb-on-the-flashforge-adventurer-5m-pro/>
  (kernel fork: <https://github.com/cfelicio/tina-linux-5.4>)
- xblax discussion *"how to get the usb serial port?"* —
  <https://github.com/xblax/flashforge_ad5m_klipper_mod/discussions/199>
- ff5m (forge-x) FAQ — <https://github.com/DrA1ex/ff5m/blob/main/docs/FAQ.md>

## Recipe (from the Carlos Felicio guide)

**Kernel:** 5.4.61 (Tina Linux). **Toolchain:** Linaro 7.4.1 ARM GNUEABI (soft-float).

```bash
# toolchain
wget https://releases.linaro.org/components/toolchain/binaries/7.4-2019.02/arm-linux-gnueabi/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabi.tar.xz
export CROSS=/root/toolchains/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-

# host deps
apt-get install -y build-essential git wget xz-utils bc bison flex libssl-dev rsync file python3 pkg-config

# config from the running printer (so it matches exactly)
zcat /proc/config.gz > printer.config            # use as the kernel .config

# prepare the tree
./scripts/config --disable CONFIG_LOCALVERSION_AUTO
./scripts/config --set-str CONFIG_LOCALVERSION ""
make ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig

# enable USB-serial as modules (FTDI shown; swap symbol for other chips)
./scripts/config --module CONFIG_USB_SERIAL
./scripts/config --module CONFIG_USB_SERIAL_FTDI_SIO
make ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig
make ARCH=arm CROSS_COMPILE="$CROSS" modules_prepare

# build just the usb/serial drivers
make -j"$(nproc)" ARCH=arm CROSS_COMPILE="$CROSS" M=drivers/usb/serial modules
```

**Output:** `drivers/usb/serial/usbserial.ko` + `drivers/usb/serial/ftdi_sio.ko`.

**Install + load (order matters — core first):**
```bash
scp -O drivers/usb/serial/usbserial.ko root@<printer>:/root/usbserial.ko
scp -O drivers/usb/serial/ftdi_sio.ko  root@<printer>:/root/ftdi_sio.ko
insmod usbserial.ko        # core, first
insmod ftdi_sio.ko         # subdriver, after
```

**Verify vermagic matches the running kernel (else "invalid module format"):**
```bash
modinfo -F vermagic drivers/usb/serial/usbserial.ko    # must be 5.4.61 ...
```

**Persist:** copy the `.ko`s into `/lib/modules/5.4.61/` and add an init script
`/etc/init.d/S50usbserialmod` that runs the `insmod`s on boot.

### Other USB-serial chips
Swap the config symbol (all under `M=drivers/usb/serial`, except ACM):

| chip | symbol | module |
|---|---|---|
| FTDI (FT232/FT230X) | `CONFIG_USB_SERIAL_FTDI_SIO` | `ftdi_sio.ko` |
| CH340/CH341 | `CONFIG_USB_SERIAL_CH341` | `ch341.ko` |
| PL2303 | `CONFIG_USB_SERIAL_PL2303` | `pl2303.ko` |
| CDC-ACM devices | `CONFIG_USB_ACM` (already `=y`) | `M=drivers/usb/class` → `cdc-acm.ko` |

`usbserial.ko` is the shared core for all of them — load it before any subdriver.

## How this maps to this repo

- **Same kernel + vermagic as our other BSP kmods.** Our prebuilt modules
  (`modules/f2fs-bsp`, `modules/zram-bsp`) target the identical stock kernel and the required
  `vermagic = 5.4.61 SMP preempt mod_unload ARMv7 p2v8`; a USB-serial `.ko` must match the same
  string to `insmod`. See [`../reverse-engineering/`](../reverse-engineering/README.md) and `modules/*/build.sh`.
- **BSP source:** the guide uses the cfelicio fork; our pinned BSP submodule is
  `vendor/kernels/tina-bsp-kernel` (the same 5.4.61 Tina tree). The Carlos toolchain is Linaro
  **7.4.1**; our kmod/kernel work uses Linaro **7.5.0** (`gcc-linaro-7.5.0-2019.12`). Either
  GCC-7 Linaro soft-float toolchain produces a loadable `.ko` as long as the vermagic matches.
- **Brick-safety:** loading a USB-serial `.ko` at runtime is non-persistent and reversible
  (`rmmod`); only the permanent `/lib/modules` + `S50usbserialmod` step survives reboot, and a
  bad init script is removable over SSH. No bootloader/eMMC risk.
