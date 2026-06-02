# AD5M / AD5M Pro boot chain, intervention points & stock hooks

**Date:** 2026-06-02
**SoC:** Allwinner T113-S3 (sun8iw20p1), dual Cortex-A7, 128 MB DRAM.
**Status:** reference — verified read-only against the live printer + the eMMC dumps.

Answers: *where can we intervene in the stock/forge-x boot, how early, and how
reversibly* — plus how forge-x hooks in and how the stock firmware detects a USB
update `.tgz` (the mechanism ReForge live-mode + the installer ride on).

---

## 1. The boot chain (verified)

```
BROM (mask ROM in silicon; FEL USB recovery)
  → boot0 / SPL (eGON)            raw eMMC, sectors 0..73727 (~36 MB before p1)
  → U-Boot 2018.05                env on p2 (+ p3 redundant)
  → kernel  (boot.img @ p4, "ANDROID!" image format: kernel+dtb+ramdisk)
       cmdline: root=/dev/mmcblk0p6 init=/init console=ttyS3,115200 cma=16M
                androidboot.hardware=sun8iw20p1 androidboot.dramsize=128 ...
  → /init  →  symlink to /bin/busybox     (busybox init)
  → /etc/inittab:
       ::sysinit:/etc/preinit             ← FIRST userspace action (file ABSENT = unused)
       ::sysinit:/bin/mount -t proc ...
       ::sysinit:/bin/mount -o remount,rw /
       ::sysinit:/bin/mount -a
       ::sysinit:/sbin/swapon -a
       ... → /etc/init.d/rcS
              S00init  → symlink to /opt/config/mod/.shell/S00init   (FORGE-X hook)
              S01syslogd S02klogd S10udev S20urandom S30dbus S40network
              S50postgresql S50telnet S55boot S60dropbear S80dnsmasq S98camera S98zssh S99root
              rcS:50:  /opt/auto_run.sh &     ← STOCK USB/update detection (backgrounded)
```

Partition map (GPT): `p1 boot-resource(33.6M) · p2 env(1M) · p3 env-redund(1M) ·
p4 boot(34.4M) · p5 dsp0(1M) · p6 rootfs(1.3G) · p7 UDISK/data(5.9G)`.

---

## 2. Intervention points — earliest → latest

| # | Stage | Hook method | Reversible | Risk |
|---|-------|-------------|-----------|------|
| 0 | **BROM FEL** | `sunxi-fel` over USB-OTG (BROM enters FEL if boot0 fails / key held) | n/a (RAM-only) | **recovery context**, not a standing hook; needs USB + trigger |
| 1 | boot0 / SPL (eGON) | reflash raw eMMC sectors 0..73727 | only via FEL | **BRICK** (FEL never rehearsed) |
| 2 | U-Boot binary | reflash boot0/uboot area | only via FEL/SPL | **BRICK** |
| 3 | **U-Boot env (p2/p3)** | **`fw_setenv`** — edit `bootargs`/`bootcmd`/`init=`, or add a `boot.scr` | **YES** — `fw_setenv` is CRC-safe; p3 is a redundant copy; restore = stock | **LOW** ⭐ earliest *safe* hook |
| 4 | boot.img (p4) | repack the Android kernel+ramdisk+cmdline | reflash p4 | medium |
| 5 | **`init=` override** | env `init=` → our PID1 script (which `exec`s busybox / `switch_root`) | YES (env) | low–med ⭐ earliest *userspace control* |
| 6 | **/etc/preinit** | create the file (absent today) → runs before mounts/swap/net/rcS | YES (file on p6) | LOW ⭐ earliest *safe userspace* on the stock flow |
| 7 | /etc/inittab, rcS, S00init | add a sysinit line / rc script (forge-x owns S00init) | YES (file) | low |
| 8 | /opt/auto_run.sh (rcS:50) | the USB-launcher hook ReForge-live uses today | YES | trivial — but **latest** |

### Practical conclusions
- **Earliest possible code:** BROM **FEL** (USB) — before any eMMC code, but a
  recovery/injection path, not a persistent boot modification.
- **Earliest persistent code:** boot0/SPL — reflash → brick risk, FEL recovery never
  rehearsed → **off-limits in practice**.
- **Earliest SAFE + reversible:** the **U-Boot environment on p2** (`fw_setenv` is on
  the device; `/etc/fw_env.config` maps `mmcblk0p2 0x0 0x20000` + p3). Change
  `bootargs`/`init=`/`bootcmd` *before the kernel runs*, restore from p3/backup → stock
  boots. No code reflash.
- **Earliest USERSPACE we control:** `init=<our-script>` set via that env → we are
  **PID1** before any mount; **or** create **`/etc/preinit`** (inittab already calls it
  first; it doesn't exist today → a free, intended, reversible early hook).

### Early `switch_root` (re: the earlier discussion)
ReForge-live hooks at `auto_run.sh` (#8) — deep under stock init, not PID1, so a real
`switch_root` doesn't fit *there*. But via the **env `init=` override (#3→#5)** the
kernel execs *us* as PID1 before mounts; from there `switch_root`/`pivot_root` into a
ReForge rootfs is clean — and reversible by restoring the env (no bootloader/kernel
reflash, so brick-safety holds). That is the architecturally-correct place for an early
switch_root, not `auto_run`.

---

## 3. How forge-x hooks the boot

`/etc/init.d/S00init` is a **symlink → `/opt/config/mod/.shell/S00init`** — forge-x
**replaces** the stock S00init, so it runs **first** in the rcS sequence. Its S00init:
- sources `/opt/config/mod/.shell/common.sh`
- `handle_special_boot_mode` → `boot/init_boot_flag.sh apply` (special boot modes)
- `handle_boot_options` — the **dual-boot / failsafe** gate:
  - `BOOT_SKIP_F` present → `touch /tmp/SKIP_MOD_SOFT`, return 1 → **stock loads** (user-requested skip)
  - `BOOT_FAILURE_F` present → `touch /tmp/SKIP_MOD_HARD`, return 1 → **stock loads** (boot-failure failsafe)
- otherwise → sets up the forge-x chroot (`/data/.mod/.forge-x`) + launches its stack.

So forge-x's takeover mechanism = **own the S00init symlink**, with `SKIP_MOD`
soft/hard escape hatches. (ReForge's installer mirrors this `SKIP_MOD` pattern.)

Note `/opt/auto_run.sh` (rcS:50) is the *stock* script and **still runs** even with
forge-x installed — which is exactly why ReForge live-mode (a USB `flashforge_init.sh`)
works on a forge-x box.

---

## 4. How stock FW detects a USB update `.tgz`  (`/opt/auto_run.sh`)

Runs at `rcS:50` (backgrounded). `MACHINE=Adventurer5MPro`, `PID=0024`. Sequence:

1. `fsck`/mount `/data` (mmcblk0p7) if not mounted; clear `/data/update`.
2. `insmod /lib/modules/8821cu.ko` (WiFi); `sleep 2` for USB enumeration.
3. Loop `/dev/sda`, `/dev/sda1..4`; `mount -t vfat ... /mnt`.
4. **Update-tarball path:** `ls -1t /mnt/Adventurer5MPro-*.tgz` →
   - copy newest to `/data/`, `mkdir /data/update`, `tar -xvf` into `/data/update/`,
     then run **`/data/update/flashforge_init.sh Adventurer5MPro 0024`**.
   - on exit 0 → `umount /mnt; rm -rf /data/update; sleep 100000`.
5. **Direct-script path:** if `/mnt/flashforge_init.sh` exists → `chmod a+x` + run
   **`/mnt/flashforge_init.sh Adventurer5MPro 0024`**; on exit 0 → `sleep 100000`.
6. After the loop: `/opt/klipper/usb_map.sh`; then the **MCU-firmware update** check —
   `/opt/PROGRAM/control/<latest>/Update` flag present → `cd` there + `./run.sh` +
   `reboot -f`; then launch the stock UI `ffstartup-arm -f .../ffstartup.cfg &`.

### The contract ReForge rides on
- **No signature check.** Detection is purely by filename / file presence.
- **Two install hooks:** a tarball named **`Adventurer5MPro-*.tgz`** (extracted, its
  inner `flashforge_init.sh` runs) **or** a bare **`/mnt/flashforge_init.sh`** at the
  USB root (run directly). Both get args `Adventurer5MPro 0024`.
- **Exit-code semantics:** `flashforge_init.sh` exit **0 → stock `sleep 100000`** (the
  launcher owns the box → this is how live-mode blocks stock); **non-zero → stock falls
  through** to `ffstartup-arm` (stock UI). ReForge-live returns 0 to hold; the installer
  installs then returns appropriately.
- **MCU flashing path:** `/opt/PROGRAM/control/<ver>/Update` + `run.sh` + reboot is how
  stock flashes the MCU firmware — the mechanism to reuse for v11↔v13 MCU switching.

---

## 5. Recipes (brick-safety boundary)

**SAFE side (reversible, no FEL needed): everything at or above the U-Boot env.**

### Earliest safe pre-kernel hook — U-Boot env (`fw_setenv`)
```sh
# inspect
fw_printenv                      # reads p2 (per /etc/fw_env.config)
# append a kernel arg / redirect init (example: our PID1)
fw_setenv init /sbin/reforge-init
# revert
fw_setenv init /init             # back to stock  (p3 redundant copy also protects you)
```
`/etc/fw_env.config` → `mmcblk0p2 0x0 0x20000` (+ `mmcblk0p3` redundant). `fw_setenv`
updates the CRC and the redundant copy, so a bad value is recoverable.

### Earliest safe userspace hook — /etc/preinit (currently absent)
```sh
# inittab already has:  ::sysinit:/etc/preinit   (no-op today, file missing)
cat > /etc/preinit <<'EOF'
#!/bin/sh
# runs before mounts / swap / network / rcS / auto_run
/opt/reforge/early-hook.sh || true
EOF
chmod +x /etc/preinit
# revert: rm /etc/preinit
```

### Become PID1 for an early switch_root — env init= override
```sh
fw_setenv init /sbin/reforge-init     # /sbin/reforge-init does setup then:
#   mount the ReForge rootfs, then  exec switch_root /newroot /sbin/init
# revert: fw_setenv init /init
```

**UNSAFE side (reflash, brick risk, FEL recovery NOT rehearsed): boot0/SPL, U-Boot
binary, boot.img.** Do not touch on the live printer until the eMMC-reader golden
restore is drilled (see docs/specs Plan 3, recovery posture).

---

## 6. Summary

- Earliest *theoretically*: BROM FEL (USB) — recovery only.
- Earliest *safe + reversible*: **U-Boot env (p2)** via `fw_setenv` (pre-kernel) →
  enables `init=` override → PID1 → clean early `switch_root`.
- Earliest *safe userspace on the stock flow*: **`/etc/preinit`** (free unused hook).
- forge-x hooks by **owning the `/etc/init.d/S00init` symlink** (+ `SKIP_MOD` escapes).
- Stock update detection: `/opt/auto_run.sh` (rcS:50) — `Adventurer5MPro-*.tgz` or a
  bare `flashforge_init.sh`, exit-0 ⇒ `sleep 100000`, **no signature check**; MCU
  firmware flashes via `/opt/PROGRAM/control/<ver>/Update` + `run.sh`.
- ReForge-live currently hooks at the **latest** point (#8 auto_run); it could move as
  early as #3/#5/#6 if a future design wants pre-kernel / pre-mount control.
