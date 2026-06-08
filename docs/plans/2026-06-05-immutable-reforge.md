# Plan: Immutable / atomic ReForge — versioned OverlayFS on the stock kernel

**Date:** 2026-06-05
**Status:** plan ready for review. Spike + on-hardware sanity check both passed (cited below); this plan turns those results into an implementation.
**Owner:** TBD (likely whoever picks up the next install/OTA-touching chunk).
**Depends on:** nothing else in flight. Slots in alongside the current Mode 2 install/OTA path; doesn't block Plan 5 (Mode 3 own-kernel).
**Replaces:** `docs/BACKLOG.md` §"immutable / atomic ReForge — OverlayFS2" (parked entry; this plan supersedes it).

---

## 0. Evidence the design rests on

Two prior pieces of work answered the open questions and produced the binary artefacts this plan builds on:

1. **Qemu spike** — `docs/research/kernel/2026-06-05-overlayfs-on-bsp-spike.md`
   Vanilla `fs/overlayfs/` source in the Tina BSP; CONFIG_OVERLAY_FS=m produces a 108 KB `.ko` from the same toolchain we use for production; the same source built `=y` mounts cleanly in qemu with correct semantics (read-from-lower, copy-up, whiteout, lower-immutability) and a per-mount cost of ~192 KiB MemAvailable + ~16 KiB ovl_inode slab on a 108 MB MemTotal box.

2. **On-hardware sanity check** — `modules/overlay-bsp/on-hw-sanity-check.log` (commit 1864397).
   `overlay.ko` built against the **exact** stock kernel config (vermagic `5.4.61 SMP preempt mod_unload ARMv7 p2v8`) + one patch (`modules/overlay-bsp/patches/0001-overlay-import-vfs-ns.patch`, adding `MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver)` to `fs/overlayfs/super.c`) loads and mounts on the running stock firmware. Real-hw cost matches qemu within noise (−172 kB MemAvailable vs −192 kB; 90 KB module resident). Cleanup returns memory to baseline.

So we have a known-loadable, known-working overlay module for the stock kernel. We can build on top of it without further measurement.

---

## 1. Goals (and explicit non-goals)

### Goals

- **G1 — Atomic install.** A fresh install from USB `.tgz` or from live mode places the new version on `/data`, then commits with a single pointer swap. Power loss before the swap leaves the device on the previous version. Power loss after the swap leaves it on the new version. There is no in-between.
- **G2 — Atomic OTA.** Moonraker `update_manager` writes a new version dir alongside the old, then the same pointer swap commits. Same power-loss guarantees as G1.
- **G3 — Real rollback.** Trial-N-fails (the existing LKG protection) and explicit `reforge-revert` become a pointer swap back, not a directory rename dance. The rollback is also power-loss-safe.
- **G4 — True Mode 1 live.** The live USB launcher mounts an overlay with `lowerdir=/data + upperdir=tmpfs`. Inside the chroot, `/data` shows the user's existing gcodes, configs, and SAVE_CONFIG sections, but writes go to RAM. Pull the stick + reboot = stock state, no eMMC residue.
- **G5 — Mode 3 alignment.** When ReForge ships its own kernel (Plan 5), the same design carries over by flipping `CONFIG_OVERLAY_FS=m` to `=y` and dropping the insmod step. No other code or layout changes.

### Non-goals

- **NG1 — Not block-level versioning.** No A/B partitions, no boot-loader pointer swap, no `mmcblk0p4` repartitioning. The atomicity boundary is one symlink on `/data`, nothing more.
- **NG2 — Not file-level deduplication.** Each version dir is its own copy of the relevant ReForge files; no ostree-style hardlink trees. Disk cost is small per version (few MB for ReForge stack overlay), so deduplication adds complexity without proportional benefit.
- **NG3 — Not user-data versioning.** Klipper's `/data/printer_data/` (gcodes, klippy.log, moonraker SQLite) stays outside the overlay. It's user state, not firmware. The user expects it to persist across upgrades and rollbacks.
- **NG4 — Not integrity verification.** dm-verity / fs-verity / signed manifests are out of scope for v1. We can layer those on later; the design doesn't preclude them.
- **NG5 — Not redirect_dir / metacopy.** Stick to the spike-confirmed sub-options (INDEX=y, XINO_AUTO=y; everything else off). Those features bring known-bad semantics on 5.4 overlayfs.

---

## 2. Disk layout

The on-eMMC layout under `/data/.mod/.reforge/` becomes:

```
/data/.mod/.reforge/
├── modules/                       Pre-built kernel modules shipped per release
│   └── overlay.ko                   (vermagic-matched 108 KB; loaded before mount)
├── versions/                      Version dirs (the "lower" layers)
│   ├── 0.3.0-dev/                   Each is a full copy of /mod that release ships
│   │   ├── start.sh                 (mod/, /etc/reforge/, /opt/{klipper,moonraker,…})
│   │   ├── init.d/
│   │   ├── etc/reforge/
│   │   ├── modules/
│   │   ├── usr/bin/
│   │   ├── services/
│   │   └── release_info.json
│   ├── 0.4.0/                       (the upgrade target on this device)
│   │   └── …
│   └── 0.3.0-dev.lkg                Last-known-good marker for rollback
├── upper/                         Writable upper-layer dirs (one per version)
│   ├── 0.3.0-dev/                   (mostly empty; tracks runtime changes)
│   └── 0.4.0/
├── work/                          OverlayFS workdir per version (kernel-internal)
│   ├── 0.3.0-dev/
│   └── 0.4.0/
├── current                        Atomic pointer: symlink to versions/<ver>
├── merged/                        Mount point (lower+upper+work get assembled here)
└── trial                          Trial-state marker (if a trial is in progress)
```

### The `current` symlink IS the atomic boundary

A symlink rename on ext4 is a single inode-pointer update on a journaled filesystem. It either completes (ext4 journal commit visible after reboot) or doesn't (next boot sees the pre-rename inode). No partial state.

```
/data/.mod/.reforge/current -> versions/0.4.0
```

`renameat2(AT_FDCWD, "current.new", AT_FDCWD, "current", RENAME_EXCHANGE)` swaps two existing symlinks atomically (requires RENAME_EXCHANGE flag, supported on ext4 since 3.15). For "no current yet" → "first install", a plain `rename("current.tmp", "current")` is sufficient.

### Mount sequence at boot

`reforge-boot` (or `S99reforge` if PID-1 is in use) does, in order:

```
1. insmod /data/.mod/.reforge/modules/overlay.ko       (only if not already loaded)
2. ver=$(readlink /data/.mod/.reforge/current)         (e.g. "versions/0.4.0")
3. mount -t overlay overlay \
       -o lowerdir=/data/.mod/.reforge/${ver}, \
          upperdir=/data/.mod/.reforge/upper/${ver##*/}, \
          workdir=/data/.mod/.reforge/work/${ver##*/}, \
          xino=off \
       /data/.mod/.reforge/merged
4. chroot /data/.mod/.reforge/merged /mod/start.sh     (existing chroot, now into the merged view)
```

The chroot sees `/mod/` from the lower (versioned, immutable), can write modifications that land in `upper/<ver>/` (per-version, so different versions don't see each other's writes), and the kernel's overlay handles the merging in flight.

### Mode 1 live (true live, the BACKLOG's other motivation)

Same code path, but the launcher (`packaging/live/flashforge_init.sh`) uses tmpfs for the upper:

```
mount -t tmpfs -o size=64m tmpfs /run/reforge-live-upper
mount -t tmpfs -o size=64m tmpfs /run/reforge-live-work
mount -t overlay overlay \
    -o lowerdir=/data, \
       upperdir=/run/reforge-live-upper, \
       workdir=/run/reforge-live-work \
    /data
```

This overlays `/data` itself: the user sees their existing gcodes and configs from the lower (the real eMMC `/data`), but every write (including `[virtual_sdcard]` uploads, SAVE_CONFIG appends, klippy.log writes) goes to the tmpfs upper. Remove the USB and reboot → the tmpfs evaporates → state is exactly what it was before, no eMMC residue.

Two policy points fall out of this:

- **Upper size cap (64 MB above)** prevents a runaway gcode upload from exhausting RAM. When the upper fills, writes get -ENOSPC, which Mainsail surfaces as "out of disk". User decides whether to install or just delete uploads.
- **`[virtual_sdcard] path` policy.** In live mode we keep it pointing at `/data/printer_data/gcodes/` (now overlaid). Uploads land on the tmpfs upper. A "saved" tab in the UI would help users distinguish persistent-on-eMMC vs ephemeral-on-RAM gcodes, but isn't required for v1.

---

## 3. Install flow (path A: USB `.tgz` updater)

The existing `packaging/flashforge_init.sh` runs as the stock USB updater. Today it extracts the .tgz, writes to `/data/.mod/.reforge/mod/`, and symlinks `S01reforge`. The new flow:

1. **Detect a fresh install vs an upgrade.** If `/data/.mod/.reforge/current` is a valid symlink → upgrade. Else → first install.
2. **Stage the new version.** Extract the .tgz into `/data/.mod/.reforge/versions/<new-ver>.partial/`. The `.partial` suffix is essential: it's a power-loss marker. A boot that finds `versions/*.partial/` knows extraction was interrupted and the dir is unsafe.
3. **Allocate upper + work dirs.** `mkdir -p upper/<new-ver> work/<new-ver>`.
4. **Verify the .partial.** Sha-256 the manifest if the .tgz ships one (it does — `md5sum.list`); reject + cleanup if it doesn't verify.
5. **Promote.** `mv versions/<new-ver>.partial versions/<new-ver>` (rename within same FS is atomic on ext4 — single inode/dirent transaction).
6. **Swap the pointer.**
   - First install: `ln -sfn versions/<new-ver> current.tmp && mv current.tmp current` (the `mv` is atomic on ext4).
   - Upgrade: `ln -sfn versions/<new-ver> current.new && renameat2(current.new, current, RENAME_EXCHANGE)`. After this call, `current` and `current.new` have swapped targets; `current.new` now points at the old version, which the cleanup step removes.
7. **Install/refresh the overlay.ko symlink.** `ln -sfn versions/<new-ver>/modules/overlay.ko modules/overlay.ko` so the next boot grabs the version-shipped module. This is also a symlink-rename, atomic.
8. **Update `S01reforge` symlink.** Only needed on first install — subsequent upgrades reuse the same `/etc/init.d/S01reforge` symlink because it points at `/data/.mod/.reforge/current/.shell/reforge-boot`, which transparently follows the new `current`.
9. **Update LKG marker.** `mv versions/<old-ver>.lkg versions/<new-ver>.lkg` AFTER N successful boots of the new version (existing trial mechanism, repurposed). Not part of the install transaction; happens during trial.

Power-loss-recovery on boot (in `reforge-boot` or `reforge-init`):

- Any `versions/*.partial/` dir → delete (interrupted extraction).
- If `current` doesn't exist or points at a non-existent target → fall back to the LKG (`versions/*.lkg`), set `current → versions/<lkg-ver>`, log to /var/log/reforge-recovery.
- If `current` exists but the target is missing → same LKG fallback.
- Boot-trial logic (existing) decides whether to make the current version "LKG" or roll back.

## 4. Install flow (path B: from live mode)

Live mode's chroot has access to the real eMMC `/data` (mounted at `/oldroot/data` after the live overlay is set up, or via a second mount in the live launcher). Triggered from the Mainsail "install ReForge to eMMC" button (or a CLI):

1. Same pre-flight as packaging/flashforge_init.sh (machine-type / forge-x conflict check / etc.).
2. Build the version dir IN PLACE: rsync (or busybox cp -a) from the live USB's `/mod/` and the relevant `/opt/{klipper,moonraker,...}` trees into `/oldroot/data/.mod/.reforge/versions/<ver>.partial/`.
3. The .partial → promote → swap dance, identical to path A from step 5 onward.

This is the path B that `docs/deployment-modes.md` notes as "not yet". The overlay-based design makes it trivial: it's just "build the lower layer dir and swap the pointer".

---

## 5. OTA flow

Moonraker's `update_manager` writes into `/opt/<component>/` on the device. Today that's a bind-mount into the chroot pointing at `/data/.mod/.reforge/mod/opt/<component>/`. The new flow:

1. Stage. `update_manager` zips the new component into `/data/.mod/.reforge/versions/<new>/opt/<component>/` (this requires a Moonraker config change: the `path` for each component now points at `versions/<staging-target>/...`, where `<staging-target>` is a new version dir the OTA orchestrator created at OTA-start time).
2. Verify. Moonraker already does this (`.writeable` check, manifest check). New step: the orchestrator copies the OTHER unmodified components from the current version into the new version dir (the OTA touches one component, but the new version dir must be self-contained).
3. Swap. Same `renameat2 RENAME_EXCHANGE` on `current`.
4. Restart services. The chroot is still running on the old overlay, so we have to umount the merged view, remount with the new lower, and re-exec the service chain. There's a brief klippy outage during this. (Improvement opportunity: dual-mount briefly and migrate, but v1 keeps it simple.)

The OTA orchestrator role is new — neither stock Moonraker nor today's ReForge has it. Two implementation options:

- **A1: Wrap moonraker's update_manager calls** in a small `reforge-ota-orchestrator` shim that intercepts the start-of-update event, creates `versions/<new>.partial/`, replays the current version into it, lets moonraker write, then commits. ~200 lines.
- **A2: Run moonraker against the upper layer** (not the lower) so writes naturally land in the per-version upper dir, and "commit" is just swapping. This is cleaner but means a moonraker-side patch (writes have to know they're upper-bound).

A1 is the lower-risk first implementation. A2 is the eventual destination once we've proved A1 works.

---

## 6. Rollback flow

Today `reforge-lkg.sh` runs at boot-N-fail and renames `mod` ↔ `lkg`. The new flow:

```
on_boot_failure() {
    lkg=$(ls /data/.mod/.reforge/versions/*.lkg 2>/dev/null | head -1)
    [ -z "${lkg}" ] && return 1                             # no LKG, nothing to roll back to
    lkg=${lkg%.lkg}                                         # versions/0.3.0-dev (the dir we point at)
    ln -sfn "${lkg}" /data/.mod/.reforge/current.new
    renameat2 current.new current RENAME_EXCHANGE
    rm /data/.mod/.reforge/current.new
    sync
    reboot
}
```

`renameat2` is the only call that needs care here; everything else is `rm` and `ln`. The whole sequence is bounded by one journal commit.

Explicit user-initiated rollback (`reforge-revert <ver>`) is the same, just driven by user input rather than boot-fail detection.

---

## 7. Build & release impact

### `tools/release/build-release.sh` changes

Today this script slices `build/output/target/{mod,opt}` into per-component zips. The new layout requires:

1. **Build `overlay.ko` once per release** using `modules/overlay-bsp/build.sh`, with the in-tree kernel-config-of-record as input. Ship it in the release artefact.
2. **Stage a complete version dir** in the .tgz: `mod/`, `modules/overlay.ko`, the version-stamped subset of `/opt/`.
3. **Manifest** the version dir for tamper-detection (the existing `md5sum.list` already does this; just point at the new layout).

### `packaging/flashforge_init.sh` changes

Refactor the install flow per §3 above. Keep the existing pre-flight (arch check, machine-type, competing-mod check) and SKIP_MOD honoring; replace the body that does "extract to `mod/` + symlink S01reforge" with the .partial → promote → swap dance.

### `br-external/board/reforge/rootfs-overlay/.shell/reforge-boot` changes

Add: insmod overlay.ko → readlink current → mount the overlay → chroot the merged. Today's chroot path becomes a chroot into `merged/` rather than into `mod/`'s parent.

Fallback: if any step fails, fall back to the previous-style direct chroot into `/data/.mod/.reforge/mod/` (which won't exist for new installs but exists for migrated-from-old installs during the transition window). After two full release cycles, drop the fallback.

### Migration from the current layout

A device currently running `/data/.mod/.reforge/mod/` (no `versions/`, no `current`) needs migration:

1. Boot once on the new release. `reforge-boot` detects `mod/` + no `current` → enters migration path.
2. `mv /data/.mod/.reforge/mod /data/.mod/.reforge/versions/<current-running-ver>`.
3. `mkdir -p /data/.mod/.reforge/{upper,work}/<current-running-ver>`.
4. `ln -sfn versions/<current-running-ver> /data/.mod/.reforge/current`.
5. Continue boot with the new overlay path. Log the migration.

Idempotent: if `current` already exists, skip.

---

## 8. Testing strategy

### New tests

| Test | What it gates | Where |
|---|---|---|
| `qemu-immutable-install` | Fresh install: extracts a "version" into versions/<v>/, swap pointer, boot, overlay merged correctly, klippy reaches ready | `tests/qemu-harness/immutable-install-test.sh` |
| `qemu-immutable-power-loss` | Kill qemu between .partial extraction and pointer swap; confirm next boot sees only the pre-install version | `tests/qemu-harness/immutable-power-loss-test.sh` |
| `qemu-immutable-rollback` | Two versions present, current → v1, boot-fail signal, current → v2, boot again, confirm rolled back | `tests/qemu-harness/immutable-rollback-test.sh` |
| `qemu-immutable-mode-1-live` | Live USB mounts overlay over /data with tmpfs upper; user upload lands in tmpfs; remove USB + reboot = byte-identical /data | `tests/qemu-harness/immutable-mode-1-live-test.sh` |
| `unit:test-overlay-paths` | Unit tests for the path-handling: current → versions/<v>, .lkg discovery, .partial cleanup | `tests/release/test_overlay_paths.py` |

### Existing tests to update

- `tests/qemu-harness/pid1-pivot-test.sh` — already passes; the reforge-init script needs the overlay-mount step added in the happy path. Tests gain a new assertion: "after pivot, /merged is an overlay".
- `tests/qemu-harness/live-mode-test.sh` and `live-ota-test.sh` — update the launcher path to mount the tmpfs upper. Gates remain: "no install state on eMMC p7" → strengthened, since now NOTHING lands on p7.
- `tests/qemu-harness/ota-test.sh` — update to expect the orchestrator-style write path (writes land in versions/<new>/opt/... not /data/.mod/.reforge/mod/opt/...).

### On-hardware verification points

- Migration: install the new release on a device currently running an old `mod/`-style install. Confirm migration log in /var/log/, confirm `current` set, confirm reboot clean.
- Rollback: deliberately corrupt a service in the current version dir, force boot-fail, confirm rollback to LKG.
- Mode 1 trial: live USB with the new launcher, upload a 10 MB gcode, remove USB, reboot. `sha256sum` the eMMC `/data/printer_data/gcodes/` and confirm byte-identical to pre-trial.

---

## 9. Phasing

### Phase 1 — substrate (~1 sprint)

- [ ] `modules/overlay-bsp/build.sh` integrated into `tools/release/build-release.sh` so `overlay.ko` ships in every release.
- [ ] `packaging/flashforge_init.sh` does the .partial → promote → swap dance for FRESH installs. Upgrade path defers to phase 2.
- [ ] `reforge-boot` insmods overlay, reads `current`, mounts the overlay, chroots merged. Fallback to old `mod/` chroot if `current` missing (backward compat).
- [ ] `tests/qemu-harness/immutable-install-test.sh` PASS.

### Phase 2 — upgrades + OTA (~1 sprint)

- [ ] Upgrade path in packaging/flashforge_init.sh (the `renameat2 RENAME_EXCHANGE` swap).
- [ ] `reforge-ota-orchestrator` shim wrapping update_manager events. Writes go to `versions/<new>/`. Swap on commit.
- [ ] Migration path for devices on the old layout (one-time on first boot of phase-1 release).
- [ ] `tests/qemu-harness/immutable-power-loss-test.sh`, `immutable-rollback-test.sh` PASS.
- [ ] OTA test updated.

### Phase 3 — Mode 1 live (~1 sprint)

- [ ] `packaging/live/flashforge_init.sh` mounts overlay over /data with tmpfs upper.
- [ ] Upper size cap (default 64 MB; configurable via `/screen_mode` siblings).
- [ ] `tests/qemu-harness/immutable-mode-1-live-test.sh` PASS — eMMC byte-identical after a full Mainsail upload + klippy run + reboot.
- [ ] Live USB README updated.

### Phase 4 — cleanup (after one release in the wild)

- [ ] Drop the fallback-to-old-layout path in `reforge-boot`. By this point all in-the-wild devices have migrated.
- [ ] Move overlay.ko to a path that's gitignored / per-release (currently planned at `/data/.mod/.reforge/modules/overlay.ko` symlink → `versions/<ver>/modules/overlay.ko`, but exact path can simplify after migration).

### Phase 5 (eventual, with Plan 5 / Mode 3)

- [ ] Flip `CONFIG_OVERLAY_FS=y` in the own-kernel config. Drop the insmod step in reforge-boot.
- [ ] `modules/overlay-bsp/` can stay around for live-mode-on-stock-kernel use, but isn't required for Mode 3.

---

## 10. Risks and how we mitigate

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Upper layer fills disk in live mode | Medium | User confusion; klippy may fail to write logs | 64 MB tmpfs cap; UI shows the limit; -ENOSPC visible in Mainsail |
| ext4 journal corruption mid-swap | Very low | Need RUNBOOK Path A | Pointer swap is one inode-pointer update; ext4's journal makes it transactional. Validated by `fsck.ext4` after a deliberate qemu power-loss test. |
| overlay.ko vermagic mismatch after stock FW update | Low | overlay won't load; system falls back to legacy chroot | reforge-boot checks vermagic before insmod; on mismatch, logs a clear error + falls back to direct chroot into mod/ (with a warning that updates are non-atomic until module rebuild) |
| Module load takes longer than expected at boot | Low | Slower boot | overlay.ko is 90 KB resident; load is sub-second on the device. Measured. |
| Symbol-namespace ABI changes in a hypothetical stock FW update | Medium for major FW updates; Low overall | Need to rebuild + re-patch | The MODULE_IMPORT_NS patch is one line; tracking is simple. The on-hw sanity check runs in <30s. |
| User runs forge-x AND ReForge somehow | Low (we now refuse to install) | Boot chain conflict | `pre_install_conflict_check` already refuses installs on forge-x-present devices |
| Cold-read amplification via overlay slows klippy startup measurably | Unknown | Klippy reach-ready slower | Measure in the qemu test rig; if >500ms regression, evaluate metacopy=on (carefully) or pre-warm |

---

## 11. Open questions to resolve in implementation, not now

- **`renameat2(RENAME_EXCHANGE)` on busybox**: busybox doesn't ship a `renameat2`-supporting `mv`. We'll need a tiny `reforge-pointer-swap` C helper (~50 lines) that calls the syscall directly. Same recipe as our other glibc helpers.
- **Where does `/var/log/` go in the overlay world?** Currently it's tmpfs anyway via inittab. Stays tmpfs. No change.
- **The chroot's view of `/`**: today the chroot's `/` is `/data/.mod/.reforge/`. With the overlay it becomes `/data/.mod/.reforge/merged/`. Anything inside the chroot that does `mount` calls needs to be checked (klippy and moonraker don't, but our `/mod/start.sh` chain does, and they'll see the merged paths).
- **moonraker's `[update_manager] type: web_static`** components (mainsail, etc.): these are simple zip-replace components. The version-dir layout fits naturally — the orchestrator stages the new zip into `versions/<new>/var/www/mainsail/`. Verify in phase 2.
- **Cold-read benchmark**: deferred from the spike (the dd parse was broken). Decide whether to measure under the immutable-install test or out of band.

---

## 12. Definition of done for v1

The plan is "done" when:

1. A fresh device installed via `make tgz` + USB stick ends up with `/data/.mod/.reforge/versions/<ver>/`, `current → versions/<ver>`, overlay merged, klippy + moonraker reach ready.
2. A subsequent OTA bumps `<ver>` → `<ver+1>` via the swap, klippy + moonraker restart cleanly, `current` points at `<ver+1>`, `<ver>` still on disk as the rollback target.
3. `reforge-revert <ver>` (or auto-trigger after N boot-fails) swaps back, klippy + moonraker restart on `<ver>`.
4. Live USB boot with the new launcher: 100 MB of Mainsail uploads land in tmpfs, removing the USB + rebooting leaves the eMMC byte-identical (sha256sum match).
5. All listed qemu tests pass; the on-hardware verification points (§8) have a recorded log.

---

## 13. References

- **Substrate spike**: `docs/research/kernel/2026-06-05-overlayfs-on-bsp-spike.md`
- **On-hw sanity check**: `modules/overlay-bsp/on-hw-sanity-check.log` (commit 1864397)
- **Overlay build recipe**: `modules/overlay-bsp/build.sh`, `modules/overlay-bsp/patches/0001-overlay-import-vfs-ns.patch`
- **Deployment-mode roadmap**: `docs/deployment-modes.md`
- **Current install path**: `packaging/flashforge_init.sh`, `packaging/README.md`
- **Current OTA path**: `docs/ota.md`, `docs/plans/2026-06-01-reforge-ota.md`
- **Partition map** (for the no-eMMC-write claim): `docs/board-notes/partition-map.md`
- **Mode-3 alignment** (for the `=y` flip): `docs/plans/2026-06-04-bsp-kernel-rebuild-and-diff.md`
- **BACKLOG entry being retired by this plan**: `docs/BACKLOG.md` §"immutable / atomic ReForge — OverlayFS2"

---

## 14. Decision request

I'm ready to start phase 1 (substrate + fresh-install path) on your sign-off. Phase 1 is self-contained: it ships the overlay.ko + the new fresh-install layout, with a fallback path that lets existing devices keep working unchanged. The upgrade/OTA/live paths come in phases 2 and 3, each independently mergeable.

Want me to start phase 1, or hold for a different design pass first?

## Update 2026-06-08

The `/reforge` bind-mount seam this plan's overlay merged-view attaches to landed in `reforge-boot` (2026-06-07): the rootfs is bind-mounted at `/reforge` and chrooted there (shared `.shell/reforge-chroot.sh`). The overlay step should mount the merged view at `/reforge` — the established seam — not a fresh `/data/.mod/.reforge/merged` chroot. `sbin/reforge-init` + the pid1-pivot harness referenced here remain staged (not wired). A `dinit` 0.22.0 package + `etc/dinit.d/` services were also added as the switch_root-PID1 building block.
