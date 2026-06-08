# ReForge deployment modes

Canonical taxonomy of how ReForge gets onto a printer. Three deployment modes
(increasing commitment: **live → install-on-stock → full replacement**) plus two
mode-2 installer paths. The mechanics live elsewhere — this is the map:
the install overlay model is in [architecture.md](architecture.md), the live
launcher in [live-mode.md](live-mode.md), the stock boot chain + USB hook in
[boot.md](boot.md), and self-update in [ota.md](ota.md).

## The three deployment modes

### Mode 1 — Live (USB-booted, true zero-touch)

Boots from USB and changes **nothing** on the device — pull the stick + reboot →
pristine stock. OS + user writes go to RAM (tmpfs, or an OverlayFS `lower=/data,
upper=tmpfs`); nothing persists.

**Status: future.** Blocked on OverlayFS (stock kernel ships `# CONFIG_OVERLAY_FS
is not set`). Today's "live mode" is really Mode 2 with the rootfs source swapped
to USB (see [live-mode.md](live-mode.md)) — it still writes ~nothing to eMMC. The
loadable-OverlayFS route that would unlock a true Mode 1 is designed in
[plans/2026-06-05-immutable-reforge.md](plans/2026-06-05-immutable-reforge.md)
(spiked green in [research/kernel/2026-06-05-overlayfs-on-bsp-spike.md](research/kernel/2026-06-05-overlayfs-on-bsp-spike.md)).

### Mode 2 — Install on stock kernel (the forge-x / zmod pattern)

Installed at `/data/.mod/.reforge/` on the stock eMMC; stock kernel, U-Boot and
rootfs are left intact. A single `/etc/init.d/S01reforge` symlink hooks the boot
chain (details: [boot.md](boot.md) §7). Co-exists with forge-x
(`/data/.mod/.forge-x/`). Uninstall = remove the dir + symlink → pure stock.

**Status: shipped.** This is what `packaging/flashforge_init.sh` installs.

### Mode 3 — Full replacement (own kernel + rootfs)

ReForge replaces the stock kernel (`boot.img` on `mmcblk0p4`) and eventually U-Boot,
and ships its own rootfs on `mmcblk0p6`, running at `/` (no chroot). The factory USB recovery hook is
**preserved** — the `auto_run.sh`-equivalent still picks up stock
`Adventurer5MPro-*.tgz` recovery bundles, so a user can always reflash back to
factory.

**Status: planned (Plan 5).** Mainline-LTS kernel + ReForge U-Boot + a
`reforge_t113_defconfig` (mainline support tracked in
[research/kernel/2026-06-01-t113-mainline-kernel-support.md](research/kernel/2026-06-01-t113-mainline-kernel-support.md)).

## Mode-2 installer paths

Both reach the same on-disk end state via the same entry point
(`packaging/flashforge_init.sh`):

- **Path A — from a stock FW upgrade** (shipped). User drops `reforge-<ver>.tgz`
  on a FAT USB; the stock `auto_run.sh` (rcS USB hook, [boot.md](boot.md) §4)
  extracts it to `/data/update/` and runs the bundled installer with the stock ABI.
- **Path B — from live mode** (not yet). A `reforge install` command installs the
  *currently running* USB rootfs + chosen runtime state to eMMC, avoiding the
  "pull stick → download → reflash" loop. Needs a small refactor of the installer
  to accept a directory-tree source instead of only a `.tgz`.

## See also

- [architecture.md](architecture.md) — the Mode 2 overlay/chroot implementation
- [live-mode.md](live-mode.md) — the current USB launcher (Mode-2-with-USB-source)
- [boot.md](boot.md) — stock boot chain + the `auto_run.sh` USB hook (path A)
- [ota.md](ota.md) — how an installed ReForge updates itself
- [board-notes/partition-map.md](board-notes/partition-map.md) — eMMC layout Mode 3 inherits
- [plans/2026-06-01-plan3-installer.md](plans/2026-06-01-plan3-installer.md) — original installer plan (path A); path B still to add
