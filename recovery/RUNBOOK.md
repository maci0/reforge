# Recovery Runbook — FlashForge AD5M Pro (kunos)

This runbook covers recovery from every known failure mode for this printer.
Read it fully before performing any recovery action. The two paths are very
different in effort and risk.

---

## Hardware constraints — read first

This unit (hostname `kunos`, T113-S3 SoC) has **no FEL boot mode and no UART
header**. There is no way to recover a bad bootloader or kernel over USB or a
serial cable. If the bootloader or kernel is corrupted, the only recovery path
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
boots normally and the stock update mechanism can overwrite userland partitions.

---

## Path B — Hard-brick: bad bootloader or kernel (reachable in P4+)

**Symptom:** The printer does not complete boot at all — black screen, immediate
power-off, or no network. Path A is not possible because the device cannot boot
far enough to run the update mechanism.

**When this can happen:** Plans P4 and later flash the bootloader and/or kernel.
This path should never be needed for P0–P3 work.

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

5. Write the golden image:

   ```sh
   # DANGER: confirm <reader-dev> is the eMMC reader, NOT your system disk,
   # before running. This command will irrecoverably overwrite the target device.
   gzip -dc golden-kunos-20260531-152104.img.gz | sudo dd of=/dev/<reader-dev> bs=4M conv=fsync status=progress
   ```

   Replace `<reader-dev>` with the confirmed device node from step 4.

6. Wait for `dd` to finish (`conv=fsync` ensures data is committed to the eMMC
   before the command exits). This writes the full 7,818,182,656-byte image.
7. Safely eject/unmount the reader, reassemble the printer, and power on.
8. Verify the printer boots normally.

---

## Where things live

| Item | Location | In git? |
|---|---|---|
| Golden image | `recovery/golden-kunos-20260531-152104.img.gz` | **NO** |
| Image checksum | `recovery/golden-kunos-20260531-152104.img.gz.sha256` | **NO** |
| Image size sidecar | `recovery/golden-kunos-20260531-152104.size` | **NO** |
| Partition map | `recovery/partitions-20260531-152104.txt` | YES |
| Dump script | `recovery/dump_golden.sh` | YES |
| Verify script | `recovery/verify_dump.sh` | YES |
| This runbook | `recovery/RUNBOOK.md` | YES |

**The large `.img.gz` file is gitignored and is NOT committed to the repository.**
It lives only on local disk (and wherever you back it up). A future operator
cloning this repo will NOT have the golden image — they must either:
- Obtain it from an external backup (e.g., an external drive, NAS, or cloud
  storage where you archived it), or
- Make a fresh dump from a known-good device using the procedure below.

**Back up the golden image to at least one external location before doing any
work that could brick the device.**

---

## Making a fresh golden dump

If you need to capture a new golden image (e.g., after verifying a clean state
on a new device, or to refresh the baseline):

```sh
# From the repo root:
./recovery/dump_golden.sh root@<printer-ip>
```

This SSHes into the printer, reads `/dev/mmcblk0` via `dd`, gzip-compresses the
stream locally, and writes:
- `recovery/golden-<hostname-or-ip>-<timestamp>.img.gz`
- `recovery/golden-<hostname-or-ip>-<timestamp>.size`
- `recovery/golden-<hostname-or-ip>-<timestamp>.img.gz.sha256`

Then verify the dump:

```sh
./recovery/verify_dump.sh recovery/golden-<hostname-or-ip>-<timestamp>.img.gz
```

Expected output ends with:
```
expected=7818182656 actual=7818182656
sha256:
golden-...: OK
OK: dump is full-size and checksum-valid
```

Do not proceed with any kernel/bootloader-modifying work until this verification
passes. This is the GATE-ZERO safety requirement for the ReForge project.
