# Live mode — run ReForge from USB, zero eMMC writes

Live mode boots the **entire ReForge stack from a USB stick** without installing
anything. The eMMC is **never** written — pull the stick, reboot, and the printer
is back to pristine stock. It's how you trial ReForge on real AD5M / AD5M Pro
hardware with **no brick risk**.

| | Live mode | Install (`.tgz`) |
|---|---|---|
| Where it runs | USB stick (loop-mounted image) | eMMC (`/data/.reforge`) |
| eMMC writes | **none** | overlay + LKG bookkeeping |
| Persistence | none (USB only; `/data` is tmpfs) | survives reboot |
| Revert | pull USB + reboot | OTA rollback / recovery |
| Stock UI | does **not** run (ReForge owns the machine) | does not run |

## How it works

The stock `auto_run.sh` scans a FAT USB on every boot and runs any
`flashforge_init.sh` it finds at the USB root — **directly from `/mnt`, off the
stick** (no copy to eMMC):

```sh
if [ -f /mnt/flashforge_init.sh ]; then
    /mnt/flashforge_init.sh ${MACHINE} ${PID}
    if [ $? -eq 0 ]; then umount /mnt; sleep 100000; fi   # stock UI never launches
fi
```

ReForge's live launcher (`packaging/live/flashforge_init.sh`) uses that hook. It:

1. **insmods three kernel modules** shipped next to it on the stick — the stock
   5.4.61 kernel has **none** of them (verified on hardware): `loop.ko` (to
   loop-mount an image file), `crc32_generic.ko` (the `crc32` algo F2FS checks at
   mount — the kernel only has `crc32c`), and `f2fs.ko`. Each insmod is a no-op if
   the symbol is already present.
2. **loop-mounts `reforge-live.f2fs`** (the ReForge rootfs as an F2FS image — FAT
   can't host a Linux rootfs's symlinks/perms) as the chroot root.
3. binds `proc`/`sys`/`dev`/`run` + a **tmpfs `/data`** into the chroot — the
   install path binds the eMMC `/data` (mmcblk0p7); live mode uses tmpfs so **no
   eMMC partition is touched**.
4. `REFORGE_LIVE=1 chroot … /mod/start.sh`, then **blocks forever** — so stock
   never reaches `umount /mnt` and never launches its own UI. ReForge owns the box.

`REFORGE_LIVE=1` tells the boot/LKG scripts to skip the persistent trial/LKG
bookkeeping (that's for installs; live mode reboots clean by removing the USB).

## The three modules

Built by `modules/f2fs-bsp/build.sh` against the Tina BSP — exact vermagic
`5.4.61 SMP preempt mod_unload ARMv7 p2v8`, `depends=` empty (standalone), same
recipe as `modules/zram-bsp`. Committed prebuilt under `modules/f2fs-bsp/dist/`.

The `loop.ko` build also patches `loop.c` with
`MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver)` — it
calls `vfs_getattr`, which this Android-GKI kernel exports into that namespace; the
BSP source omits the import because loop was never built as a module here.

**Verified end-to-end on real hardware:** all three load and an F2FS image
loop-mounts read-write.

## Build & use

```sh
make rootfs                       # the ReForge image (build/output/images/rootfs.tar)
make live-usb                     # -> packaging/dist/reforge-live-<ver>.img
sudo dd if=packaging/dist/reforge-live-<ver>.img of=/dev/sdX bs=4M conv=fsync
```

Then: insert the stick, power on the printer — ReForge boots from USB. To return to
stock, **pull the stick and reboot**. The build is fully rootless (`mkfs.f2fs` +
`sload.f2fs` + `mcopy`); only the final `dd` to your stick needs root.

USB layout (FAT32):

```
/flashforge_init.sh    the live launcher
/loop.ko               loop block driver
/crc32_generic.ko      the 'crc32' algo F2FS needs at mount
/f2fs.ko               F2FS filesystem
/reforge-live.f2fs     the ReForge rootfs (loop-mounted chroot root)
```

## The brick-safe invariant

**Never write the eMMC.** No partition writes, no init edits, no `/data/.reforge`
install. Runtime state (klippy logs, moonraker DB, zram) lives in the loop-mounted
USB image (persistent) or tmpfs (ephemeral). Worst case — USB yanked mid-run — the
chroot's fs vanishes but the eMMC is intact; reboot recovers.

The qemu gate `tests/qemu-harness/live-mode-test.sh` (`make qemu-live`, rootless)
enforces it: it boots the launcher with an eMMC stand-in disk and **asserts the
eMMC bytes are identical before and after** and the stack came up. CI-gated.

## Caveats

- The USB must stay inserted — it *is* the rootfs; running from USB is slower than eMMC.
- The stock UI (`firmwareExe`) does not run — live mode runs ReForge's GuppyScreen /
  headless. That's the point.
- `/data` is tmpfs (ephemeral). Persistent live state across reboots is a future
  option (a writable dir on the FAT stick).

## See also

- `docs/specs/2026-06-02-reforge-live-mode.md` — the design spec (archival snapshot)
- `docs/architecture.md` — the overlay-on-stock chroot model live mode mirrors
- `tests/qemu-harness/README.md` — the qemu gates
