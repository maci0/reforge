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
`/opt/PROGRAM/library/<ver>/run.sh` from the captured rootfs, cross-checked below
against the held official `Adventurer5MPro-5.1.4.tgz`. A modded capture alone
does not establish factory provenance.

## The single point of entry: `/etc/init.d/rcS` tail

All boot-time upgrade flows reach userspace via the **same final line of
`/etc/init.d/rcS`**:

```sh
/opt/auto_run.sh &
```

Backgrounded. `rcS` returns immediately; `inittab` continues to spawn
`getty`; `auto_run.sh` runs in parallel doing its scan. The first thing
that exits 0 from `auto_run.sh` either:

- **Parks `auto_run.sh` forever** (`sleep 100000`) — used by the USB-install
  paths so they can claim the printer without the stock UI ever launching.
- **Reboots** (`reboot -f`) — used by the MCU-update path because the new
  MCU firmware needs a fresh power-on to take effect.
- **Falls through to launch the stock UI** (`ffstartup-arm`) — the default
  path when nothing is being upgraded.

See [`boot.md`](../boot.md) §4 for the full `auto_run.sh` timeline.

## The five upgrade paths

| # | Mechanism | Trigger | Entry point | Target |
|---|---|---|---|---|
| 1 | **USB host-FW tarball** | `Adventurer5MPro-*.tgz` present on a FAT USB stick | `auto_run.sh` step 3a → `flashforge_init.sh` inside the tarball | Host software, MCU, kernel/DTB and library updates — sub-dispatched to paths #3, #4, #5 below |
| 2 | **USB direct script** | `flashforge_init.sh` present on a FAT USB stick (no tarball wrapper) | `auto_run.sh` step 3b → `/mnt/flashforge_init.sh` directly | Whatever the script does — hook used by ReForge live mode; the packaged installer uses path #1 |
| 3 | **MCU firmware update** | `/opt/PROGRAM/control/<latest>/Update` flag file exists | `auto_run.sh` step 5 → `/opt/PROGRAM/control/<latest>/run.sh` → `NationsCommand` (mainboard MCU) + `IAPCommand` (eboard MCU) | Flash the two N32G455 MCUs — `Mainboard-20230831.bin` and `Eboard-20231012.hex` from the same dir |
| 4 | **Host software update** | invoked from inside paths #1 or #2 | `/opt/PROGRAM/software/<latest>/run.sh` (inside a tarball; copied to disk during install) | Overwrite `/opt/auto_run.sh`, `/etc/init.d/rcS`, `/bin/zip`, `/sbin/iwlist`, `/bin/wifi_reconnect`, `/data/logFiles/firmwareExe`, `/opt/ntpclient` in place on the running rootfs |
| 5 | **Kernel/library update** | invoked from inside paths #1 or #2 | `/opt/PROGRAM/kernel/<latest>/run.sh` and `/opt/PROGRAM/library/<latest>/run.sh` | Kernel: update rootfs files and, when `uImage` is present, the active p1 kernel/DTB and splash images (details below). Library: overwrite the version dir in `/opt/PROGRAM/library/<ver>/` (OpenSSL/libffi/etc., used by Klipper) |
| (6) | **Cloud OTA** — *not in this list of five* | runs from `firmwareExe` (the QT UI) once the printer is booted | `/opt/cloud/` SDK | Push-update from FF cloud; uses the same `/opt/PROGRAM/*/run.sh` mechanism under the hood. ReForge live mode stops the stock UI; installed Mode 2a still runs it and retains this path. |

### Path #1 in detail — USB `.tgz` (the canonical FW upgrade)

```
USB stick contains:
  Adventurer5MPro-<ver>.tgz
    └── flashforge_init.sh         ← entry point
    └── control-<ver>.tar.xz       → unpacks to /opt/PROGRAM/control/<ver>/
    └── software-<ver>.tar.xz      → unpacks to /opt/PROGRAM/software/<ver>/
    └── kernel-<ver>.tar.xz        → unpacks to /opt/PROGRAM/kernel/<ver>/
    └── library-<ver>.tar.xz       → unpacks to /opt/PROGRAM/library/<ver>/
    └── md5sum.list                ← integrity check
```

`auto_run.sh` steps for this path:

```
1. mount /dev/sda<N> -t vfat → /mnt
2. UPDATEFILE=$(ls -1t /mnt/Adventurer5MPro-*.tgz | head -1)
3. cp ${UPDATEFILE} /data/
4. mkdir -p /data/update
5. tar -xvf /data/Adventurer5MPro-*.tgz -C /data/update/
6. /data/update/flashforge_init.sh Adventurer5MPro 0024
7. if exit 0:
     umount /mnt
     rm -rf /data/update
     sleep 100000             ← stock UI NEVER launches
   else:
     umount /mnt
     continue to next /dev/sda<N>
```

The `flashforge_init.sh` inside the tarball typically:

```
1. Verify md5sum.list
2. Extract each subpackage tar.xz
3. Run each subpackage's run.sh (paths #4, #5)
4. Set /opt/PROGRAM/control/<ver>/Update flag    ← schedules path #3 on next boot
5. Sync; exit 0
```

So a full firmware update happens in **two reboots**: first the
`.tgz` install lands the new files + sets the `Update` flag; the next
boot's `auto_run.sh` runs path #3 (MCU update) and does its own `reboot -f`;
the boot after that runs the new stock UI clean.

### Path #2 in detail — USB bare `flashforge_init.sh`

Same as path #1 minus the tarball wrapper:

```
1. mount /dev/sda<N> -t vfat → /mnt
2. if -f /mnt/flashforge_init.sh:
     chmod a+x /mnt/flashforge_init.sh
     /mnt/flashforge_init.sh Adventurer5MPro 0024
3. on exit 0: umount /mnt; sleep 100000
```

The script runs **directly from the USB stick** — nothing is staged to
`/data/update/` first. This is the **hook ReForge live mode rides on**
(`packaging/live/flashforge_init.sh` is exactly that file at the USB
root). The packaged **ReForge installer** uses the tarball hook, path #1
([deployment modes](../deployment-modes.md)).

### Path #3 in detail — MCU firmware (the bin/hex flash)

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
  line flasher). Mainboard MCU → board-internal serial bus.
- `IAPCommand` is a simpler / second-generation flasher used for the
  toolhead MCU specifically. Same chip family but the toolhead's serial
  is on `/dev/ttyS1` (the eboard UART).
- `mcu.img` is a 3 MB framebuffer image displayed on the screen during the
  flash (the "do not power off" splash).

Trigger: presence of an `Update` flag file. The path-#1 installer touches
this flag if it ships new MCU firmware; otherwise the flag stays absent and
the MCU update is skipped.

### Path #4 in detail — host software update

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
matches — a safeguard against partial writes during power loss
mid-update.

`firmwareExe` lands in `/data/logFiles/firmwareExe` (NOT `/opt/PROGRAM/`)
— a path the QT UI checks for and overlays at runtime. This is FF's
"OTA the UI without touching the read-mostly rootfs" trick.

### Path #5 in detail — kernel + library update

`/opt/PROGRAM/kernel/<ver>/run.sh` updates the kernel and adjacent files. The
held official 5.1.4 package (SHA-256
`80e98c82b028c2c1bdcabaa970c22ada1ef943b88786f93123b961888c9f0f07`)
contains `kernel-2.1.6.tar.xz` (SHA-256
`85e4d1fd0040a37ec669c06dea7d16db791526c9a17cccdf7351a063b3b048f7`).
Its `run.sh` lines 78–92 mount `/dev/mmcblk0p1` at `/media` and copy the
following payloads when `uImage` is present:

```text
# Captured 5.1.4 package, kernel component 2.1.6
uImage          → /media/uImage                    (active kernel on p1)
sunxi.dtb        → /media/sunxi.dtb                 (device tree on p1)
bootlogo.bmp     → /media/bootlogo.bmp              (boot splash on p1)
fastbootlogo.bmp → /media/fastbootlogo.bmp          (fastboot splash on p1)
8821cu.ko        → /lib/modules/8821cu.ko           (WiFi driver)
udhcpd.conf      → /etc/udhcpd.conf                 (DHCP server)
rcS              → /etc/init.d/rcS
```

This is a captured stock-USB path for replacing the active `uImage` and
`sunxi.dtb` on FAT p1; it does not write p4 `boot.img`
([boot.md §1](../boot.md#1-the-boot-chain-verified)). Recovery still requires
working userspace that reaches the updater, and the selected package must contain
the required payload. It cannot rescue a kernel failure that prevents startup.

`/opt/PROGRAM/library/<ver>/run.sh` updates `/opt/openssl-1.0.2d/`,
`/opt/libffi-3.4.4/`, etc. — the FF-bundled libs that Klipper depends on.

### Path #6 — cloud OTA (not one of the five)

`firmwareExe` (the stock QT UI) connects to FF's cloud over TLS using the
keys in `/opt/key.*` and the CA bundle in `/opt/cacert.pem`. The cloud
can push updates that materialise on disk as `/opt/PROGRAM/*/<ver>/`
trees, then schedule a reboot — same downstream mechanism as paths #3
and #4, just initiated server-side instead of user-side.

ReForge’s image does not include the stock cloud SDK or keys, but an installed
Mode 2a chroot leaves the stock filesystem and UI running beside it. The cloud
path remains present there. Live mode blocks the stock UI launch; see the
[current closure table](../security-findings.md#summary-table).

## What stock updates touch vs don't touch

A common misreading: "stock updates only ever touch `/opt/`." Almost true,
but not quite. The stock paths #4 and #5 reach into a small whitelist of
files **outside** `/opt/` — all of which are FF-maintained even though they
live in Tina's directories. The bulk of the Tina rootfs (busybox, the
unused `/usr/bin/*` tools, libc, the other `/etc/init.d/S??` scripts) is
left strictly alone.

### Files OUTSIDE `/opt/` that stock updates overwrite

From path #4 (`/opt/PROGRAM/software/<ver>/run.sh`) and path #5
(`/opt/PROGRAM/kernel/<ver>/run.sh`), the **6-file whitelist**:

| Path | Origin | Why FF ships it |
|---|---|---|
| `/etc/init.d/rcS` | Tina (Buildroot template) | FF's customised version: the standard BR `S??` loop **plus** the rcS-tail audio routing, libcrypto symlinks, and the all-important final `/opt/auto_run.sh &` line that wires in path #1–#3 dispatch |
| `/bin/zip` | Tina (Buildroot `infozip` package) | FF likely ships a vendored variant; the OTA path packages it for atomic updates |
| `/bin/wifi_reconnect` | FF-maintained shim | **6-line `wpa_cli` action stub that doesn't actually reconnect anything** — see [Footnote A](#footnote-a--binwifi_reconnect-is-a-misnomer) |
| `/sbin/iwlist` | Tina (Buildroot `wireless-tools`) | Updates carry FF's vendored build |
| `/lib/modules/8821cu.ko` (5.1.4 updater destination) | Built from Tina's `drivers/staging/rtl8821cu/` in FF's kernel build | The WiFi driver; vermagic-locked to the BSP kernel |
| `/etc/udhcpd.conf` | Tina default | Updates can overwrite with FF-tuned DHCP-server config |

Plus one quirky entry that lands NOT in Tina-territory but on `/data`:

| Path | Notes |
|---|---|
| `/data/logFiles/firmwareExe` | The QT touchscreen UI binary. Path #4's `run.sh` copies it to `/data/logFiles/firmwareExe` (NOT `/opt/PROGRAM/`) so it survives a future `/opt/PROGRAM/software/<ver>/` re-extract. The UI checks for this path at startup and uses the `/data` copy if present — FF's "OTA the UI without touching the read-mostly rootfs" trick. |

### Files that stock updates DO NOT touch

Everything else in the Tina rootfs is untouched by any of paths #3–#5:

- `/bin/busybox` and all the busybox symlinks (`ls`, `cat`, `sh`, …)
- All ~600 entries in `/usr/bin/*` (PostgreSQL, BlueZ, can-utils, GStreamer,
  csslint, alsamixer, …)
- `/usr/lib/*`, `/usr/share/*` (Tina's bundled libs and locale/man data)
- The other `/etc/init.d/S??*` scripts (`S01syslogd`, `S02klogd`, `S10udev`,
  `S20urandom`, `S30dbus`, `S40network`, `S50postgresql`, `S50telnet`,
  `S80dnsmasq`) — only `rcS` itself is overwritten
- `/lib/libc.so.*`, libstdc++, libgcc, the rest of the base C/C++ runtime
- Tina's audio HAL / video HAL / codec libs (under `/usr/lib/`)
- `/system/`, `/Settings/` mountpoint directories themselves
- **p4 `boot.img`** — not selected by the validated environment and not written
  by the captured 5.1.4 updater. Its kernel component instead writes FAT p1
  (see [path #5](#path-5-in-detail--kernel--library-update)).
- `boot0` / SPL / U-Boot (raw sectors before p1) and the U-Boot env (`mmcblk0p2`–`p3`)
  — **never** touched by any stock OTA path we captured. `fw_setenv` can write the env from userspace. On this unit FEL is not
  externally accessible; recovery requires the eMMC reader (RUNBOOK Path B).

### Practical takeaway

Stock updates replace selected `/opt/PROGRAM/` components and rootfs files;
the captured 5.1.4 kernel component also writes FAT p1. They do not clear mod
state under `/opt/config/mod`, `/data/.mod/.forge-x` or `/etc/init.d/S00init`.
The bulk of Tina is left alone, and the small set FF
overwrites are all files FF maintains its own builds of anyway.

For **Mode 3** this matters because every one of the 6 whitelisted files
comes from our own build automatically (modern `wireless-tools`, modern
`infozip`, our kernel's 8821cu, our init's `rcS`-equivalent, our own
DHCP server config). The stock update mechanism's "touchpoints outside
`/opt/`" are exactly the files we'd be replacing wholesale anyway, so
they're not a blocker for the own-rootfs work.

#### Footnote A — `/bin/wifi_reconnect` is a misnomer

Despite the name, neither stock nor forge-x's `wifi_reconnect` actually
reconnects anything. They are both `wpa_cli` action scripts (the format
you register via `wpa_cli -B -a <script> -i wlan0` so wpa_supplicant
invokes them on state changes), and both are basically logging stubs.

| | Stock `/bin/wifi_reconnect` (116 B / 6 lines) | forge-x `.shell/boot/wifi_reconnect.sh` (618 B / 27 lines) |
|---|---|---|
| Shell | `#!/bin/sh` | `#!/bin/bash` |
| Sources `common.sh`? | no | yes (gets `$WIFI_CONNECTED_F`, `logged()`) |
| On `CONNECTED` | `echo "connection established"` | `echo "Connection Established"` **+ `touch "$WIFI_CONNECTED_F"`** marker |
| On `DISCONNECTED` | `echo "connection lost"` | `echo "?? Connection Lost"` **+ `rm -f "$WIFI_CONNECTED_F"`** |
| Catch-all | none (silent) | `echo "Received Wi-Fi signal: $@"` |
| Output | stdout (wherever the parent dropped it) | `\| logged "/data/logFiles/wifi.log"` |
| Actually reconnects? | **no** | **no** |

The **real** reconnect logic on forge-x is in a separate
`wifi_connect.sh` (no "re") invoked at boot in a 5-retry loop
(see `forge-x/.shell/boot/boot.sh::wifi_init`). After the initial
association, `wpa_supplicant` itself maintains the connection — the
action script is a passive event listener, not a reconnector.

The genuinely useful thing forge-x's version does (and stock's doesn't):
maintain a **`$WIFI_CONNECTED_F` marker file**. Other forge-x components
can answer "am I currently online?" with `[ -f "$WIFI_CONNECTED_F" ]` —
no `wpa_cli status` parsing, no `ip link` polling. Tiny but useful
primitive.

ReForge's `packaging/live/net-up.sh` does the equivalent of forge-x's
`wifi_connect.sh` (the actual association logic) but does not yet ship
an equivalent of `wifi_reconnect.sh` (the marker-file maintainer). If we
want feature parity with forge-x on the "is wifi up?" primitive, we'd
ship a 20-line `wpa_cli` action script and register it via `wpa_cli
-B -a <script>` after `wpa_supplicant` launch. Tracked as backlog
follow-up.

## Cross-reference to ReForge

| Stock path | ReForge equivalent | Notes |
|---|---|---|
| #1 USB tarball (`Adventurer5MPro-*.tgz`) | **USB `.tgz` installer route** in [`deployment-modes.md`](../deployment-modes.md) — the stock-format `reforge-<ver>.tgz`. `auto_run.sh` only matches `Adventurer5MPro-*.tgz`, so the file must be renamed to that pattern on the stick | Same hook, same exit-0 → sleep 100000 semantics. We **don't** modify `/opt/PROGRAM/*` through the `.tgz` installer route; we write to `/data/.mod/.reforge/` instead. |
| #2 USB bare `flashforge_init.sh` | **live mode** (`packaging/live/flashforge_init.sh`) | Same hook. The live launcher exits non-zero from `auto_run.sh`'s perspective only if it fails to mount/start — normally it blocks forever inside its own `while true; do sleep; done` so the stock flow never resumes. |
| #3 MCU firmware (`Update` flag) | **NOT TOUCHED today.** ReForge runs against the stock-shipped MCU firmware (v0.11). If we ever ship a different MCU image (for v0.13 upgrade), we'd reuse this same path: drop the new `.bin`/`.hex` into `/opt/PROGRAM/control/<newver>/` and create the `Update` flag. | We **hold the binaries** for path #3 (`Mainboard-20230831.bin`, `Eboard-20231012.hex`, `NationsCommand`, `IAPCommand`, `mcu.img`) — see `docs/research/2026-06-04-klipper-v0.11-fork-deltas.md` §4 and the FF fork's `fw-Ad5m/` dir. Useful for emergency MCU re-flash. |
| #4 host software | **OTA mechanism** in [`ota.md`](../ota.md) — we publish per-component `.zip` bundles (`klipper.zip`, `moonraker.zip`, `guppyscreen.zip`, `reforge.zip`) for Moonraker's `update_manager` `type: zip`; Mainsail uses `type: web` against upstream releases | Different transport (HTTPS pull, not USB push), different target dir (`/opt/<component>` or `/mod` inside the chroot, not `/opt/PROGRAM/<sub>/<ver>/`). Same fundamental "drop a tree, run a hook, swap pointers" pattern. |
| #5 kernel/library | **NOT TOUCHED today.** Mode 2 (install-on-stock) explicitly does not replace the kernel or `/opt/PROGRAM/library/`. **Mode 3** (full-replacement, Plan 5) will own the kernel build but should keep this hook so a stock `.tgz` can downgrade to factory. | Forward-compat thing to remember when designing Mode 3's update mechanism. |
| #6 cloud OTA | Absent after successful live startup and in planned Modes 2b/3; still present in installed Mode 2a because the stock UI runs. | [Current closure status](../security-findings.md). |

## Implications for Mode 3 (full-replacement) design

When ReForge builds its own rootfs (per [`deployment-modes.md`](../deployment-modes.md)
Mode 3), the upgrade-mechanism question becomes: **how much of the stock
upgrade infrastructure do we re-implement?**

Recommended baseline:
- **Keep path #1 fully functional** — a stock-format `Adventurer5MPro-*.tgz`
  on a USB stick should *still* be picked up by our equivalent of
  `auto_run.sh` and treated as an emergency "flash stock back" path.
  This is the "no FEL, no UART" brick-safety boundary from
  [`board-notes/partition-map.md`](partition-map.md).
- **Keep path #2 functional** for our own live-launcher mechanism.
- **Keep path #3 (MCU update)** as a hook — we still need to flash
  N32G455 firmware sometimes, and `NationsCommand`/`IAPCommand` are
  reusable as-is.
- **Drop paths #4 and #5** — they target `/opt/PROGRAM/*` which is FF's
  product layout, not ours. ReForge updates live through Moonraker's
  `update_manager` and don't need the legacy mechanism.
- **Drop path #6** — spec.

## See also

- [`boot.md`](../boot.md) §4 — the `auto_run.sh` boot-chain position
- [`stock-rootfs-provenance.md`](stock-rootfs-provenance.md) — what's in
  `/opt/PROGRAM/`, who put it there
- [`partition-map.md`](partition-map.md) — the eMMC layout and brick-safety
  tier per partition
- [`../deployment-modes.md`](../deployment-modes.md) — ReForge's three
  modes + two installer invocation paths
- [`../ota.md`](../ota.md) — ReForge's own OTA mechanism (the path-#4
  equivalent we ship)
- [`../research/2026-06-04-klipper-v0.11-fork-deltas.md`](../research/2026-06-04-klipper-v0.11-fork-deltas.md)
  §4 — the MCU firmware binaries we hold (path #3 ammo)
