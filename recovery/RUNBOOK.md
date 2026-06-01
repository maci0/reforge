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

5. Write the golden image. Use the **stock-clean** golden for a pure-stock
   recovery baseline (preferred), or the original golden if you need to restore
   the forge-x state exactly as it was captured:

   ```sh
   # DANGER: confirm <reader-dev> is the eMMC reader, NOT your system disk,
   # before running. This command will irrecoverably overwrite the target device.

   # Preferred: pure stock (forge-x removed)
   gzip -dc recovery/golden-stock-clean.img.gz | sudo dd of=/dev/<reader-dev> bs=4M conv=fsync status=progress

   # Alternative: exact capture state (forge-x installed)
   # gzip -dc recovery/golden-kunos-20260531-152104.img.gz | sudo dd of=/dev/<reader-dev> bs=4M conv=fsync status=progress
   ```

   Replace `<reader-dev>` with the confirmed device node from step 4.

6. Wait for `dd` to finish (`conv=fsync` ensures data is committed to the eMMC
   before the command exits). This writes the full 7,818,182,656-byte image.
7. Safely eject/unmount the reader, reassemble the printer, and power on.
8. Verify the printer boots normally.

---

## Two goldens — which one to use

There are now two golden images on disk. They are **both gitignored** (large
binaries) and live only on local disk / external backup.

| Image | State | Use for |
|---|---|---|
| `recovery/golden-kunos-20260531-152104.img.gz` (~886 MB gz) | Captured live, **forge-x installed** | Exact snapshot of the printer as it was; reference only |
| `recovery/golden-stock-clean.img.gz` (~877 MB gz) | Derived offline, **pure stock — forge-x removed** | **Preferred recovery baseline and qemu rootfs source** |

The `golden-stock-clean.img.gz` is the preferred pristine recovery baseline.
It was derived from the original dump using `recovery/make-clean-golden.sh`
(offline, loop-mounted, no live printer access). The forge-x removal was guided
by forge-x's own `uninstall.sh` + `S00init` + `boot/boot.sh` install record;
it removes exactly what those scripts add and nothing more.

**To regenerate the stock-clean golden** (if it is lost or the original golden is
refreshed):

```sh
# From the repo root (needs sudo for loop-mount):
sudo ./recovery/make-clean-golden.sh
```

This decompresses the original golden into a scratch raw, mounts p6/p7,
removes all forge-x artifacts, verifies the cleaned state (15 checks PASS/FAIL),
recompresses → `recovery/golden-stock-clean.img.gz`, extracts p6 →
`validation/qemu-harness/build/stock-clean-rootfs.ext4`, then deletes the
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
| Original golden (forge-x state) | `recovery/golden-kunos-20260531-152104.img.gz` | **NO** |
| Original checksum | `recovery/golden-kunos-20260531-152104.img.gz.sha256` | **NO** |
| Original size sidecar | `recovery/golden-kunos-20260531-152104.size` | **NO** |
| **Stock-clean golden (preferred)** | `recovery/golden-stock-clean.img.gz` | **NO** |
| Clean-golden derivation script | `recovery/make-clean-golden.sh` | YES |
| Cleaned p6 rootfs for qemu | `validation/qemu-harness/build/stock-clean-rootfs.ext4` | **NO** |
| Partition map | `recovery/partitions-20260531-152104.txt` | YES |
| Dump script | `recovery/dump_golden.sh` | YES |
| Verify script | `recovery/verify_dump.sh` | YES |
| This runbook | `recovery/RUNBOOK.md` | YES |

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
