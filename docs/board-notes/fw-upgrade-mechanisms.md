# Stock firmware upgrade mechanisms — where each is triggered

The stock AD5M firmware has **five distinct firmware-upgrade paths**, each
with its own trigger, entry point, and target. They share the same
"executor" (`/opt/auto_run.sh`, the last line of `/etc/init.d/rcS`) but
fan out from there.

This doc maps the **trigger → entry point → effect** chain for each, so a
future ReForge component can decide which to preserve, replace, or
intentionally hook for our own update mechanism.

**Source of truth:** `/opt/auto_run.sh`, `/opt/PROGRAM/control/<ver>/run.sh`,
`/opt/PROGRAM/software/<ver>/run.sh`, `/opt/PROGRAM/kernel/<ver>/run.sh`,
`/opt/PROGRAM/library/<ver>/run.sh` \u2014 all from the forge-x rootfs slice
(forge-x doesn't touch any of these, so they are functionally identical to
pristine stock).

## The single point of entry: `/etc/init.d/rcS` tail

All boot-time upgrade flows reach userspace via the **same final line of
`/etc/init.d/rcS`**:

```sh
/opt/auto_run.sh &
```

Backgrounded. `rcS` returns immediately; `inittab` continues to spawn
`getty`; `auto_run.sh` runs in parallel doing its scan. The first thing
that exits 0 from `auto_run.sh` either:

- **Parks `auto_run.sh` forever** (`sleep 100000`) \u2014 used by the USB-install
  paths so they can claim the printer without the stock UI ever launching.
- **Reboots** (`reboot -f`) \u2014 used by the MCU-update path because the new
  MCU firmware needs a fresh power-on to take effect.
- **Falls through to launch the stock UI** (`ffstartup-arm`) \u2014 the default
  path when nothing is being upgraded.

See [`boot.md`](../boot.md) \u00a74 for the full `auto_run.sh` timeline.

## The five upgrade paths

| # | Mechanism | Trigger | Entry point | Target |
|---|---|---|---|---|
| 1 | **USB host-FW tarball** | `Adventurer5MPro-*.tgz` present on a FAT USB stick | `auto_run.sh` step 3a \u2192 `flashforge_init.sh` inside the tarball | Whole-system update (kernel + rootfs + MCU fw + libs) \u2014 sub-dispatched to paths #3, #4, #5 below |
| 2 | **USB direct script** | `flashforge_init.sh` present on a FAT USB stick (no tarball wrapper) | `auto_run.sh` step 3b \u2192 `/mnt/flashforge_init.sh` directly | Whatever the script does \u2014 same hook ReForge live mode + the installer ride |
| 3 | **MCU firmware update** | `/opt/PROGRAM/control/<latest>/Update` flag file exists | `auto_run.sh` step 5 \u2192 `/opt/PROGRAM/control/<latest>/run.sh` \u2192 `NationsCommand` (mainboard MCU) + `IAPCommand` (eboard MCU) | Flash the two N32G455 MCUs \u2014 `Mainboard-20230831.bin` and `Eboard-20231012.hex` from the same dir |
| 4 | **Host software update** | invoked from inside paths #1 or #2 | `/opt/PROGRAM/software/<latest>/run.sh` (inside a tarball; copied to disk during install) | Overwrite `/opt/auto_run.sh`, `/etc/init.d/rcS`, `/bin/zip`, `/sbin/iwlist`, `/bin/wifi_reconnect`, `/data/logFiles/firmwareExe`, `/opt/ntpclient` in place on the running rootfs |
| 5 | **Kernel/library update** | invoked from inside paths #1 or #2 | `/opt/PROGRAM/kernel/<latest>/run.sh` and `/opt/PROGRAM/library/<latest>/run.sh` | Kernel: overwrite `8821cu.ko`, `sunxi.dtb`, `bootlogo.bmp`, `fastbootlogo.bmp`, `udhcpd.conf`. Library: overwrite the version dir in `/opt/PROGRAM/library/<ver>/` (OpenSSL/libffi/etc., used by Klipper) |
| (6) | **Cloud OTA** \u2014 *not in this list of five* | runs from `firmwareExe` (the QT UI) once the printer is booted | `/opt/cloud/` SDK | Push-update from FF cloud; uses the same `/opt/PROGRAM/*/run.sh` mechanism under the hood. We do **not** ship `/opt/cloud/`, so this path is dead in ReForge by definition. |

### Path #1 in detail \u2014 USB `.tgz` (the canonical FW upgrade)

```
USB stick contains:
  Adventurer5MPro-<ver>.tgz
    \u2514\u2500\u2500 flashforge_init.sh         \u2190 entry point
    \u2514\u2500\u2500 control-<ver>.tar.xz       \u2192 unpacks to /opt/PROGRAM/control/<ver>/
    \u2514\u2500\u2500 software-<ver>.tar.xz      \u2192 unpacks to /opt/PROGRAM/software/<ver>/
    \u2514\u2500\u2500 kernel-<ver>.tar.xz        \u2192 unpacks to /opt/PROGRAM/kernel/<ver>/
    \u2514\u2500\u2500 library-<ver>.tar.xz       \u2192 unpacks to /opt/PROGRAM/library/<ver>/
    \u2514\u2500\u2500 md5sum.list                \u2190 integrity check
```

`auto_run.sh` steps for this path:

```
1. mount /dev/sda<N> -t vfat \u2192 /mnt
2. UPDATEFILE=$(ls -1t /mnt/Adventurer5MPro-*.tgz | head -1)
3. cp ${UPDATEFILE} /data/
4. mkdir -p /data/update
5. tar -xvf /data/Adventurer5MPro-*.tgz -C /data/update/
6. /data/update/flashforge_init.sh Adventurer5MPro 0024
7. if exit 0:
     umount /mnt
     rm -rf /data/update
     sleep 100000             \u2190 stock UI NEVER launches
   else:
     umount /mnt
     continue to next /dev/sda<N>
```

The `flashforge_init.sh` inside the tarball typically:

```
1. Verify md5sum.list
2. Extract each subpackage tar.xz
3. Run each subpackage's run.sh (paths #4, #5)
4. Set /opt/PROGRAM/control/<ver>/Update flag    \u2190 schedules path #3 on next boot
5. Sync; exit 0
```

So a full firmware update happens in **two reboots**: first the
`.tgz` install lands the new files + sets the `Update` flag; the next
boot's `auto_run.sh` runs path #3 (MCU update) and does its own `reboot -f`;
the boot after that runs the new stock UI clean.

### Path #2 in detail \u2014 USB bare `flashforge_init.sh`

Same as path #1 minus the tarball wrapper:

```
1. mount /dev/sda<N> -t vfat \u2192 /mnt
2. if -f /mnt/flashforge_init.sh:
     chmod a+x /mnt/flashforge_init.sh
     /mnt/flashforge_init.sh Adventurer5MPro 0024
3. on exit 0: umount /mnt; sleep 100000
```

The script runs **directly from the USB stick** \u2014 nothing is staged to
`/data/update/` first. This is the **hook ReForge live mode rides on**
(`packaging/live/flashforge_init.sh` is exactly that file at the USB
root) and the same hook the **ReForge installer** uses (path A in
`docs/deployment-modes.md`).

### Path #3 in detail \u2014 MCU firmware (the bin/hex flash)

```sh
# auto_run.sh, after the USB scan loop:
CONTROL_DIR=/opt/PROGRAM/control/
CONTROL_VERSION=`ls -1t ${CONTROL_DIR} | head -n 1`
CONTRIL_FLAG=${CONTROL_DIR}${CONTROL_VERSION}/Update
if [ -f ${CONTRIL_FLAG} ]; then
    cd ${CONTROL_DIR}${CONTROL_VERSION}
    ./run.sh
    reboot -f
fi
```

And `/opt/PROGRAM/control/2.2.3/run.sh` (the latest version on the live unit):

```sh
WORK_DIR=`dirname $0`
FIRMWARE_Board_M3=Mainboard-20230831.bin
FIRMWARE_Head_M3=Eboard-20231012.hex

cat $WORK_DIR/mcu.img > /dev/fb0                              # splash screen

# Mainboard MCU (N32G455, /dev/ttyS5, 230400)
$WORK_DIR/NationsCommand -c -d --fn $WORK_DIR/$FIRMWARE_Board_M3 --v -r

# Toolhead MCU (N32G455, /dev/ttyS1, 230400)
$WORK_DIR/IAPCommand $WORK_DIR/$FIRMWARE_Head_M3 /dev/ttyS1
sync
```

- `NationsCommand` is the **Nations IAP loader** (Nations Technology = the
  manufacturer of the N32G455 part; "Nations" + "Command" = their command
  line flasher). Mainboard MCU \u2192 board-internal serial bus.
- `IAPCommand` is a simpler / second-generation flasher used for the
  toolhead MCU specifically. Same chip family but the toolhead's serial
  is on `/dev/ttyS1` (the eboard UART).
- `mcu.img` is a 3 MB framebuffer image displayed on the screen during the
  flash (the "do not power off" splash).

Trigger: presence of an `Update` flag file. The path-#1 installer touches
this flag if it ships new MCU firmware; otherwise the flag stays absent and
the MCU update is skipped.

### Path #4 in detail \u2014 host software update

`/opt/PROGRAM/software/<ver>/run.sh` is **invoked from inside a `.tgz`
installer** (path #1). It does file-by-file overwrites of the live
running rootfs:

```sh
# Excerpts from /opt/PROGRAM/software/5.1.4/run.sh
cp_file $WORK_DIR/auto_run.sh /opt/                              # the dispatcher itself!
cp      $WORK_DIR/rcS         /etc/init.d/rcS                    # the boot dispatch script
cp      $WORK_DIR/network/iwlist        /sbin/
cp      $WORK_DIR/zip                   /bin/zip
cp      $WORK_DIR/ntpclient             /opt/
cp      $WORK_DIR/network/wifi_reconnect /bin/wifi_reconnect
cp      $WORK_DIR/firmwareExe           /data/logFiles/firmwareExe
sync
```

Note the **self-modifying** nature: `auto_run.sh` and `rcS` overwrite
themselves on the next boot. The `cp_file` helper re-tries until MD5
matches \u2014 a safeguard against partial writes during power loss
mid-update.

`firmwareExe` lands in `/data/logFiles/firmwareExe` (NOT `/opt/PROGRAM/`)
\u2014 a path the QT UI checks for and overlays at runtime. This is FF's
"OTA the UI without touching the read-mostly rootfs" trick.

### Path #5 in detail \u2014 kernel + library update

`/opt/PROGRAM/kernel/<ver>/run.sh` updates kernel-adjacent files:

```sh
# Excerpts from /opt/PROGRAM/kernel/2.1.6/
8821cu.ko        \u2192 /lib/modules/5.4.61/8821cu.ko    (WiFi driver)
sunxi.dtb        \u2192 ?                                (the device tree?)
bootlogo.bmp     \u2192 ?                                (boot splash)
fastbootlogo.bmp \u2192 ?                                (fastboot splash)
udhcpd.conf      \u2192 /etc/udhcpd.conf?               (DHCP server)
rcS              \u2192 /etc/init.d/rcS                 (yes, AGAIN)
```

It does **not** ship a new kernel binary (`boot.img` on p4) \u2014 the kernel
itself is updated by overwriting `mmcblk0p4` via a different OTA path
(we don't have a captured `run.sh` for that and stock doesn't appear to
hook it from `auto_run.sh`; suspect it's from `firmwareExe`/cloud).

`/opt/PROGRAM/library/<ver>/run.sh` updates `/opt/openssl-1.0.2d/`,
`/opt/libffi-3.4.4/`, etc. \u2014 the FF-bundled libs that Klipper depends on.

### Path #6 \u2014 cloud OTA (not really fifth-of-five)

`firmwareExe` (the stock QT UI) connects to FF's cloud over TLS using the
keys in `/opt/key.*` and the CA bundle in `/opt/cacert.pem`. The cloud
can push updates that materialise on disk as `/opt/PROGRAM/*/<ver>/`
trees, then schedule a reboot \u2014 same downstream mechanism as paths #3
and #4, just initiated server-side instead of user-side.

ReForge does **not** ship `/opt/cloud/`, `/opt/cacert.pem`, or
`/opt/key.*` (firm spec requirement), so this path is dead for any
ReForge user. The hardware key material remains in flash but nothing on
the rootfs talks to it.

## Cross-reference to ReForge

| Stock path | ReForge equivalent | Notes |
|---|---|---|
| #1 USB tarball (`Adventurer5MPro-*.tgz`) | **install-path A** in [`deployment-modes.md`](../deployment-modes.md) \u2014 `reforge-<ver>.tgz` with the same FF-compatible naming so stock `auto_run.sh` picks it up | Same hook, same exit-0 \u2192 sleep 100000 semantics. We **don't** modify `/opt/PROGRAM/*` from path A; we write to `/data/.mod/.reforge/` instead. |
| #2 USB bare `flashforge_init.sh` | **live mode** (`packaging/live/flashforge_init.sh`) **and** the bare-launcher variant of the installer | Same hook. The live launcher exits non-zero from `auto_run.sh`'s perspective only if it fails to mount/start \u2014 normally it blocks forever inside its own `while true; do sleep; done` so the stock flow never resumes. |
| #3 MCU firmware (`Update` flag) | **NOT TOUCHED today.** ReForge runs against the stock-shipped MCU firmware (v0.11). If we ever ship a different MCU image (for v0.13 upgrade), we'd reuse this same path: drop the new `.bin`/`.hex` into `/opt/PROGRAM/control/<newver>/` and create the `Update` flag. | We **hold the binaries** for path #3 (`Mainboard-20230831.bin`, `Eboard-20231012.hex`, `NationsCommand`, `IAPCommand`, `mcu.img`) \u2014 see `docs/research/2026-06-04-klipper-v0.11-fork-deltas.md` \u00a74 and the FF fork's `fw-Ad5m/` dir. Useful for emergency MCU re-flash. |
| #4 host software | **OTA mechanism** in [`ota.md`](../ota.md) \u2014 we publish per-component `.zip` bundles (`klipper.zip`, `moonraker.zip`, `guppyscreen.zip`, `reforge.zip`, `mainsail.zip`) consumed by Moonraker's `update_manager` `type: zip`/`type: web` | Different transport (HTTPS pull, not USB push), different target dir (`/data/.mod/.reforge/<component>/`, not `/opt/PROGRAM/<sub>/<ver>/`). Same fundamental "drop a tree, run a hook, swap pointers" pattern. |
| #5 kernel/library | **NOT TOUCHED today.** Mode 2 (install-on-stock) explicitly does not replace the kernel or `/opt/PROGRAM/library/`. **Mode 3** (full-replacement, Plan 5) will own the kernel build but should keep this hook so a stock `.tgz` can downgrade to factory. | Forward-compat thing to remember when designing Mode 3's update mechanism. |
| #6 cloud OTA | **Intentionally absent.** ReForge has no cloud connection. | Spec. |

## Implications for Mode 3 (full-replacement) design

When ReForge builds its own rootfs (per [`deployment-modes.md`](../deployment-modes.md)
Mode 3), the upgrade-mechanism question becomes: **how much of the stock
upgrade infrastructure do we re-implement?**

Recommended baseline:
- **Keep path #1 fully functional** \u2014 a stock-format `Adventurer5MPro-*.tgz`
  on a USB stick should *still* be picked up by our equivalent of
  `auto_run.sh` and treated as an emergency \"flash stock back\" path.
  This is the "no FEL, no UART" brick-safety boundary from
  [`board-notes/partition-map.md`](partition-map.md).
- **Keep path #2 functional** for our own live-launcher mechanism.
- **Keep path #3 (MCU update)** as a hook \u2014 we still need to flash
  N32G455 firmware sometimes, and `NationsCommand`/`IAPCommand` are
  reusable as-is.
- **Drop paths #4 and #5** \u2014 they target `/opt/PROGRAM/*` which is FF's
  product layout, not ours. ReForge updates live through Moonraker's
  `update_manager` and don't need the legacy mechanism.
- **Drop path #6** \u2014 spec.

## See also

- [`boot.md`](../boot.md) \u00a74 \u2014 the `auto_run.sh` boot-chain position
- [`stock-rootfs-provenance.md`](stock-rootfs-provenance.md) \u2014 what's in
  `/opt/PROGRAM/`, who put it there
- [`partition-map.md`](partition-map.md) \u2014 the eMMC layout and brick-safety
  tier per partition
- [`../deployment-modes.md`](../deployment-modes.md) \u2014 ReForge's three
  modes + two installer invocation paths
- [`../ota.md`](../ota.md) \u2014 ReForge's own OTA mechanism (the path-#4
  equivalent we ship)
- [`../research/2026-06-04-klipper-v0.11-fork-deltas.md`](../research/2026-06-04-klipper-v0.11-fork-deltas.md)
  \u00a74 \u2014 the MCU firmware binaries we hold (path #3 ammo)
