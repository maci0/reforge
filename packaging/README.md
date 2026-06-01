# ReForge Packaging

This directory contains the installer for the ReForge firmware overlay for the
FlashForge AD5M Pro (armv7, AllWinner H616).

---

## WARNING: MCU Caveat — Printer Will NOT Print Until Plan 4

A flashed ReForge boots cleanly and serves **Mainsail + Moonraker** on the local
network, but **klippy will not connect to the stock v11 MCU**.  Driving the
printer (motion, heaters, fans, print jobs) requires **Plan 4**, which flashes a
matching upstream Klipper MCU firmware onto the eboard.  Until then the web
interface is live but print control is non-functional.

---

## What the `.tgz` Is

`make tgz` produces `packaging/dist/reforge-<ver>.tgz`, a **stock-format FlashForge
OTA package** — a plain tar of xz-compressed subpackages plus a `flashforge_init.sh`
script.  The stock USB-updater (and `auto_run.sh`) can unpack and run it exactly like
any official FlashForge update.

### Subpackage Layout

```
reforge-<ver>.tgz
├── flashforge_init.sh          ← entry point; stock updater runs this
├── software-<ver>.tar.xz       ← ReForge rootfs overlay (klipper, moonraker,
│                                   mainsail, nginx, guppyscreen, boot glue)
├── library-<ver>.tar.xz        ← shared libs / Python wheels (reserved)
├── control-<ver>.tar.xz        ← MCU firmware stub (EMPTY — Plan 4 placeholder)
└── md5sum.list                 ← sha/md5 manifest; installer verifies before commit
```

The `control-` subpackage is an **empty reserved stub**.  Real MCU firmware is
built and flashed in Plan 4.

---

## Build

```sh
make tgz
# output: packaging/dist/reforge-<ver>.tgz
```

Version is read from `packaging/VERSION`.

---

## Install Flow

1. **USB updater** detects the `.tgz` on a FAT-formatted USB stick and unpacks it
   to a temp dir on `/data`.
2. **`flashforge_init.sh`** is called by the stock `auto_run.sh` as
   `flashforge_init.sh Adventurer5MPro 0024`.  It:
   - Validates machine type + PID.
   - Verifies the `md5sum.list` of the extracted archive.
   - Atomically renames the temp dir to `/data/.reforge`.
   - Writes the default screen mode (`SCREEN_MODE=HEADLESS`) to
     `/data/.reforge/config/screen.conf`.
   - Symlinks `/data/.reforge/.shell/reforge-boot` as `/etc/init.d/S01reforge`
     (the **boot hook**).
3. **Boot hook** (`S01reforge` / `reforge-boot`): on next boot, the stock `/etc/rcS`
   calls this script which:
   - Checks the **SKIP_MOD** guard (see Dual-Boot below).
   - Bind-mounts `/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/data`, `/opt/config`
     into the chroot.
   - `exec chroot /data/.reforge /etc/init.d/rcS start` — runs the ReForge init
     chain (cloud-block → zram → Klipper → Moonraker → nginx → GuppyScreen if enabled).

**Stock kernel, partitions, and FlashForge binaries are never modified.**
A bad install is recoverable by reflashing the stock `.tgz` from USB.

---

## Uninstall

```sh
# On the printer (via SSH or serial):
tar -xf reforge-uninstall-<ver>.tgz -C / && sh /tmp/reforge-uninstall.sh
```

Or flash `packaging/uninstall/reforge-uninstall-<ver>.tgz` via the USB updater —
it is also a stock-format package whose `flashforge_init.sh` removes `/data/.reforge`
and the `/etc/init.d/S01reforge` symlink.

---

## Dual-Boot (SKIP_MOD)

To boot stock firmware without uninstalling ReForge:

```sh
# On the printer — boot stock once (cleared on next boot):
touch /tmp/SKIP_MOD

# Persistent skip (survives reboots until removed):
touch /data/.reforge/SKIP_MOD
rm /data/.reforge/SKIP_MOD   # to re-enable ReForge
```

When any SKIP_MOD marker is present, `reforge-boot` exits immediately and the stock
firmware stack continues normally.  The stock `firmwareExe` UI runs as if ReForge were
not installed.

---

## Screen Modes

Configured in `/data/.reforge/config/screen.conf` (`SCREEN_MODE=<mode>`).

| Mode | Description | Status |
|------|-------------|--------|
| `HEADLESS` | No display daemon. Mainsail/Moonraker served over HTTP. **Default.** | Implemented |
| `GUPPY` | GuppyScreen Qt5 touchscreen UI against upstream Klipper. | Implemented (Plan 2) |
| `STOCK` | Stock FlashForge `firmwareExe` Qt4/QWS UI against upstream Klipper. | Feasibility confirmed (see below) — implementation deferred to a later plan |

### STOCK Mode — Feasibility (spike-stockui, Plan 3)

The Plan 3 spike confirmed that STOCK mode is feasible (**GO — Option A**):

- `firmwareExe` renders to `/dev/fb0` via Qt4 LinuxFB — **confirmed** by qemu test.
- `firmwareExe` connects to Klipper at `/tmp/uds` using **standard upstream JSON-RPC**
  — no proprietary protocol gap.
- All required Klipper objects (`objects/query` payload) are available in upstream
  Klipper.  The only work is adding `[temperature_sensor weightValue/tvocValue]` and
  `[gcode_button btn_power]` entries to `printer.cfg` — no custom modules.
- Constraint: `firmwareExe` is **soft-float ABI** and must run in the stock soft-float
  environment, not inside the ReForge hard-float chroot.

Full spike findings: `spike-stockui/REPORT.md`.

Implementation of STOCK mode is **deferred** to a future plan.

---

## Validation (Without Flashing)

### Loopback Test

```sh
make validate-loopback
```

Runs `flashforge_init.sh` with `REFORGE_SKIP_ARCH_CHECK=1` and `REFORGE_DATA_ROOT`
pointing at a tmpfs scratch directory.  Verifies that the overlay installs cleanly
and the boot hook is placed correctly — all on an x86 host, no printer needed.

### qemu Harness

The `validation/qemu-harness/` directory contains a qemu-system-arm test harness
that boots a virt-machine kernel + the stock rootfs + the ReForge overlay and runs
install, boot, web-reachability, and GUI-render tests.

```sh
make qemu-kernel    # build the virt ARM kernel (heavy, sudo, one-time)
make qemu-update    # run the update-process test
make qemu-render    # run the GuppyScreen / STOCK-UI render test
```

These are **local-only** — they require sudo, ~10 GB of stock rootfs data, and
significant build time.  They are not run in CI.  See
`validation/qemu-harness/README.md` for full setup and expected results.

---

## Proprietary Blob Policy

The repo must **never track** FlashForge proprietary blobs (`firmwareExe`, Qt `.so`
libraries, `/opt/PROGRAM/` contents).  The spike extracts them only to
`spike-stockui/extracted/` which is gitignored.

A CI job (`no-blobs` in `.github/workflows/build.yml`) fails if any tracked file path
matches these patterns — providing an automated guard against accidental commits.

## Known follow-ups (Plan 4)
- **`reforge-boot` mount-unwind on failure:** the boot hook runs under `set -e`; a
  failed chroot bind-mount aborts mid-sequence, leaving partial mounts. Harmless today
  (mounts are read-through; uninstaller lazy-unmounts), but add a `trap` that unwinds
  partial mounts on failure before Plan 4 puts real print services behind it.
- The canonical `reforge-boot` lives in the rootfs overlay
  (`br-external/board/reforge/rootfs-overlay/.shell/reforge-boot`) — it ships inside the
  rootfs; there is intentionally no copy under `packaging/`.
