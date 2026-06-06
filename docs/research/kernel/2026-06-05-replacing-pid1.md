# Replacing PID 1 on the AD5M — research note

**Date:** 2026-06-05
**Status:** research, no implementation yet
**Audience:** anyone evaluating boot-handoff mechanisms for ReForge Mode 2 → Mode 3 transitions
**See also:**
  - [`../boot.md`](../../boot.md) \u00a72 \u2014 the intervention-points table (this note expands on
    rows #4 (boot.img), #5 (init=), and the implied "swap /init symlink" intervention)
  - [`2026-06-04-brick-safe-kernel-test-paths.md`](2026-06-04-brick-safe-kernel-test-paths.md)
    \u2014 the kexec / FEL analysis (the Tier-0/1 cousin of the PID-1 question)
  - [`../deployment-modes.md`](../../deployment-modes.md) \u2014 the three-mode roadmap (Mode 3
    is where PID-1 replacement becomes trivial)
  - [`../board-notes/partition-map.md`](../../board-notes/partition-map.md) \u2014 the brick
    tiers that constrain how aggressively we can intervene

---

## 1. What PID 1 is, and why this question is asymmetric

The Linux kernel sets PID 1 **exactly once per boot** \u2014 when the kernel finishes
its own init, it `execve`s the binary indicated by:

1. `init=<path>` on the kernel cmdline if present
2. else `/sbin/init`, `/etc/init`, `/bin/init`, `/bin/sh` (in order, first one found)
3. on the rootfs the kernel just mounted from `root=<dev>`

Whoever the kernel `execve`s **becomes PID 1**. The kernel records that PID
and special-cases it forever: PID 1 is the parent of every orphaned process,
it receives `SIGCHLD` for every reparented child, and **if PID 1 ever dies the
kernel panics**.

This asymmetry is the whole reason the question is hard:

- **Becoming PID 1 yourself** is easy if you can influence what the kernel
  exec's at boot. Replace `/init` (or set `init=`) and you are PID 1.
- **Replacing an already-running PID 1** with a different process is
  fundamentally **not** a clean operation in Linux. There is no "exec into
  this binary" syscall for PID 1 from another process. PID 1 can `execve`
  itself into something else, but no other process can force that
  transition.

So the practical answer to "how do we replace PID 1" splits into two
families: **become PID 1 at boot** (clean, well-supported) vs **swap out a
running PID 1** (hacks, all with serious caveats).

---

## 2. Family A \u2014 become PID 1 at boot (the clean family)

These all rely on the kernel's normal boot-time PID-1 selection mechanism.
They work cleanly because we are the first process the kernel ever exec'd as
PID 1 \u2014 we have full PID-1 lifecycle semantics, no contention, no PID-1
"already running" to fight with.

### A1. Replace `/init` on the rootfs (Option A in boot.md \u00a72)

`/init` on the stock rootfs is a symlink to `/bin/busybox`. We can:

- Replace the file (`ln -sf /sbin/reforge-init /init`)
- Or write a regular file at `/init` (a script or static binary)

Then the kernel runs *our* code as PID 1 and we do what we want, including
`pivot_root` into a different rootfs and `exec /sbin/init` of the new root \u2014
which preserves PID 1 status through the `exec`.

| | |
|---|---|
| Earliness | PID 1 \u2014 earliest userspace possible without kernel/boot.img changes |
| Reversibility | One-line file edit on p6: `ln -sf /bin/busybox /init` |
| Effort | Low (one symlink + a script) |
| Risk | Medium \u2014 broken /init script means broken userspace. But if our script falls back to `exec /bin/busybox init` on any error, the box still boots stock as a degraded recovery path. |
| Brick tier (per docs/boot.md \u00a72 / partition-map.md) | **SAFE** (rootfs file edit) |
| Implementation | `br-external/board/reforge/rootfs-overlay/sbin/reforge-init` (this repo, written 2026-06-05, staged but not wired in) |

This is what `sbin/reforge-init` in this repo implements. See the script
header for the `pivot_root` flow and the fallback semantics.

### A2. `init=` on the kernel cmdline (Option B in boot.md \u00a72 \u2014 the env-edit variant)

Set `init=/sbin/reforge-init` (or `init=/opt/reforge-init`) in the kernel
cmdline. Identical end result to A1 \u2014 the kernel exec's our binary as PID 1
\u2014 but the *change* lives in U-Boot env (mmcblk0p2 + p3) rather than the
rootfs.

| | |
|---|---|
| Earliness | PID 1 (same as A1) |
| Reversibility | `fw_setenv init ''` to clear the override |
| Effort | Low (one `fw_setenv` call) |
| Risk | **HIGH on this unit.** U-Boot env corruption (e.g. partial write on power loss) puts us in the boot.md \u00a72 row #3 "hard-brick tier" with no FEL and no UART to recover from. |
| Brick tier | **HARD-BRICK risk** |

A1 strictly dominates A2 on our hardware. The only reason to use A2 is if
the rootfs is itself read-only and we can't edit `/init` \u2014 not our case.

### A3. Boot image replacement (Mode 3, the proper way)

Ship our own `boot.img` on `mmcblk0p4` containing **our** kernel + **our**
initramfs + **our** cmdline. The kernel's `init=` cmdline points at our
init; the initramfs IS rootfs (`rootfs` type), so `switch_root` works
cleanly (no `pivot_root` workaround needed).

| | |
|---|---|
| Earliness | PID 1 from the moment userspace exists |
| Reversibility | Reflash stock boot.img via RUNBOOK Path A (USB `.tgz`) \u2014 needs userspace to still be reaching `auto_run.sh` |
| Effort | High \u2014 building a kernel + initramfs is Plan 5 (Mode 3) territory |
| Risk | Medium \u2014 a bad `boot.img` is brick-tier MEDIUM per `docs/boot.md` \u00a72 row #4. Recoverable via USB `.tgz` if userspace stays reachable, else eMMC reader (Path B). |
| Brick tier | **MEDIUM** for the reflash itself; PID-1 semantics are bulletproof afterward |

This is the long-term direction. Until then A1 gives us 95% of the value
on the stock kernel.

---

## 3. Family B \u2014 replace an already-running PID 1 (the hack family)

These all try to swap PID 1 *after* the box has booted and busybox-init is
already PID 1. They range from "expensive but clean" (kexec) to
"theoretical and brittle" (ptrace into PID 1).

### B1. `kexec` \u2014 soft-reboot into a new kernel

`kexec` lets a running kernel load and jump into a different kernel binary
in place, without the firmware reset cycle. The new kernel boots from
scratch \u2014 fresh PID 1, fresh rootfs mount, fresh everything. **It's the
clean answer to "replace PID 1 at runtime" but it requires `CONFIG_KEXEC=y`
in the running kernel.**

The stock 5.4.61 kernel **does NOT have `CONFIG_KEXEC=y`** (verified against
`docs/board-notes/stock-kernel-config-5.4.61.txt.gz`:
`# CONFIG_KEXEC is not set`). So we can't kexec on stock without first
rebuilding the kernel with the option enabled and reflashing `mmcblk0p4`
once.

Full analysis: [`2026-06-04-brick-safe-kernel-test-paths.md`](2026-06-04-brick-safe-kernel-test-paths.md)
\u00a72.3 ("the hybrid plan: one-time `boot.img` reflash, then iterate freely
via kexec"). The Kconfig is reachable in the BSP, every dependency is
already satisfied, and `kexec-tools` is a Buildroot package (~200 KB).

| | |
|---|---|
| Earliness | At the point of kexec, the next "boot" starts with our kernel + our init (which is our PID 1) |
| Reversibility | The kexec'd kernel doesn't change anything on disk; a `reboot -f` returns to the original boot chain |
| Effort | **One-time medium-risk `boot.img` reflash** to enable `CONFIG_KEXEC=y`, then trivial per-test thereafter |
| Risk | Medium for the one-time reflash; zero per-test thereafter |
| Brick tier | Same as Mode 3 boot.img \u2014 MEDIUM for the reflash, SAFE afterward |
| When useful | Iterative kernel-test development, sandboxed "boot ReForge from a fresh kernel" flows that don't want full power cycles, A/B comparison runs |

This is the "real" answer for replacing PID 1 at runtime on this hardware,
and it's also the gateway for cleaner iterative kernel work in Plan 5. The
one-time `boot.img` reflash is the gating step.

### B2. PID namespaces (`CLONE_NEWPID`)

We can `unshare(CLONE_NEWPID)` (or `clone(CLONE_NEWPID)`) to create a new
PID namespace. The first process inside the new namespace **is PID 1
inside that namespace**, with all the usual PID-1 properties (signal
handling, child reaping) \u2014 **but only for processes in the same namespace**.
From the host's perspective our "PID 1" is just PID N.

This is the same trick Docker / LXC / systemd-nspawn use to give a
container its own init. For ReForge it's interesting in narrow cases:

- We could chroot into `/data/.mod/.reforge`, `unshare(CLONE_NEWPID)`,
  then run our service chain. Inside the namespace, our init is PID 1 and
  reaps children correctly. Outside, busybox-init is still PID 1 doing its
  thing.
- Useful for "run klippy + moonraker in a PID-1-isolated context so they
  don't pollute the host's process tree" \u2014 but for our use case the chroot
  alone already gives us most of that benefit.

| | |
|---|---|
| Earliness | Whenever we want \u2014 launched as a regular process |
| Reversibility | Kill the namespace's PID 1, namespace evaporates |
| Effort | Low (`unshare(CLONE_NEWPID)` from a shell helper) |
| Risk | Low |
| Brick tier | SAFE (userspace-only) |
| When useful | Process-tree isolation, signal handling correctness; **not** for "skip Tina entirely" |

Not a replacement for global PID 1. Listed for completeness.

### B3. Killing PID 1 (DON'T)

`kill -9 1` from a privileged process panics the kernel ("Kernel panic - not
syncing: Attempted to kill init!"). Same outcome whether the kill is
synchronous or via an exit of PID 1 itself.

The corollary: if PID 1 is alive and not us, **we cannot become PID 1**
without rebooting (via the kernel boot path, kexec, or a real reset).

### B4. `ptrace` PID 1 into doing `execve`

In theory, a `CAP_SYS_PTRACE`-capable process can `PTRACE_ATTACH` to PID 1,
poke the registers and stack to set up an `execve` syscall, then detach.
PID 1 would then `execve` into whatever we point it to.

In practice:

- Kernel hardening (`CONFIG_SECURITY_YAMA=y` plus `kernel.yama.ptrace_scope`)
  often forbids ptracing PID 1.
- Even when allowed, the technique is wildly brittle: the PID-1 process has
  signal handlers, file descriptors, and reaping state we'd need to
  preserve through the `execve`.
- A failed setup typically leaves PID 1 wedged, which (when its main loop
  fails to make progress) causes the system to hang.

Listed only so it's not mistaken for a real option. **Do not do this.**

### B5. systemd-style re-exec (N/A)

systemd implements `systemctl daemon-reexec` which has PID 1 (systemd
itself) `execve` into a new copy of itself. It works because PID 1
*chooses* to re-exec; nothing external forced it.

busybox-init has no such feature. Not applicable to us unless we switch to
systemd (we don't and won't on a 128 MB box).

---

## 4. Decision matrix for ReForge

| Goal | Best mechanism | Family | Notes |
|---|---|---|---|
| **Mode 2 transitional: skip Tina without rebuilding the kernel** | **A1 `/init` symlink swap** | A | What `sbin/reforge-init` implements. Staged, not yet wired into the installer. |
| Mode 2 stock-kernel kexec-into-new-rootfs experiments | B1 `kexec` (after one-time boot.img reflash to enable `CONFIG_KEXEC`) | B | Per [`2026-06-04-brick-safe-kernel-test-paths.md`](2026-06-04-brick-safe-kernel-test-paths.md) \u00a72.3. Worth doing once to unlock iterative kernel-test flows. |
| Mode 3: ship our own kernel + initramfs + init | A3 boot.img replacement | A | The long-term destination; PID 1 is trivially ours. |
| Run isolated processes with their own PID 1 lifecycle (signal handling etc.) without affecting global init | B2 PID namespace | B | Container-style isolation; not a global PID-1 replacement. |
| Add hooks to Tina's init flow without skipping it | preinit, S?? script, or auto_run.sh hook (`docs/boot.md` \u00a72 rows #6\u20138) | n/a | Not PID-1 replacement; just additive userspace hooks. |

For our roadmap, the sequence is:

1. **Now**: keep using the chroot-based Mode 2 install flow (busybox-init
   stays PID 1; we run from `/etc/init.d/S01reforge` -> `.shell/reforge-boot`
   -> chroot into `/data/.mod/.reforge/`). Works, ships, doesn't replace
   PID 1.

2. **Soon (after testing)**: ship A1 (`/init` swap) as the Mode 2 default.
   Skips Tina entirely, gives us real PID 1 inside our overlay, preserves
   stock at `/oldroot` for fallback and for the MCU-firmware binaries we
   sometimes need to reach.

3. **Plan 5**: ship Mode 3 with A3 (our own boot.img). Tina is gone from
   our rootfs; PID 1 is bulletproof; the kexec gate (B1) becomes irrelevant
   because we don't need to leave a running kernel to test a different one
   \u2014 we just reflash p4 in development.

4. **Optional, in parallel with #2 or #3**: enable `CONFIG_KEXEC` in our
   own kernel build so we can use kexec for iterative kernel-test loops in
   development. Cheap once we have our own kernel.

---

## 5. Open questions / things to verify before going to A1

- **`/oldroot` after the pivot** \u2014 should we keep it permanently mounted
  (read-only? read-write?), or lazy-`umount` it after our init is done with
  it? Read-only keeps the disk warm in page cache but blocks future writes;
  unmount frees pages but means MCU-firmware updates (path #3 in
  `docs/board-notes/fw-upgrade-mechanisms.md`) need to remount it.

- **The MCU firmware update path** when we're not the stock init \u2014 today
  `/opt/auto_run.sh` checks `/opt/PROGRAM/control/<latest>/Update` and runs
  `/opt/PROGRAM/control/<latest>/run.sh` if present. With A1, our init has
  to pick up this responsibility (e.g. as one of `/mod/init.d/S??` ahead of
  klippy startup), reading from `/oldroot/opt/PROGRAM/control/<ver>/`.

- **The USB `.tgz` recovery hook** \u2014 same question. We need to scan
  `/dev/sda*` for `Adventurer5MPro-*.tgz` and `flashforge_init.sh` ourselves
  in our own equivalent of `auto_run.sh`. The `/oldroot/lib/modules/8821cu.ko`
  WiFi driver, the `mount -t vfat`, the tarball-extract path \u2014 all
  reimplemented in our init.

- **busybox-init's signal handling** \u2014 our `exec /sbin/init` after pivot
  hands off to busybox-init in the new root. We need to verify it correctly
  reaps children, handles `SIGCHLD`, and processes `::ctrlaltdel:` and
  `::shutdown:` inittab entries. Probably fine (BR's busybox is well-tested)
  but worth a qemu smoke-test before committing to the path.

- **Recovery posture when `reforge-init` itself crashes** \u2014 the script falls
  back to `exec /bin/busybox init` on any error. We should verify the
  fallback path actually boots stock cleanly (e.g. via a deliberate
  corruption test in the qemu harness).

- **What about live mode?** \u2014 live mode (Mode 1) doesn't touch eMMC and
  runs from USB, so the `/init` swap doesn't apply there. Live continues
  to use `auto_run.sh` -> `flashforge_init.sh` (the bare-script path #2 in
  the FW-upgrade-mechanisms doc) for the foreseeable future. The two
  hooks are independent.
