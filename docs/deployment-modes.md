# ReForge deployment modes

Canonical taxonomy of how ReForge gets onto a printer. Three deployment modes
(increasing commitment: **live → install-on-stock → full replacement**) plus two
mode-2 installer routes. The mechanics live elsewhere — this is the map:
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
to USB (see [live-mode.md](live-mode.md)): it creates `/reforge` on p6 and
persists uploaded gcode on p7. The loadable-OverlayFS route that would unlock a true Mode 1 is designed in
[plans/2026-06-05-immutable-reforge.md](plans/2026-06-05-immutable-reforge.md)
(spiked green in [research/kernel/2026-06-05-overlayfs-on-bsp-spike.md](research/kernel/2026-06-05-overlayfs-on-bsp-spike.md)).

### Mode 2 — Install on stock kernel (the forge-x / zmod pattern)

- **Mode 2a (current):** the installed chroot launched by `S01reforge`; stock init
  continues and launches the stock UI.
- **Mode 2b (planned):** replace PID 1 with `reforge-init` and pivot into ReForge,
  skipping the stock init/UI chain. It is not wired into the installer.

Installed at `/data/.mod/.reforge/` on the stock eMMC; stock kernel, U-Boot and
rootfs contents remain in place. A single `/etc/init.d/S01reforge` symlink hooks the boot
chain (details: [boot.md](boot.md) §7). The installer refuses to proceed while
forge-x or another competing mod is still present
([packaging/README.md](../packaging/README.md#before-you-install--other-mods-must-be-cleanly-uninstalled)).
Uninstall removes the dir and the symlink; only the empty `/reforge` mountpoint
directory stays on p6. The stock UI is not suppressed in this mode: `reforge-boot`
returns after starting the services and `auto_run.sh` still launches `firmwareExe`
([security findings](security-findings.md)).

**Status: shipped.** This is what `packaging/flashforge_init.sh` installs. Validated
under qemu (`make qemu-update`); the [loopback test](../tests/README.md#loopback-install-test)
still checks an obsolete layout. No install-mode hardware trial is recorded yet.

### Mode 3 — Full replacement (own kernel + rootfs)

ReForge would replace the stock kernel (currently `uImage` on FAT p1; see the
[verified boot chain](boot.md#1-the-boot-chain-verified)) and eventually U-Boot,
and ship its own rootfs on `mmcblk0p6`, running at `/` (no chroot). The planned
factory USB recovery hook would pick up stock
`Adventurer5MPro-*.tgz` recovery bundles while the replacement system can still reach that hook. It cannot
recover a bootloader or kernel failure that prevents userspace startup.

**Status: planned (Plan 5).** Mainline-LTS kernel + ReForge U-Boot + a
`reforge_t113_defconfig` (mainline support tracked in
[research/kernel/2026-06-01-t113-mainline-kernel-support.md](research/kernel/2026-06-01-t113-mainline-kernel-support.md)).

## Mode-2 installer paths

Both reach the same on-disk end state via the same entry point
(`packaging/flashforge_init.sh`):

- **USB `.tgz` installer route** (shipped). User copies `reforge-<ver>.tgz`
  to a FAT USB under a name matching `Adventurer5MPro-*.tgz` (the only pattern
  `auto_run.sh` scans for); the stock `auto_run.sh` (rcS USB hook, [boot.md](boot.md) §4)
  extracts it to `/data/update/` and runs the bundled installer with the stock ABI.
- **Live-install route** (not yet). A `reforge install` command installs the
  *currently running* USB rootfs + chosen runtime state to eMMC, avoiding the
  "pull stick → download → reflash" loop. Needs a small refactor of the installer
  to accept a directory-tree source instead of only a `.tgz`.

Older plans call these installer routes A and B. Those labels are separate from
[RUNBOOK recovery Paths A and B](../tools/recovery/RUNBOOK.md).

## See also

- [architecture.md](architecture.md) — the Mode 2 overlay/chroot implementation
- [live-mode.md](live-mode.md) — the current USB launcher (Mode-2-with-USB-source)
- [boot.md](boot.md) — stock boot chain + the `auto_run.sh` USB hook (`.tgz` installer route)
- [ota.md](ota.md) — how an installed ReForge updates itself
- [board-notes/partition-map.md](board-notes/partition-map.md) — eMMC layout Mode 3 inherits
- [plans/2026-06-01-plan3-installer.md](plans/2026-06-01-plan3-installer.md) — original `.tgz` installer plan; live-install route still to add
