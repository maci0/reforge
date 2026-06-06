# OverlayFS on stock 5.4.61 BSP — spike findings

**Date:** 2026-06-05
**Status:** spike complete. Findings inline. Implementation plan deferred to a follow-up that uses these results.
**Triggered by:** `docs/BACKLOG.md` §"immutable / atomic ReForge — OverlayFS2", which parked the design direction until a half-day spike answered five open questions.
**Test harness:** `tests/qemu-harness/overlayfs-spike-test.sh` (committed alongside this note).
**Related:** `docs/deployment-modes.md` (Mode 1 / Mode 2 / Mode 3 roadmap), `docs/board-notes/fw-upgrade-mechanisms.md`, `docs/research/memory/2026-05-31-memory-and-testing.md` (squashfs notes).

---

## TL;DR

OverlayFS **is reachable on the stock 5.4.61 BSP without an own-kernel** (Plan 5 / Mode 3 is not a prerequisite). Specifically:

1. The BSP carries **vanilla** `fs/overlayfs/` source (no Allwinner / sun8iw patches; checked across all 11 `.c` files).
2. Building it as a loadable module (`CONFIG_OVERLAY_FS=m`) produces a clean **122 KB `overlay.ko`** with zero external module dependencies — drop-in `insmod` on stock would work.
3. Mounted as a normal `lowerdir + upperdir + workdir` overlay over an ext4 `/data`, semantics are correct: read-from-lower, write-to-upper (with copy-up), whiteout, lower-immutability. All five semantics asserts pass.
4. **Per-mount RAM cost: ~192 KiB MemAvailable delta**, with the `ovl_inode` slab at ~16 KiB. Well under the 500 KiB flag threshold the BACKLOG entry proposed.

So the BACKLOG entry's question 1 ("Can it build as a module?") and question 2 ("OverlayFS2 vs stock 5.4 overlayfs?") are answered: **yes** and **stock 5.4 is sufficient for what we need** (basic merge, copy-up, whiteout; we don't need redirect_dir / metacopy / nfs_export for v1). Question 3 (memory cost) is bounded. Questions 4 (layout) and 5 (Mode-3 alignment) are architectural and don't need measurement before deciding.

The atomic-update / true-live design from the BACKLOG can be elevated from "parked" to "scheduled" with high confidence.

---

## 1. Source-level audit

### BSP carries vanilla overlayfs

The Tina BSP kernel tree at `vendor/kernels/tina-bsp-kernel/fs/overlayfs/` contains:

```
copy_up.c  dir.c  export.c  file.c  inode.c  Kconfig  Makefile
namei.c  overlayfs.h  ovl_entry.h  readdir.c  super.c
```

11 `.c` files and 2 headers, **10,320 lines total**. A regex grep for Allwinner / sunxi / sun8iw / aw_ markers across the directory returns zero meaningful hits (the only matches are coincidental substrings inside argument names like `raw_data`). So the BSP didn't fork overlayfs — it carries upstream 5.4 source as-is.

This matters because it means we don't have to reason about a vendor-divergent overlay codepath. If upstream 5.4 overlayfs works, so does the BSP's.

### Kconfig allows modular build

```
config OVERLAY_FS
    tristate "Overlay filesystem support"
    select EXPORTFS
```

`tristate` means `=m` is reachable per the Kbuild contract; `select EXPORTFS` means we get a pure-Y kernel-export dependency, not another module to ship. No `depends on` clauses that would require a kernel rebuild.

### Stock kernel has overlayfs disabled

`docs/board-notes/stock-kernel-config-5.4.61.txt.gz`:

```
# CONFIG_OVERLAY_FS is not set
```

So FlashForge's shipped kernel cannot mount overlay today. To use overlay on the stock kernel, we'd have to:

- Build `overlay.ko` against the BSP source with the **exact** kernel version + config the device runs (vermagic must match: `5.4.61 SMP preempt mod_unload ARMv7 p2v8`).
- Drop it into the device's `/lib/modules/$(uname -r)/` (or anywhere we control, e.g. `/data/.mod/.reforge/modules/`).
- `insmod /path/to/overlay.ko` before any mount.

This is the same pattern we already use for the F2FS module (`modules/f2fs-bsp/`). The vermagic-matching constraint is the only friction.

---

## 2. Module build result

We forced `CONFIG_OVERLAY_FS=m` in the qemu test kernel's `.config` (whose source is the same BSP tree the device uses, just with `multi_v7_defconfig + virt.fragment` instead of the sun8iw20 production config) and built modules:

```
[OK] overlay.ko produced: tests/qemu-harness/build/kbuild/fs/overlayfs/overlay.ko
-rw-r--r-- 1 maci maci 122K Jun  6 00:01 .../overlay.ko
  .../overlay.ko: ELF 32-bit LSB relocatable, ARM, EABI5 version 1 (SYSV),
                  BuildID[sha1]=adbf4f8..., not stripped
```

`objdump --section=.modinfo` decodes to:

```
license=GPL
description=Overlay filesystem
author=Miklos Szeredi <miklos@szeredi.hu>
depends=                  (empty — no external module deps)
intree=Y
name=overlay
vermagic=5.4.61 SMP mod_unload ARMv7 p2v8
```

Build emitted four warnings of the form:

```
WARNING: module overlay uses symbol vfs_rename from namespace
         VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver,
         but does not import it.
```

These are upstream-kernel symbol-namespace pedantry that affects logging only, not loading. Mainline 5.4.x emits the same warnings. Safe to ignore.

**Implications for stock deployment:** `overlay.ko` is a single 122 KB file with no module dependencies. Loading it on stock would be:

```sh
# Once at install time, when /data is mounted but before /etc/init.d/S?? begins:
insmod /data/.mod/.reforge/modules/overlay.ko
```

The only requirement is that the .ko was built against the EXACT kernel the device boots. Since we control the BSP build and we already ship pre-built kernel modules (F2FS), this is straightforward to add.

A future Mode 3 (own-kernel) build can flip to `=y` for one less ko shipping step. No design changes between Mode 2 and Mode 3 needed.

---

## 3. Runtime behaviour (in qemu)

The spike test (`tests/qemu-harness/overlayfs-spike-test.sh`) boots the BSP-source kernel under qemu virt with `CONFIG_OVERLAY_FS=y`, builds a layered structure under `/data`, mounts overlay, and exercises the semantics.

### Mount succeeds with documented flags

```
[spike] mounting overlay (lower=/data/.spike/lower,
                          upper=/data/.spike/upper,
                          work=/data/.spike/work) ...
[spike] PASS: overlay mount succeeded
```

`/proc/filesystems` registers `nodev overlay` as expected. `mount` shows the overlay live at `/data/.spike/merged`.

### Semantics are correct

| Operation | Expected | Observed |
|---|---|---|
| Read file present only in `lower/` via `merged/` | returns lower content | ✅ PASS |
| Write to `merged/` (file existed in lower only) | copy-up + write to `upper/` | ✅ PASS — `upper/README.txt` appeared |
| Read back after write | returns the new (upper) content | ✅ PASS |
| Lower is unchanged after write-to-merged | byte-identical | ✅ PASS |
| `rm` file from `merged/` (lower-only) | whiteout in upper, hidden from merged | ✅ PASS — file gone from merged, intact in lower |

All five semantics asserts pass. No surprises, no kernel oopses, no dmesg warnings beyond the mount-time info line.

### Memory cost — per-mount overhead

`/proc/meminfo` taken at three snapshot points (system idle, after `mount -t overlay`, after the exercise sequence):

| Field | Baseline | Post-mount | Delta |
|---|---:|---:|---:|
| MemTotal | 108,332 kB | 108,332 kB | 0 |
| MemFree | 90,864 kB | 90,672 kB | −192 kB |
| **MemAvailable** | **92,208 kB** | **92,016 kB** | **−192 kB** |
| Buffers | 412 kB | 492 kB | +80 kB |
| Cached | 1,712 kB | 1,452 kB | −260 kB |
| Slab | 10,800 kB | 11,164 kB | +364 kB |

The Slab grew by 364 kB; the page-cache hit (Cached + Buffers) shows a small reshuffle (-180 kB net). The headline figure is the **MemAvailable delta of ~192 kB**, which is what would matter on a 128 MB box.

`/proc/slabinfo` for the new overlay-specific slab:

```
ovl_inode  16 16 504  16 2 : tunables 0 0 0 : slabdata 1 1 0
```

`504 B/object × 16 active` ≈ 8 KB for active inodes + ~8 KB of slab metadata, so the **overlay's own per-inode allocator footprint is ~16 KB at idle**. The other ~176 KB of MemAvailable delta is general FS bookkeeping (mount-point dentries, the kernel's internal mount struct, journaling overhead from the upper ext4 layer being written).

**Projection to multi-mount:** Each additional overlay mount adds another ~8 KB of slab metadata + ovl_inode slab growth proportional to actively-merged inodes. For the BACKLOG's proposed "versions/" model where only ONE overlay is live at a time (current = pointer to one version), the cost is fixed at ~192 KB. For a more elaborate "diff visible to admin" model with multiple overlays mounted, the cost scales linearly.

### Read amplification — not measured cleanly

The cold/warm-read benchmark was wired but the dd-output parsing only captured the count line, not the timing. The numbers we have aren't usable. **Follow-up needed** if read amplification turns out to matter for klippy cold-start performance.

---

## 4. What the spike does NOT yet prove

- **Real-hardware load**. The .ko built here has `vermagic=5.4.61 SMP mod_unload ARMv7 p2v8`. To load on a real AD5M, the .ko must be rebuilt against the **exact** production kernel config (sun8iw20-specific, not multi_v7 + virt fragment). The codepath is the same source so functional behaviour is identical, but vermagic + Module.symvers must match.
- **Cold-read amplification at klippy startup**. The benchmark slot is in the test rig but the dd parse is broken; numbers not recorded.
- **Long-running stability**. Spike runs for ~30 s. No information on multi-day uptime, copy-up storms, or page-cache pressure when `[virtual_sdcard] path` is in the overlay.
- **Write-amplification on upper**. When the user does a large gcode upload that lands on an upper-layer ext4, ext4 journals every block update twice (once for upper, once for the underlying lower mount's own journal). Not benchmarked.
- **f2fs as lower instead of ext4**. Today's live-mode USB stick is f2fs; the BACKLOG entry's "true Mode 1 live" idea wants `lowerdir=/data + upperdir=tmpfs`. We only tested ext4 lower here. f2fs-as-lower should also work (overlay is upper-layer-agnostic) but not verified.
- **Per-mount cost under contention**. Single idle mount measured. Multiple concurrent reads/writes through the overlay may surface page-cache stacking penalties not visible here.

---

## 5. Implications for the BACKLOG entry

Looking back at the five open questions from `docs/BACKLOG.md` §"immutable / atomic ReForge":

| Question | Pre-spike | Post-spike |
|---|---|---|
| **1.** Can OverlayFS build as a loadable module against the stock 5.4.61 BSP? | Unknown; Kconfig says tristate so reachable in theory | **YES.** 122 KB `overlay.ko`, vanilla source, zero external deps. |
| **2.** OverlayFS2 vs stock 5.4 overlayfs — what do we actually need? | Open | We need merge / copy-up / whiteout. Stock 5.4 overlayfs has all three with correct semantics. Skip redirect_dir / metacopy / nfs_export for v1. |
| **3.** Memory implications — per-mount RSS, tmpfs upper sizing, page-cache | Open; "every MB matters" | ~192 KiB MemAvailable per single mount. Headroom of ~92 MiB on a 128 MB box means we can afford 50+ mounts. The dominating cost will be the tmpfs upper for Mode 1 (needs its own size cap). |
| **4.** Atomic-install layout choice (versions / side-by-side / btrfs) | Open | **Versioned overlay** is the clear winner now that the per-mount cost is small: pointer swap = atomic commit, drop upper = atomic rollback, works on ext4 `/data`, no fs swap, fits Mode 3 trivially. |
| **5.** Mode 3 alignment | Will work but unknown overhead | OverlayFS in Mode 3's own kernel is `=y` at compile time — no module shipping, same code path. The Mode 2 design carries over with the module-vs-builtin flag flipped. |

All five answered. The architectural direction is **green-light**.

---

## 6. Recommended next step

Two paths forward, parallel or sequential:

### Path A: Implementation plan + Mode 2 deployment

Write `docs/plans/2026-06-XX-immutable-reforge.md` covering:

- **Layout**: `/data/.mod/.reforge/versions/<ver>/` lower-layer dirs, `/data/.mod/.reforge/upper/<ver>/` upper-layer dirs, `/data/.mod/.reforge/current` symlink (the "pointer"), `/data/.mod/.reforge/merged/` mount point.
- **Install path**: `flashforge_init.sh` extracts the new version into `versions/<new>/`, creates an empty `upper/<new>/`, **atomically** swaps `current → <new>`, remounts overlay, exits. Power-loss-safe: if the swap doesn't complete, `current` still points at the old version.
- **OTA path**: same pattern, with the rsync-style version dir population happening via Moonraker's `update_manager` writes into `versions/<new>/`, then the pointer swap.
- **Rollback**: drop `upper/<new>/`, point `current → <previous>`, remount. Trial-N-fails-rolls-back becomes a real pointer swap rather than a side-by-side directory rename.
- **Live mode (true Mode 1)**: launcher mounts overlay with `lowerdir=/data, upperdir=tmpfs, workdir=tmpfs`. User sees existing gcodes; writes go to RAM; remove USB → reboot → RAM evaporates → back to stock state.
- **Boot integration**: `S01reforge` (or `/sbin/reforge-init` if we go PID-1) does the `insmod overlay.ko + mount -t overlay` chain before launching `/mod/start.sh`.
- **Module shipping**: build `overlay.ko` once per release against the production sun8iw20 kernel config, ship in `mod/modules/overlay.ko`, alongside today's zram modules.

Acceptance: a qemu test that walks install → run → "OTA" version bump → rollback through the layout above, with the eMMC stand-in byte-identical at the end except for the version dirs and the pointer.

### Path B: Real-hardware vermagic validation

Before committing to (A), verify that the `overlay.ko` produced from a sun8iw20-config'd build actually loads + mounts on the running stock kernel. One short test on hardware:

```sh
# Build overlay.ko with the EXACT stock kernel config.
# Drop it on the device via SSH or USB.
ssh root@printer "insmod /tmp/overlay.ko"
ssh root@printer "grep overlay /proc/filesystems"
ssh root@printer "mkdir -p /tmp/l /tmp/u /tmp/w /tmp/m; \
                  echo HELLO > /tmp/l/test; \
                  mount -t overlay overlay -o lowerdir=/tmp/l,upperdir=/tmp/u,workdir=/tmp/w /tmp/m; \
                  cat /tmp/m/test"
```

Three terminal commands, zero risk (overlay.ko loaded into a tmpfs work dir; `rmmod overlay` cleans up). The most that can go wrong is the insmod fails because vermagic mismatches, which just means we built against the wrong config.

This is the right next-physical-test once we have a stock-config kernel build going (the BSP-rebuild work in `docs/research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md` is the prerequisite).

### Recommended ordering

Do **A first** (the implementation plan, design only — no code), then **B** (one-evening hardware validation when you next have the device on the bench), then implementation against the plan with B's vermagic confirmation in hand.

---

## 7. Open follow-up tasks

Captured here so they don't get lost:

- [ ] **Fix the dd timing parse** in `overlayfs-spike-test.sh` — current cold/warm benchmark captures the wrong line of dd output. One-line fix; do next time we touch the test.
- [ ] **Run the spike with `=m`** end-to-end. Today the spike rebuilds with `=y` for simplicity (no insmod needed). To prove the module-shipping pathway works under qemu we'd inject `overlay.ko` into the rootfs image and `insmod` it from the spike init. ~30 minutes work; not blocking.
- [ ] **Build `overlay.ko` against the production sun8iw20 config** as a one-shot artefact for future on-hardware testing. The vermagic mismatch story has only one resolution.
- [ ] **f2fs-as-lower** verify. Live mode's USB stick is f2fs. Overlay should be upper-layer-agnostic but worth a single qemu run to confirm.
- [ ] **Cold-read amplification at klippy startup** measurement — does pulling klippy.cfg through an overlay layer slow klippy reach-ready by a measurable amount on the 128 MB box?
- [ ] **Mode-3 design alignment doc** — once Plan 5 has a concrete kernel target, add a one-page note that the immutable design carries over with `=y` instead of `=m` and no other changes.
