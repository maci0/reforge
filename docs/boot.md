# ReForge boot — stock chain, hooks, intervention & the installed service chain

**Date:** 2026-06-02
**SoC:** Allwinner T113-S3 (sun8iw20p1), dual Cortex-A7, 128 MB DRAM.
**Status:** reference — verified read-only against the live printer + the eMMC dumps.

The single boot reference. §1–§6 cover the **stock/forge-x substrate**: the BROM→init
chain, where (and how reversibly) we can intervene, how forge-x hooks in, and how the
stock firmware detects a USB update `.tgz` (the mechanism live-mode + the installer ride
on). §7 covers the **installed-ReForge boot** (the chroot service chain). Live-mode boot
is its own topic — see [live-mode.md](live-mode.md).

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
| 0 | **BROM FEL** | `xfel`/`sunxi-fel` over USB0 (BROM enters FEL if boot0 fails, FEL trigger held, or U-Boot runs `efex`) | n/a (RAM-only) | **recovery / kernel-test context**, not a standing hook. On this unit needs **two solder mods** (USB0 internal pad → ext. connector; 3.3 V UART for `efex` entry). See [`research/2026-06-04-brick-safe-kernel-test-paths.md`](research/2026-06-04-brick-safe-kernel-test-paths.md). |
| 1 | boot0 / SPL (eGON) | reflash raw eMMC sectors 0..73727 | only via FEL | **BRICK** (FEL never rehearsed) |
| 2 | U-Boot binary | reflash boot0/uboot area | only via FEL/SPL | **BRICK** |
| 3 | **U-Boot env (p2/p3)** | **`fw_setenv`** — edit `bootargs`/`bootcmd`/`init=`, or add a `boot.scr` | **ONLY if it still boots to a shell** — see ⚠ below | **HIGH on this unit** — a bad `init=`/`bootargs`/`bootcmd` boots U-Boot+kernel but kills userspace; with **no UART + no FEL** there's no in-band fix → **eMMC-reader hard-brick** |
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
- **Earliest userspace-controlling pre-kernel hook:** the **U-Boot environment on p2**
  (`fw_setenv`; `/etc/fw_env.config` maps `mmcblk0p2 0x0 0x20000` + p3). BUT it is **NOT
  a safe hook on this unit** — see ⚠ below. Only the *value* is reversible, and only if
  the new value still boots to a shell.
- **Earliest TRULY SAFE hook:** create **`/etc/preinit`** (inittab calls it first; it
  doesn't exist today). A broken `/etc/preinit` is **non-fatal** — busybox init logs the
  error and continues to the next sysinit line, so the box still boots to SSH and you
  revert with `rm /etc/preinit`. This is the right place for early experiments.

> ⚠ **Brick reality (no FEL, no UART on this unit as shipped — `tools/recovery/RUNBOOK.md`).**
> Both are *gated behind hardware mods*, not silicon-absent: the T113-S3 BROM exposes FEL
> on USB0 (internal JST PH2.0 pad, requires soldering an external connector) and the
> board has UART0 console pads next to USB0 (requires a 3.3 V USB-UART adapter). Once
> both mods are in, FEL becomes a brick-safe kernel-test path and `fw_setenv` becomes
> in-band recoverable from the U-Boot prompt. Recipe + workflow:
> [`research/2026-06-04-brick-safe-kernel-test-paths.md`](research/2026-06-04-brick-safe-kernel-test-paths.md).
> A bad `init=`/`bootargs`/`bootcmd` set via `fw_setenv` does NOT corrupt U-Boot, so
> U-Boot + the kernel still run — but userspace never starts. You then have **no SSH**
> (no userspace), **no U-Boot prompt** (no UART), **no FEL** (USB). That is a hard-brick
> recoverable ONLY by Path B: open the enclosure, attach an eMMC reader, and
> `gzip -dc tools/recovery/golden.img.gz | sudo dd of=/dev/<reader-dev> bs=4M conv=fsync`.
> The redundant p3 copy only protects against a *bad CRC* (U-Boot then falls back to its
> compiled-in defaults); it does NOT protect against a *valid-but-wrong* value, which is
> what `fw_setenv` writes. Therefore: do NOT change boot-critical env vars on this unit
> until the eMMC-reader golden-restore has been rehearsed end-to-end. Prefer `/etc/preinit`
> (#6) for early hooks; reserve `init=` overrides for after recovery is proven + with a
> wrapper that `exec /init` on any error.

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
Full forge-x chroot/service teardown: [board-notes/forge-x-boot-architecture.md](board-notes/forge-x-boot-architecture.md).

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

**Brick-safety on this unit (no FEL, no UART) has only TWO tiers:**
- **SAFE — revertible over SSH:** changes to **files on the rootfs (p6)** — `/etc/preinit`,
  inittab, rc scripts, `/opt/auto_run.sh`. If they misbehave the box still boots to a
  shell (or stock), so you `rm`/edit them back. Worst case, reflash a stock `.tgz` over
  USB (RUNBOOK Path A — needs userspace to reach `auto_run.sh`).
- **NOT SAFE — eMMC-reader recovery only:** the **U-Boot env (p2/p3)** and anything below
  it (U-Boot, boot0, boot.img). A bad value here can stop userspace, and with no UART/FEL
  the only fix is RUNBOOK **Path B** (open case → eMMC reader → `dd` golden). Treat the
  env as boot-code, not as a config file — even though `fw_setenv` makes it *look* easy.

### Pre-kernel env hook — U-Boot env (`fw_setenv`)  ⚠ hard-brick risk, see §4 ⚠
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
- Earliest *pre-kernel* hook: **U-Boot env (p2)** via `fw_setenv` → `init=` override →
  PID1 → clean early `switch_root`. **But NOT safe on this unit** — a bad value =
  eMMC-reader hard-brick (no UART/FEL). Gate behind a rehearsed golden-restore.
- Earliest *truly safe* hook (revertible over SSH): **`/etc/preinit`** (free unused
  hook; broken = non-fatal, box still boots).
- forge-x hooks by **owning the `/etc/init.d/S00init` symlink** (+ `SKIP_MOD` escapes).
- Stock update detection: `/opt/auto_run.sh` (rcS:50) — `Adventurer5MPro-*.tgz` or a
  bare `flashforge_init.sh`, exit-0 ⇒ `sleep 100000`, **no signature check**; MCU
  firmware flashes via `/opt/PROGRAM/control/<ver>/Update` + `run.sh`.
- ReForge-live currently hooks at the **latest** point (#8 auto_run); it could move as
  early as #3/#5/#6 if a future design wants pre-kernel / pre-mount control.

---

## 7. Installed-ReForge boot (the chroot service chain)

This is the **installed** product (Plan 3), distinct from the stock chain above and from
live-mode. ReForge installs as an **overlay on stock**: the stock SPL/U-Boot/kernel/init
are untouched; the **only** persistent change is one symlink, `/etc/init.d/S01reforge` →
the ReForge boot hook (`reforge-boot`). Everything ReForge lives under the writable
`/data/.reforge` chroot. (forge-x, by contrast, owns the `S00init` symlink — §3; the two
escape hatches both use the `SKIP_MOD` pattern.)

```mermaid
flowchart TD
    A[rcS] --> D{"S01reforge<br/>(reforge-boot)"}
    D --> E{"SKIP_MOD marker?<br/>/tmp/SKIP_MOD · $DATA/.reforge/SKIP_MOD"}
    E -- yes --> Z[Boot stock firmware<br/>firmwareExe / stock klipper]
    E -- no --> F{".reforge installed?<br/>(.installed stamp)"}
    F -- no --> Z
    F -- yes --> G[fire/ember banner]
    G --> H[Mount /data · read SCREEN_MODE]
    H --> T{"trial/LKG check (OTA era)"}
    T --> I["bind proc/sys/dev/run/tmp/data → /data/.reforge"]
    I --> J["chroot /data/.reforge · exec mod init chain"]
    J --> K[S00cloudblock] --> L[S35zram] --> M[S60klipper] --> N[S65moonraker]
    N --> O[S70httpd] --> P{"SCREEN_MODE=GUPPY?"}
    P -- yes --> Q[S75guppyscreen] --> R[S99ok]
    P -- no --> R
    R --> S([ReForge up])
```

| step | what | source |
|---|---|---|
| `S01reforge` | boot hook — chroots into `/data/.reforge` | `…/rootfs-overlay/.shell/reforge-boot` |
| `SKIP_MOD` gate | USB/`/tmp` marker → pure stock boot (escape hatch) | `reforge-boot` |
| banner | fire/ember "ReForge" splash | `usr/bin/reforge-banner` |
| `S00cloudblock` | block FF cloud hosts in `/etc/hosts` | `etc/init.d/S00cloudblock` |
| `S35zram` | insmod `zram.ko`/`zsmalloc.ko` + zstd swap; sources `reforge-vmtune.sh` (the VM sysctls) | `modules/zram-bsp/` + `.shell/reforge-vmtune.sh` |
| `S60klipper` | klippy — **jemalloc** (`LD_PRELOAD` + `MALLOC_CONF=narenas:1,…decay:0`) | `etc/init.d/S60klipper` |
| `S65moonraker` | Moonraker API/WS `:7125` — jemalloc | `etc/init.d/S65moonraker` |
| `S70httpd` | busybox httpd serves Mainsail `:80` (browser → Moonraker direct, no proxy) | `etc/init.d/S70httpd` |
| `S75guppyscreen` | LVGL UI on `/dev/fb0` — only when `SCREEN_MODE=GUPPY` | `etc/init.d/S75guppyscreen` |
| `S99ok` | services-up sentinel (OTA era: promote `mod`→LKG) | `etc/init.d/S99ok` |

Memory tuning (jemalloc, zram, the VM sysctls) is detailed in
[optimizations.md](optimizations.md). OTA adds a **trial/last-known-good** guard around
the `mod` dir (trial counter; reaching `S99ok` promotes to LKG; N=3 failures restore the
previous LKG) — see [ota.md](ota.md). Uninstall = remove the one `S01reforge` symlink.
