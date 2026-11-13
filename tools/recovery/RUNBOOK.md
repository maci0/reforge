# Recovery Runbook — FlashForge AD5M Pro (kunos)

This runbook covers recovery from every known failure mode for this printer.
Read it fully before performing any recovery action. The two paths are very
different in effort and risk.

---

## Hardware constraints — read first

This unit (hostname `kunos`, T113-S3 SoC) has **no usable FEL port and no UART
header as shipped** (both need solder mods; see
[brick-safe kernel test paths](../../docs/research/kernel/2026-06-04-brick-safe-kernel-test-paths.md)).
Without them there is no way to recover a bad bootloader, U-Boot environment or
kernel over USB or a serial cable. If the bootloader or kernel is corrupted, the only recovery path
is physically reading and writing the eMMC with an external reader (path B
below). This is why the golden image **must exist and be verified before any
kernel- or bootloader-touching flash is attempted**.

---

## Path A — Soft-brick: broken mod/userland, bootloader and kernel still intact

**Symptom:** The printer powers on, the boot sequence completes (or partially
completes), but the firmware is non-functional — e.g., a bad rootfs, a broken
mod layer, misconfigured userland, or a failed OTA update.

**Recovery:** Reflash a known-good stock firmware `.tgz` from a USB stick using
the normal FlashForge USB update path.

1. Download the stock firmware `.tgz` from FlashForge (ensure it matches the
   AD5M Pro hardware revision).
2. Copy the `.tgz` to the root of a FAT32-formatted USB stick.
3. Power off the printer.
4. Insert the USB stick.
5. Power on. The printer detects the firmware file and begins flashing
   automatically. Follow any on-screen prompts.
6. Wait for the flash cycle to complete and the printer to reboot.
7. Verify normal operation (touchscreen, connectivity, motion).

**Why this works:** The bootloader and kernel are still intact, so the device
boots far enough for `/opt/auto_run.sh` to find the `Adventurer5MPro-*.tgz` and run
its `flashforge_init.sh`. If boot never reaches `auto_run.sh`, use Path B.

---

## Path B — Hard-brick: bad bootloader, U-Boot environment or kernel

**Symptom:** The printer does not complete boot at all — black screen, immediate
power-off, or no network. Path A is not possible because the device cannot boot
far enough to run the update mechanism.

**When this can happen:** Plan 5 flashes the bootloader and/or kernel. Before
that, a bad `fw_setenv` value (`init=`, `bootargs`, `bootcmd`) already stops
userspace ([boot.md §2](../../docs/boot.md#2-intervention-points--earliest--latest)).
The shipped install and live modes write neither.

**Recovery:** Physically remove the eMMC (or attach an eMMC reader to the board),
connect it to a host machine, and write the golden image directly.

### Steps

1. Power off the printer and disconnect it from mains power.
2. Open the enclosure and locate the eMMC chip or eMMC reader pads.
3. Attach an eMMC reader/adapter and connect it to your host machine.
4. Identify the reader's block device on the host. **This is the most critical
   step — a mistake here will destroy your host system's disk.**

   ```sh
   lsblk -d -o NAME,SIZE,MODEL,TRAN
   ```

   Confirm the device node (e.g., `/dev/sdX` or `/dev/mmcblkN`) belongs to the
   eMMC reader and not to any internal disk or important drive.

5. Write the golden image. Use the **offline-cleaned** golden as the curated recovery
   baseline (preferred), or use the saved Forge-X recovery image to restore that
   saved system state. Neither is a proven byte-for-byte factory/capture image:

   ```sh
   # DANGER: confirm <reader-dev> is the eMMC reader, NOT your system disk,
   # before running. This command will irrecoverably overwrite the target device.

   # Offline-cleaned baseline (see provenance limitations below)
   gzip -dc tools/recovery/golden.img.gz | sudo dd of=/dev/<reader-dev> bs=4M conv=fsync status=progress

   # Alternative: saved Forge-X recovery image
   # gzip -dc tools/recovery/forge-x-20260531-152104.img.gz | sudo dd of=/dev/<reader-dev> bs=4M conv=fsync status=progress
   ```

   Replace `<reader-dev>` with the confirmed device node from step 4.

6. Wait for `dd` to finish (`conv=fsync` ensures data is committed to the eMMC
   before the command exits). This writes the full 7,818,182,656-byte image.
7. Safely eject/unmount the reader, reassemble the printer, and power on.
8. Verify the printer boots normally.

---

## The two curated images — which one to use

There are two curated full-eMMC images on disk. They are **both gitignored** (large
binaries) and live only on local disk / external backup.

**Naming (2026-06-01 rename, to avoid confusion):**
- `golden.img.gz` — the **offline-cleaned recovery** reference (forge-x removal recipe).
- `forge-x-<ts>.img.gz` — the device capture with forge-x installed; `dump_golden.sh` may repair filesystems before saving.
- A fresh `dump_golden.sh` capture is named `dump-<host>-<ts>.img.gz` (neutral); curate it
  into one of the above by content. "golden" identifies the curated recovery baseline, never an uncurated dump.

| Image | State | Use for |
|---|---|---|
| `tools/recovery/forge-x-20260531-152104.img.gz` (~886 MB gz) | Captured live, **forge-x installed** | Forge-x reference; dump script may apply filesystem repairs |
| `tools/recovery/golden.img.gz` (~877 MB gz) | Derived offline, **forge-x cleanup recipe applied** | **Preferred recovery baseline and qemu rootfs source** |

The `golden.img.gz` is an offline-cleaned recovery baseline, derived with
`tools/recovery/make-clean-golden.sh` (loop-mounted, no live printer access).
The removal recipe follows forge-x install/uninstall records, but factory origin
of the removed `S00init` and `/opt` scaffold remains unverified; see the
[rootfs provenance limits](../../docs/board-notes/stock-rootfs-provenance.md).
The [bring-up audit](../../docs/board-notes/stock-bringup-rebuild.md) also records
a different backup U-Boot in this image. It is not a proven byte-identical factory image.

**To regenerate the stock-clean golden** (if it is lost or the original golden is
refreshed):

```sh
# From the repo root (needs sudo for loop-mount):
sudo ./tools/recovery/make-clean-golden.sh
```

This decompresses the original golden into a scratch raw, mounts p6/p7,
removes all forge-x artifacts, verifies the cleaned state (15 checks PASS/FAIL),
recompresses → `tools/recovery/golden.img.gz`, extracts p6 →
`tests/qemu-harness/build/stock-clean-rootfs.ext4`, then deletes the
scratch raw. The original golden is **never touched**.

**Boot-verify result (2026-06-01):** The cleaned p6 was booted under the
qemu virt harness (`run-qemu.sh ... --timeout 75`). The stock `ffstartup-arm`
launched and started `firmwareExe` (stock Qt app, firmware 5.1.4). No forge-x
chroot, no Moonraker, no Klipper boot messages were observed — clean stock
userspace confirmed. The stock app could not fully initialize without T113 MCU /
display hardware (expected in qemu), but the boot sequence reached stock
userspace successfully.

---

## Where things live

| Item | Location | In git? |
|---|---|---|
| forge-x device reference (as-dumped) | `tools/recovery/forge-x-20260531-152104.img.gz` | **NO** |
| forge-x checksum | `tools/recovery/forge-x-20260531-152104.img.gz.sha256` | **NO** |
| forge-x size sidecar | `tools/recovery/forge-x-20260531-152104.size` | **NO** |
| forge-x partition map (`/proc/partitions`) | `tools/recovery/forge-x-20260531-152104.partitions.txt` | YES |
| **Stock golden (preferred)** | `tools/recovery/golden.img.gz` | **NO** |
| Golden checksum + size | `tools/recovery/golden.img.gz.sha256` · `golden.size` | **NO** |
| Clean-golden derivation script | `tools/recovery/make-clean-golden.sh` | YES |
| Cleaned p6 rootfs for qemu | `tests/qemu-harness/build/stock-clean-rootfs.ext4` | **NO** |
| Dump script | `tools/recovery/dump_golden.sh` | YES |
| Verify script | `tools/recovery/verify_dump.sh` | YES |
| This runbook | `tools/recovery/RUNBOOK.md` | YES |

**All `.img.gz` and `.ext4` files are gitignored and are NOT committed.**
They live only on local disk (and wherever you back them up). A future operator
cloning this repo will NOT have the golden images — they must either:
- Obtain them from an external backup (e.g., an external drive, NAS, or cloud
  storage where you archived them), or
- Re-derive the stock-clean golden from the original golden using
  `make-clean-golden.sh` (if the original golden is available), or
- Make a fresh dump from a known-good device using the procedure below.

**Back up both golden images to at least one external location before doing any
work that could brick the device.**

---

## Making a fresh golden dump

If you need to capture a new golden image (e.g., after verifying a clean state
on a new device, or to refresh the baseline):

```sh
# From the repo root. PRINTER is user@host, for example root@192.168.1.10
./tools/recovery/dump_golden.sh "$PRINTER"
```

This reads `/dev/mmcblk0` over SSH into a local raw image. Before compression,
`dump_golden.sh` runs `e2fsck -fy` on ext partition slices and splices successful
repairs back into that image. The saved dump may therefore differ from the bytes
captured from the device; it is not a forensic byte-for-byte capture. It then
compresses the repaired image and names it from the host and time, not "golden":

- `tools/recovery/dump-<host>-<timestamp>.img.gz`
- `tools/recovery/dump-<host>-<timestamp>.size`
- `tools/recovery/dump-<host>-<timestamp>.img.gz.sha256`

`<host>` is the part of `$PRINTER` after `@`. A raw dump stays a dump until it
is curated. The offline-cleaned recovery baseline produced by
`make-clean-golden.sh` is `golden.img.gz`. A forge-x device dump kept as the forge-x reference is
`forge-x-<timestamp>.img.gz`. See `recovery-sources.md`.

Verify the file the script just wrote. `DUMP` is that `.img.gz` path:

```sh
./tools/recovery/verify_dump.sh "$DUMP"
```

Expected output ends with:
```
expected=7818182656 actual=7818182656
sha256:
dump-...: OK
OK: dump is full-size and checksum-valid
```

Do not proceed with any kernel/bootloader-modifying work until this verification
passes. This is the GATE-ZERO safety requirement for the ReForge project.
