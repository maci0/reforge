# ReForge deployment modes

The long-term shape: ReForge supports **three deployment modes** plus **two
installer invocation paths**. This doc is the canonical mapping; it
super-cedes any earlier framing that conflated "live" with "zero eMMC writes".

The order is roughly the order of increasing commitment to the device:
**live → install-on-stock → full replacement**.

## The three deployment modes

### Mode 1 — Live (USB-booted, true zero-touch)

**Definition:** ReForge boots from USB and **does not change anything on the
device directly**. Pull the stick + reboot → printer is byte-identical to
what it was before the USB was inserted.

| | |
|---|---|
| Boot source | USB stick (`p1` vfat hook + `p2` f2fs rootfs) |
| eMMC writes | **zero** (OS + user data both live in RAM or on USB) |
| `/data` inside chroot | tmpfs **or** overlay-fs whose lower is the eMMC `/data` and whose upper is tmpfs (so the user sees the stock gcodes etc., but writes go to RAM) |
| Persistence across reboots | **none** (everything in RAM is lost; F2FS USB state is what the user manually packed) |
| Use case | "Try ReForge for 5 minutes, don't commit." |
| Implementation status | **Future.** Blocked on either OverlayFS in the stock kernel (`# CONFIG_OVERLAY_FS is not set`) or our own kernel (Mode 3 prerequisite). Today's "live mode" is actually Mode 2 with the rootfs source swapped for USB \u2014 see below. |

### Mode 2 — Install on stock kernel (the forge-x / zmod pattern)

**Definition:** ReForge is installed at `/data/.mod/.reforge/` on the stock
eMMC ext4. The stock kernel, stock U-Boot, and stock rootfs (`/opt/PROGRAM`,
`/etc/init.d/`, etc.) are **left intact**. A single
`/etc/init.d/S01reforge → /data/.mod/.reforge/.shell/reforge-boot` symlink
hooks the boot chain. Coexists with forge-x (`/data/.mod/.forge-x/`) without
conflict.

| | |
|---|---|
| Boot source | eMMC `/data/.mod/.reforge/` (chrooted into) |
| eMMC writes | install overlay + LKG bookkeeping + runtime state (klippy log, moonraker DB) |
| `/data` inside chroot | eMMC `mmcblk0p7` (bind from host) — same path as stock |
| Persistence across reboots | full |
| Stock UI | does not run (ReForge's `S01reforge` takes over before `auto_run.sh` reaches `ffstartup-arm`) |
| Revert | uninstall removes `/data/.mod/.reforge/` + the `S01reforge` symlink → next boot is pure stock |
| Use case | The default, long-term ReForge user. |
| Implementation status | **Shipped today.** This is what `packaging/flashforge_init.sh` installs. |

### Mode 3 — Full replacement (own kernel + rootfs)

**Definition:** ReForge replaces the stock kernel (and U-Boot, eventually)
and ships its own rootfs in `mmcblk0p6` (the rootfs partition). The
**factory USB recovery hook is preserved** \u2014 i.e.
`/etc/init.d/rcS:50 → /opt/auto_run.sh` (or its equivalent in our init)
still scans USB for `Adventurer5MPro-*.tgz` / `flashforge_init.sh` and runs
them, so a user can always drop a stock recovery .tgz on a USB stick and
reflash back to factory.

| | |
|---|---|
| Boot source | eMMC `mmcblk0p4` (boot.img with ReForge kernel) + `mmcblk0p6` (ReForge rootfs) |
| eMMC writes | the rootfs IS on eMMC; persistent by definition |
| `/data` inside chroot | n/a \u2014 ReForge is at `/`, not in a chroot |
| Stock UI | gone; the stock binary `firmwareExe` is removed from the rootfs |
| Stock recovery USB hook | **preserved** \u2014 the auto_run-equivalent in our init still picks up factory recovery `.tgz` files so users can always go back to stock |
| Revert | drop a stock `Adventurer5MPro-*.tgz` on USB; boot; recovery flow restores stock |
| Use case | The long-term destination once the mainline kernel port is mature. |
| Implementation status | **Planned, Plan 5.** Mainline-LTS kernel + ReForge U-Boot + a `reforge_t113_defconfig` that strips everything not in `docs/board-notes/stock-kernel-config-5.4.61.txt.gz`. |

## The two installer invocation paths (mode 2)

The mode-2 installer **must** be reachable from both of these starting
states, with the same end state on disk:

### Path A — From a stock FW upgrade

The user drops `reforge-<ver>.tgz` on a FAT USB stick. The **stock**
`/opt/auto_run.sh` picks it up (mmcblk0p6 rcS:50 hook \u2014 see
[boot.md](boot.md) \u00a74), extracts to `/data/update/`, and runs the bundled
`flashforge_init.sh` with the stock-installer ABI (`MACHINE PID` args).

- **Reaches:** users who have never run ReForge before, including users on
  pristine stock who don't even have ReForge live mode tried out.
- **Source of truth:** the `.tgz` contents on USB.
- **Installer entry point:** `packaging/flashforge_init.sh` (currently shipped).

### Path B — From live mode

The user is currently running ReForge live mode (Mode 1, or the transitional
mode 2-on-USB we have today). They decide to commit to the device. A single
command \u2014 e.g. `reforge install` from a Mainsail dialog or an SSH session \u2014
invokes the installer **with the currently running state as the source**.

Specifically, the installer must:
1. Take the live USB's F2FS rootfs content as the install source (instead
   of a `.tgz`)
2. Include any **runtime state** the user wants preserved: `SAVE_CONFIG`
   appends in `/etc/reforge/printer.cfg`, moonraker job history DB,
   per-component config (e.g. WiFi creds, screen mode).
3. Write all of that to `/data/.mod/.reforge/` on the eMMC.
4. Install the `S01reforge` symlink.
5. Stamp `/data/.mod/.reforge/.installed`.

- **Reaches:** users who tried ReForge live and liked it. Avoids
  shipping a separate `.tgz` and the awkward "pull stick \u2192 download \u2192
  reflash" loop.
- **Source of truth:** the running USB rootfs + the user's runtime state.
- **Installer entry point:** the same `packaging/flashforge_init.sh`,
  refactored to accept `--source=running` (or a `REFORGE_INSTALL_SOURCE=running`
  env var) so the source\u2192target logic is shared between path A and path B.

**Implementation status:** **Path A: shipped today. Path B: not yet
implemented.** The current installer reads from `/data/update/software-VER.tar.xz`
(path A only); refactoring it to accept a directory tree source is a small
change but hasn't been done.

## What's running today vs the target

| | Target (this doc) | Today |
|---|---|---|
| Mode 1 \u2014 Live (true zero-touch) | RAM-resident or tmpfs/overlay-backed; zero eMMC writes | **Conflated with Mode 2.** Today's `packaging/live/flashforge_init.sh` mounts the F2FS USB at `/data/.mod/.reforge` and binds host `/data` into the chroot \u2014 effectively a Mode 2 install whose rootfs source is the USB partition instead of the eMMC directory. The OS still writes virtually nothing to eMMC; the only writes are user-uploaded gcodes (intentional) and the one-time `mkdir /data/.mod/.reforge` mountpoint. |
| Mode 2 \u2014 Install on stock | `/data/.mod/.reforge/` overlay, single `S01reforge` symlink, forge-x co-existence | **Shipped.** Migration to `/data/.mod/.reforge/` (from `/data/.reforge/`) completed 2026-06-05 to match the forge-x / zmod pattern. |
| Mode 3 \u2014 Full replacement | ReForge kernel + rootfs on `mmcblk0p{4,6}`; factory `.tgz` recovery preserved | **Planned (Plan 5).** Mainline-LTS port. |
| Install path A \u2014 from stock FW upgrade | reads `.tgz` from `/data/update/` | **Shipped.** `packaging/flashforge_init.sh` is the entry point. |
| Install path B \u2014 from live mode | reads running USB rootfs + runtime state, writes to eMMC | **Not yet.** Needs a small refactor of `packaging/flashforge_init.sh` to accept a directory-tree source. |

## Migration notes

- Today's "live mode" is renamed conceptually to **Live-as-Mode-2-with-USB-source**
  in this doc, but the user-facing command and the file
  (`packaging/live/flashforge_init.sh`) keep the "live" name for continuity.
  Once we ship a true Mode 1, we can decide whether to rename the
  USB-source-Mode-2 variant or keep both as separate user-facing modes.
- The `/data/.mod/.reforge/` path mirrors forge-x's `/data/.mod/.forge-x/`
  and zmod's `/data/.mod/.zmod/`. The `/data/.mod/` directory is a shared
  namespace any vendor mod can claim a subdir under, by convention.
- For Mode 3, the `/data/.mod/.reforge/` path becomes irrelevant (ReForge
  is at `/`), but the **`/data` partition itself** (mmcblk0p7) should be
  preserved if at all possible, so user gcodes survive a Mode 2 \u2192 Mode 3
  transition.

## See also

- [`docs/architecture.md`](architecture.md) \u2014 the current Mode 2 implementation
- [`docs/live-mode.md`](live-mode.md) \u2014 the current "live" launcher (which is
  Mode-2-with-USB-source in the framing of this doc)
- [`docs/boot.md`](boot.md) \u2014 the stock boot chain and the
  `auto_run.sh` USB hook (path A)
- [`docs/ota.md`](ota.md) \u2014 how Mode 2 updates itself once installed
- [`docs/board-notes/partition-map.md`](board-notes/partition-map.md) \u2014 the
  eMMC partition layout that Mode 3 inherits
- `docs/plans/2026-06-01-plan3-installer.md` \u2014 the original installer plan
  (was path A only; path B needs to be added)
- [`docs/BACKLOG.md`](BACKLOG.md) § **"immutable / atomic ReForge — OverlayFS2 (or similar) for transactional updates and true Mode 1 live"** — the parked design direction that, if it pans out, gives us atomic Mode 2 updates *and* a true Mode 1 live (with a `lowerdir=/data + upperdir=tmpfs` overlay) without waiting for Mode 3's own-kernel work. Open question first: does OverlayFS build as a loadable module against the stock 5.4.61 BSP.
