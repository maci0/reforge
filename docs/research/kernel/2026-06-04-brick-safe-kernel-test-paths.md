# Brick-safe custom-kernel test paths on AD5M Pro

**Date:** 2026-06-04
**Status:** documented, **not rehearsed**. Reference for future Plan 5 (mainline-kernel
self-port) work. No hardware mod or reflash has been performed against the live unit
(`kunos`) based on this document.
**See also:** [`../boot.md`](../../boot.md) (intervention table + brick-safety boundary),
[`../board-notes/device-overview.md`](../../board-notes/device-overview.md),
[`2026-05-31-g992-research-findings.md`](2026-05-31-g992-research-findings.md) §3 + §6,
[`../../tools/recovery/RUNBOOK.md`](../../../tools/recovery/RUNBOOK.md).

---

## 1. The problem

Plan 5 will eventually ship ReForge's own kernel. Before that, we want a way to test
a custom kernel (any kernel — mainline-LTS port, BSP rebuild with extra Kconfig, etc.)
on real AD5M Pro hardware **without persistent eMMC writes**, so that recovery on a
hang/panic is literally "power-cycle". Three properties define the loop we want:

1. No change to U-Boot env (`mmcblk0p2/p3`) — that's the hard-brick tier on this
   unit (see [`../boot.md`](../../boot.md) §2 row #3, §5).
2. No reflash of `boot.img` (`mmcblk0p4`) per test — medium-risk tier, not the
   iterative loop we want.
3. Recovery on failure = remove power, re-apply power; stock comes back identical.

Two mechanisms in the literature do exactly this: **kexec** (warm-jump from a running
kernel to another kernel) and **FEL** (the Allwinner BROM USB recovery protocol that
loads + runs a kernel out of RAM with the eMMC untouched). This note records what
works on the AD5M Pro for each.

---

## 2. Path A — `kexec` from the running stock kernel

### 2.1 Status on stock: NOT available

The stock Linux 5.4.61 BSP kernel running on the live device (verified against the
on-disk capture `docs/board-notes/stock-kernel-config-5.4.61.txt.gz`, which is a literal
`cp /proc/config.gz` from `root@192.168.0.158`, hostname `kunos`):

```
# CONFIG_KEXEC is not set
# CONFIG_CRASH_DUMP is not set
```

So `sys_kexec_load(2)` returns `-ENOSYS`. No userspace trick gets around that —
machine_kexec, purgatory, the per-arch trampolines etc. are simply not compiled into
the running image. A kernel module cannot patch it in: the symbols aren't exported, and
kexec is tens of KB of new code, not a small flip.

### 2.2 The Kconfig is reachable in the BSP source

`vendor/kernels/tina-bsp-kernel/arch/arm/Kconfig:1909-1923`:

```kconfig
config KEXEC
    bool "Kexec system call (EXPERIMENTAL)"
    depends on (!SMP || PM_SLEEP_SMP)
    depends on MMU
    select KEXEC_CORE
```

Every precondition is already satisfied by the running kernel:

| Requirement | Stock kernel | Status |
|---|---|---|
| `CONFIG_MMU=y` | `CONFIG_MMU=y` | ✓ |
| `(!SMP \|\| PM_SLEEP_SMP)` | `CONFIG_SMP=y` + `CONFIG_PM_SLEEP_SMP=y` | ✓ |
| `CONFIG_BLOCK=y` (transitive) | `CONFIG_BLOCK=y` | ✓ |
| `CONFIG_AUTO_ZRELADDR=y` (helps loader) | `CONFIG_AUTO_ZRELADDR=y` | ✓ |

So a rebuild of the same BSP, same commit (`349a0b9`), same `.config` **plus
`CONFIG_KEXEC=y`** would yield a kernel binary identical to stock for every userspace
consumer (same cmdline, same DT, same modules ABI) but with the kexec syscall available.
kexec-tools userland is a Buildroot package (`BR2_PACKAGE_KEXEC`, ~200 KB stripped).

### 2.3 The hybrid plan: one-time `boot.img` reflash, then iterate freely via kexec

If you accept one prior persistent change to the eMMC, the loop is:

1. Rebuild the BSP kernel with only `CONFIG_KEXEC=y` (+ optionally `CONFIG_ATAGS_PROC=y`)
   added on top of the captured stock `.config`.
2. Repack into the Android boot-image format (`mkbootimg`), preserving the **identical**
   cmdline, dtb, and ramdisk byte-for-byte.
3. Reflash `mmcblk0p4` once — over SSH from live mode so the running system isn't
   reading from p4. `tools/recovery/golden.img.gz` (Path B per RUNBOOK) is the recovery.
4. From then on, every kernel test is:
   ```
   kexec -l /path/to/test.img --initrd=... --command-line='...'
   kexec -e
   ```
   Test kernel panics / hangs → power-cycle → kexec-enabled stock kernel comes back.

You pay the brick-risk *once*. After that the loop is software-only and brick-safe.

### 2.4 What kexec does NOT change in stock semantics

The repacked stock+kexec `boot.img` boots **identically** to stock for everything
except the syscall surface: same `/init` → same busybox init → same rcS → same
`auto_run.sh` USB detection → same firmwareExe launch (or forge-x S00init takeover, if
installed). So the "stock or forge-x or ReForge" boot decision is unaffected; kexec is a
latent capability that only activates when something in userspace invokes it.

---

## 3. Path B — FEL via `xfel` over USB0

### 3.1 Conceptually exactly what we want

FEL is a BROM-resident USB protocol on Allwinner SoCs. The BROM enters FEL when boot0
fails CRC, when a board-specific trigger is held during reset, or when running U-Boot
issues `efex`. Once in FEL, the host PC can:

- Initialize DRAM via an `xfel ddr <chip>` payload (the BROM only brings up SRAM)
- `xfel write <addr> <file>` arbitrary bytes into RAM
- `xfel exec <addr>` to jump

That gives a **brick-free** way to load and run any kernel: nothing touches the eMMC,
power-cycle returns to the BROM → boot0 (in mask-ROM + eMMC, unchanged) → stock boots
normally.

### 3.2 T113-S3 silicon support is verified

`xfel` (the modern Allwinner-FEL fork, [`xboot/xfel`](https://github.com/xboot/xfel))
ships explicit T113 support at `chips/r528_t113.c` (R528 is the same die as T113-S3,
sun8iw20). The chip identifier is `0x00185900`. The community has the working
workflow:

```
$ xfel ver
AWUSBFEX ID=0x00185900(R528/T113) dflag=0x44 dlength=0x08 scratchpad=0x00045000

$ xfel sid
d3402000ec1408140140082114cb5bcb

$ xfel ddr t113-s3
Initial ddr controller succeeded
```

(Reference: [aw-ol.com forum thread on T113-S3 RT-Thread bring-up via xfel](https://bbs.aw-ol.com/topic/1279/).)

### 3.3 The AD5M-Pro-specific gates: TWO solder mods

This is where the picture changes from "ideal" to "real". The only published source
that has actually run FEL on AD5M Pro hardware is
[**DrA1ex/ff5m `docs/RECOVERY.md`** § "Recovery using FEL"](https://github.com/DrA1ex/ff5m/blob/main/docs/RECOVERY.md).
Two prerequisites are non-negotiable on this board:

**Gate 1 — USB0 (the only FEL-capable port) is internal, not the front USB-A.**

The front USB-A is USB1, wired host-only — that's the port the live-mode USB stick goes
into. FEL on Allwinner is hard-routed to USB0 in the BROM; you cannot redirect it. USB0
on AD5M Pro is brought out only to an internal pad:

> "You'll need to **solder USB0**. This is relatively simple, even for beginners (you
> would need JST PH2.0 5pin)."
> — DrA1ex/ff5m RECOVERY.md

So you wire a JST PH2.0 5-pin connector to the USB0 pad → run a cable out of the case
→ terminate in a USB connector for the host PC.

**Gate 2 — there is no documented hardware FEL trigger; entry is via U-Boot `efex`.**

Most sunxi boards have either a "FEL"/"BOOT" GPIO button or known test pads to short
(R53 on OpenCentauri, GPIO PL4 on F133-A, the SD-slot trick on older boards). AD5M Pro
has none of these published. The community-tested entry method is via the U-Boot prompt:

> "You don't need to solder a button to a resistor. Instead, interrupt the boot process
> via UART (press Enter when prompted) to enter U-Boot. From U-Boot, run the following
> command to enter FEL mode: `efex`"

So **FEL on this board requires UART access too**. Without UART, the only way to enter
FEL is to intentionally corrupt boot0 so the BROM falls through to FEL automatically —
which is the brick we're trying to avoid.

Our prior research already flagged this state in `2026-05-31-g992-research-findings.md`
§3: *"No FEL documented anywhere ... Treat FEL as unverified/unexposed, not silicon-absent."*
The DrA1ex find upgrades that to *"verified accessible after USB0 + UART solder mods,
no zero-mod path"*.

### 3.4 The UART mod (independently useful)

From the same RECOVERY guide: "Connect the UART adapter to the motherboard near the
processor (next to USB0)". Requirements:

- **3.3 V** USB-UART adapter. **NOT 5 V** — a 5 V adapter "could **fry the CPU**" (per
  RECOVERY.md). An ESP8266/ESP32 in MultiSerial passthrough also works.
- Pin map: adapter RX → board TX, adapter TX → board RX, adapter GND → board GND, leave
  Vcc disconnected.
- Baud 115200 (matches `console=ttyS3,115200` in the stock cmdline).

UART alone (without USB0) is independently the **highest-value brick-risk reducer** on
this device:

- Kernel console for any kernel test (panic/oops messages instead of silent hangs).
- U-Boot prompt: interrupt autoboot, set/unset env, `bootm` a kernel loaded from USB
  into RAM via `usb start; fatload usb 0 <addr> <file>` — without ever writing eMMC.
- A bad `init=` / `bootargs` / `bootcmd` via `fw_setenv` (currently §5 hard-brick on
  this unit) becomes recoverable from the prompt → no longer hard-brick.

[`../boot.md`](../../boot.md) §2 explicitly calls this out: *"`fw_setenv` is **NOT a safe
hook on this unit** — see ⚠ below"* would become *"safe-with-UART"* once the mod is in.

### 3.5 The FEL kernel-test workflow (post-mods)

```sh
# Host PC (Linux), USB cable plugged into the soldered USB0 connector:

# 1. From the printer's UART, interrupt U-Boot autoboot (press Enter), then:
=> efex
   # T113 jumps into FEL; AWUSBFEX device enumerates on host:
   #   $ lsusb | grep Allwinner
   #   Bus 001 Device 0xx: ID 1f3a:efe8 Allwinner Technology

# 2. Verify host ↔ BROM
sudo xfel ver
# AWUSBFEX ID=0x00185900(R528/T113) ...

# 3. Bring up the 128 MB SiP DDR (the xfel T113-S3 payload knows the DRAM controller)
sudo xfel ddr t113-s3
# Initial ddr controller succeeded

# 4. Load a kernel + dtb + (optional) initramfs into DRAM
sudo xfel write 0x40080000  arch/arm/boot/zImage
sudo xfel write 0x4fa00000  arch/arm/boot/dts/sun8i-t113-ad5m.dtb
sudo xfel write 0x50000000  initramfs.cpio.gz    # optional

# 5. Jump. For a quick poke, exec the zImage entry directly:
sudo xfel exec 0x40080000
# (For passing a proper cmdline + r2=dtb register, chain via U-Boot in RAM:
#    sudo xfel uboot u-boot-sunxi-with-spl.bin
#    => bootz 0x40080000 - 0x4fa00000   # from the live U-Boot)

# 6. Kernel console + any failure visible on UART. Power-cycle → stock back, clean.
```

Address conventions are T113-typical (DRAM base `0x40000000`). Confirm against the
target kernel's `arch/arm/boot/Image.lds` and the dts/initrd sizes before use.

### 3.6 Risks worth knowing about

- **The two solder mods are required, period.** No software path bypasses them. Budget
  ~1–2 h of careful work on the mainboard, with a magnifier. Photos of the JST PH2.0
  USB0 pad and the UART pads are in DrA1ex's RECOVERY.md.
- **The `efex` command's exact name/form on the AD5M Pro's stock U-Boot 2018.05 fork is
  unverified by us** — DrA1ex's photo shows it works on their unit. If FF customized
  U-Boot to strip the command, the fallback is corrupting boot0 (= brick risk), so this
  should be checked at the U-Boot prompt as the first thing after the UART mod lands.
- **xfel must be a recent build.** T113 support landed in late 2022; pin a known-good
  release (`v1.2.x`+) rather than distro-packaged. Confirm with `xfel ver` returning
  `0x00185900`.
- **DDR init timing.** The `xfel ddr t113-s3` payload is built for the standard T113-S3
  128 MB SiP. AD5M Pro uses that SiP per
  `2026-05-31-g992-research-findings.md` §5 ("DRAM: 128 MB is INTEGRATED into the
  T113-S3 package (SiP), not a discrete chip"), so the payload should be a fit, but worth
  verifying with `xfel hexdump 0x40000000 0x10` after init.

---

## 4. Path C — touch nothing, do nothing

Status quo. Every kernel test reflashes `boot.img` (medium brick-risk per `boot.md` §2
row #4). The eMMC golden image is the recovery (RUNBOOK Path B = open case + eMMC
reader). This is what we have today and it is **not** a sustainable Plan 5 dev loop —
it's a one-shot kernel-deploy mechanism.

---

## 5. Comparison

| | Path A: kexec hybrid | Path B: FEL (xfel) | Path C: status quo |
|---|---|---|---|
| One-time setup | One `dd` reflash of `boot.img` w/ `CONFIG_KEXEC=y` rebuild; ~30 min + golden-rehearsed recovery | Open case once: solder USB0 to ext. connector + solder 3.3 V UART pads; ~1–2 h | none |
| Per-test cost | `kexec -l && kexec -e` (SSH) | `xfel write + xfel exec` (USB) | reflash `boot.img` each test |
| Per-test brick risk | **zero** | **zero** | **medium** (each test) |
| Stock-rootfs modification | one `boot.img` reflash (semantically identical, +kexec syscall) | **none, ever** (eMMC untouched forever) | varies by test |
| UART/console for kernel test | only via separate UART mod | **included** (UART is required to enter FEL) | needs separate UART mod anyway |
| Sunxi-community tooling | irrelevant | **direct fit** (xfel, awboot, sunxi-fel ecosystem) | irrelevant |
| Brick-tier of failed setup | mmcblk0p4 medium-risk | low (no eMMC ops); failed `efex` falls back to stock boot if U-Boot prompt is preserved | n/a |
| Useful for Plan 5 mainline dev | yes (warm-jump kernels) | **yes** (canonical sunxi dev loop) | no |

---

## 6. Conclusion (for the record — no action taken)

If/when Plan 5 work resumes, **Path B (FEL) is the preferred test loop** for these
reasons:

1. Zero modification to stock eMMC, ever. The "did I break it with the test kernel or
   with my modified stock kernel?" question never arises.
2. The UART mod required to enter FEL via `efex` is *independently* the single highest-
   value brick-risk reducer on this device (`boot.md` §5 elevates from "no UART, hard-
   brick on bad env" to "in-band recoverable").
3. xfel is the canonical Allwinner dev tool; we inherit the linux-sunxi community's
   payloads (DDR, JTAG, SPI), tutorials, and bug surface instead of building parallel
   plumbing.

**Path A (kexec hybrid) is the fallback** if hardware mods are off the table — e.g. a
unit we cannot open. It is software-only after the one-time `boot.img` reflash, but it
carries that one prior brick-tier operation and leaves a (semantically identical)
modified stock kernel in p4 forever.

**Path C (status quo) is what we have today** and is fine for one-shot kernel deploys,
unworkable for iteration.

### Status: documented only

Per 2026-06-04 decision: **no hardware mod or reflash is attempted now.** This
document is the reference we use **before** opening the case or touching `mmcblk0p4`,
not a checklist to execute. The next concrete trigger would be Plan 5 mainline-kernel
work starting in earnest, at which point Path B should be picked up here.

### Prerequisite plan (host-only, zero device risk) — ✅ executed 2026-06-04

Before *either* Path A (kexec hybrid reflash) or Path B (FEL) is attempted, we need to
verify that we can reproduce the on-device kernel from our pinned BSP source +
captured `.config` + pinned toolchain (GCC 9.5.0 vs stock Linaro 5.3.1). That is a
purely host-side build + diff exercise. **Done 2026-06-04** — see the plan +
findings:

- Plan: [`docs/plans/2026-06-04-bsp-kernel-rebuild-and-diff.md`](../../plans/2026-06-04-bsp-kernel-rebuild-and-diff.md)
- Findings: [`docs/research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md`](2026-06-04-bsp-kernel-rebuild-findings.md)

Verdict: Tier 1 + Tier 2 + Tier 3 PASS. Built `Image` differs from stock by
**−756 bytes (−0.0058 %)**, `vermagic` byte-identical
(`5.4.61 SMP preempt mod_unload ARMv7 p2v8`), and **99.99 % of our exported
symbols (9055 / 9056) appear in stock as plain strings**. The 7 stock-only
Allwinner-vendor symbols (CAN, IR, PWM char-dev, SPI slave, SMC-TC) are
out-of-tree Tina SDK patches; none is exercised on the AD5M Pro's
documented hardware path. **Green light to layer `CONFIG_KEXEC=y` (Path A) on top of this baseline.**

### Path B follow-up (when Plan 5 starts in earnest)

The first FEL sub-task is `2026-XX-XX-fel-bringup.md`:
1. Verify the USB0 pad pinout against the schematic (or by probing).
2. Verify the UART pad locations + 3.3 V logic level.
3. Confirm the stock U-Boot 2018.05 fork still exposes `efex` (or document the
   alternative entry).
4. Do the two solder mods (USB0 + UART).
5. `xfel ver` must return `ID=0x00185900(R528/T113)`. If yes, FEL access is verified
   and Path B is open.

---

## 7. Pointers into the existing repo

- `docs/boot.md` §1 — boot chain (BROM → SPL → U-Boot → kernel → init)
- `docs/boot.md` §2 row #0 — BROM FEL entry table row (the row this document expands)
- `docs/boot.md` §5 — brick-safety boundary tiers
- `docs/board-notes/device-overview.md` — hardware inventory, T113-S3 + 128 MB SiP DDR
- `docs/board-notes/stock-kernel-config-5.4.61.txt.gz` — captured `/proc/config.gz`
  (the evidence for `CONFIG_KEXEC=n`)
- `docs/board-notes/running-unit-probe.txt` — uname + cmdline + lsmod
- `vendor/kernels/tina-bsp-kernel/arch/arm/Kconfig:1909-1923` — KEXEC Kconfig in BSP
- `docs/research/kernel/2026-05-31-g992-research-findings.md` §3, §5, §6 — prior FEL/UART
  status + DRAM SiP confirmation
- `docs/research/kernel/2026-06-01-stock-recovery-images.md` — mentions of xfel + community
  FEL recovery dumps
- `tools/recovery/RUNBOOK.md` — Path A (USB reflash) + Path B (eMMC reader); this doc
  is upstream of any hardware mod here.

---

## Sources

### Internal (this repo)

- `docs/boot.md`
- `docs/board-notes/device-overview.md`
- `docs/board-notes/stock-kernel-config-5.4.61.txt.gz`
- `docs/board-notes/running-unit-probe.txt`
- `docs/research/kernel/2026-05-31-g992-research-findings.md`
- `docs/research/kernel/2026-06-01-stock-recovery-images.md`
- `vendor/kernels/tina-bsp-kernel/arch/arm/Kconfig`
- `tools/recovery/RUNBOOK.md`

### External

- DrA1ex/ff5m **`docs/RECOVERY.md`** § "Recovery using FEL" (the **only** published
  AD5M-Pro FEL recipe; documents USB0 solder + `efex` from U-Boot + the `xfel_t113_ds`
  flash command): <https://github.com/DrA1ex/ff5m/blob/main/docs/RECOVERY.md>
- xboot/**xfel** — Allwinner FEL tool with T113 support
  (`chips/r528_t113.c`, `payloads/...`): <https://github.com/xboot/xfel>
- xboot/**xboot** T113-S3 page (canonical xfel command sequence:
  `xfel ddr t113-s3 → xfel write → xfel exec`):
  <https://github.com/xboot/xboot/tree/master/src/arch/arm32/mach-t113s3>
- linux-sunxi **FEL reference** (protocol, trigger methods):
  <https://linux-sunxi.org/FEL>
- linux-sunxi **FEL/USBBoot**: <https://linux-sunxi.org/FEL/USBBoot>
- aw-ol forum **T113-S3 bring-up via xfel** (working `xfel ver`/`sid`/`ddr t113-s3`):
  <https://bbs.aw-ol.com/topic/1279/t113-s3-rt-thread-smp%E9%80%82%E9%85%8D%E7%AC%94%E8%AE%B0/1>
- Linux kernel `kexec_load(2)` manpage (returns `ENOSYS` when `CONFIG_KEXEC=n`):
  <https://man7.org/linux/man-pages/man2/kexec_load.2.html>
- Buildroot `package/kexec/Config.in` — `BR2_PACKAGE_KEXEC` (kexec-tools userland).
