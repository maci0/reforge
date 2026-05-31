# ReForge — Full From-Scratch Firmware for FlashForge Adventurer 5M / 5M Pro

**Status:** Design / brainstorming output
**Date:** 2026-05-31
**Target hardware:** FlashForge Adventurer 5M (Pro) — Allwinner T113-S3 (sun8iw20, Cortex-A7 dual, `armv7l`), 128 MB RAM, 7.28 GiB eMMC. Two satellite MCUs (mainboard + eboard) running Klipper firmware.

---

## 1. Goal & Scope

Build a **complete, from-scratch firmware** for the AD5M/Pro using a *fresh* upstream Buildroot tree (not a fork), bundling the **latest pinned** Klipper (host + MCU), Moonraker, Mainsail, and GuppyScreen, plus the AD5M-specific bug-fixes and plugins proven by the prior mods (xblax `flashforge_ad5m_klipper_mod`, ghzserg `zmod`, DrA1ex `forge-x`).

The project is named **ReForge**.

### Non-goals (v1)

- No cloud / telemetry of any kind (NetEase IM, VoxelShare, MQTT, OSS uploads are actively blocked).
- No KlipperScreen, no Fluidd (see §4 decisions).
- No bleeding-edge HEAD tracking — everything pinned (§3).

### Key prior-art facts this design relies on (from `fw-analysis/` + `forge-x/docs/FIRMWARE_5x_COMPAT.md`)

- Stock OTA `.tgz` = plain tar of xz sub-packages (`kernel` / `control`=MCU / `software` / `library`) + `flashforge_init.sh` installer. **No signature check.**
- Kernel + MCU firmware are **byte-identical 3.1.3 → 5.1.4**; only the stock Qt app and the cloud SDK changed across the 5.x bump.
- **Klipper is never shipped in the OTA** — it lives in the eMMC rootfs (`/opt/klipper`). This is why userland mods survive stock version bumps.
- Stock kernel = vendor sunxi **BSP Linux 5.4.61** (confirmed on the live unit: `uname -a` → `5.4.61 ... armv7l`). It drives the RGB-LCD via `/dev/fb0` (stock writes splash bitmaps there).
- eMMC layout (live probe): `p1` 34 MB, `p2`/`p3`/`p5` 1 MB each, `p4` 35 MB, `p6` ~1.25 GB (`/opt` rootfs, ext4 `/dev/root`), `p7` ~6.2 GB (`/data`, ext4).

---

## 2. Architecture & Layer Boundaries

ReForge is three independently-buildable, independently-testable layers plus packaging/recovery. The hard boundary rule: **the upstream Buildroot submodule is never patched.** All board-specific work lives in our `BR2_EXTERNAL` tree, which is what keeps "fresh upstream Buildroot" honest rather than a fork.

```
reforge/
├── br-external/              BR2_EXTERNAL tree (our packages + board defconfig)
│   ├── board/reforge/        T113-S3 bringup: genimage cfg, post-build/post-image,
│   │                           fstab, kernel defconfig fragment, OUR device tree
│   ├── configs/              reforge_defconfig + variant fragments (lite, guppyscreen)
│   ├── package/              klipper moonraker mainsail guppyscreen
│   │                           ff-ad5m-audio ff-ad5m-backlight (+ component patches)
│   ├── external.desc / external.mk / Config.in
├── buildroot/                PINNED upstream Buildroot (git submodule @ release tag)
├── pins.lock                 single source of truth for all component SHAs/tags
│                               (Buildroot, kernel, U-Boot, Klipper, Moonraker,
│                                Mainsail, GuppyScreen) — the reproducibility anchor
├── kernel/                   Mainline-LTS kernel tree refs + OUR display-driver port
│   ├── patches/              ported T113 RGB-LCD / TCON / panel DT (see §6)
│   ├── defconfig             reforge_t113_defconfig
│   └── dts/                  sun8i-t113s-flashforge-ad5m.dts
├── uboot/                    Upstream mainline U-Boot refs + OUR board bringup
│   ├── defconfig             reforge_t113_uboot_defconfig
│   └── dram/                 DRAM/DDR3 timing params + SPL/eMMC boot config
├── mcu/                      Klipper MCU fw build (mainboard+eboard) + v11 fallback blobs
├── overlay/                  rootfs overlay: init scripts, /etc/hosts cloud-block,
│                               chroot / dual-boot glue, OTA client
├── packaging/                .tgz builder (flashforge_init.sh-compatible)
│                               + genimage full .img (P4) + checksums
├── recovery/                 golden eMMC dump tooling + stock-restore .tgz + runbook
└── docs/                     this spec, bringup notes, recovery runbook, gate checklists
```

Each layer has one job and a defined artifact:

| Layer | Input | Output |
|---|---|---|
| `br-external` rootfs | pinned sources + defconfig | `rootfs.tar` / `rootfs.ext4` |
| `kernel` | mainline-LTS + our patches/DT | `Image`/`uImage` + `.dtb` |
| `mcu` | pinned Klipper commit + board configs | `mainboard.bin`, `eboard.hex` |
| `packaging` | the above | `reforge-<ver>.tgz`, `reforge-<ver>.img`, checksums |
| `recovery` | live device | `golden-<id>.img.gz`, restore proof |

---

## 3. Components & Version Policy

All upstream components are carried as **pristine source + numbered `.mk` patches** (the Buildroot/xblax model). **No vendored forks.** Versions are **pinned to recent commits/tags** for reproducible builds; bumps are deliberate (CI may propose re-pins, a human merges). The exact SHAs/tags for every component live in a single tracked **`pins.lock`** at the repo root — it is the reproducibility anchor; the table below is descriptive, `pins.lock` is authoritative.

| Component | Pin | Source | Notes |
|---|---|---|---|
| Buildroot | release tag (≥ **2025.02**) submodule | buildroot/buildroot | Never forked. ≥6.12 DTS-dir support needed (§6). |
| Linux kernel | **latest mainline LTS** (6.12.x line at time of writing), pinned | torvalds / stable | Built via `BR2_LINUX_KERNEL_CUSTOM_VERSION` or `CUSTOM_REPO`. **Requires our display-driver port (§6).** |
| U-Boot | **upstream mainline**, pinned (≥ 2024.01) | u-boot/u-boot | T113 supported upstream. Board DRAM/DDR + eMMC/SPL params in `board/reforge` (§6). No vendor BSP bootloader. |
| Klipper (host klippy) | pinned recent `master` commit | klipper3d/klipper | AD5M fixes as `.mk` patches. Build `chelper` with Cortex-A7/NEON flags (§10.6). |
| Klipper (MCU fw) | **same commit as host** | klipper3d/klipper | Host↔MCU protocol must match → one tree. |
| Moonraker | pinned commit | Arksine/moonraker | Port 7125. |
| Mainsail | pinned release tag | mainsail-crew/mainsail | **Single network web UI** (§4). |
| GuppyScreen | pinned commit | ballaswag/guppyscreen | Native LVGL on-device UI (§4). Port xblax's 3 build patches. |
| ff-ad5m-audio / -backlight | pinned | PyPI | Buzzer + LCD backlight HW glue. |

### AD5M-specific patches (ported, each with one-line provenance comment)

- `klipper/0001-relax-TRSYNC_TIMEOUT-ffad5m.patch` — fixes E0011 comms timeout.
- `klipper/0002-lookahead-flush-time.patch` — fixes E0017 move-queue overflow.
- `klipper/0003-unicode-gcode-objectnames.patch` — non-ASCII object names.

### klippy extensions (dropped in, not patches)

`resurrection.py` (power-loss recovery), `load_cell_tare.py` + bed-collision protection (nozzle-collision failsafe), `md5_checker.py` (gcode MD5 validation), `gcode_shell_command.py`, KAMP (adaptive meshing / smart parking).

---

## 4. Locked Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Build base | **Fresh upstream Buildroot + own `BR2_EXTERNAL`** | Max control; xblax fork consulted only as HW-bringup reference. |
| Kernel | **Latest mainline LTS**, with **our ported display driver** | Modern kernel; accept the panel-port cost (§6). |
| Bootloader | **Upstream mainline U-Boot** (≥ 2024.01) | Mainline supports T113; no vendor BSP bootloader. Board DRAM/DDR + eMMC params matched in our board dir (§6, §10). |
| Network web UI | **Mainsail only** | Broader feature set + higher velocity than Fluidd; no reason to ship two static bundles. |
| On-device UI | **GuppyScreen** (native LVGL) | Best fit for 128 MB RAM vs KlipperScreen (GTK/Python OOM risk). |
| MCU firmware | **Both, switchable** — default latest↔latest; **v11 emergency fallback** | `UPDATE_MCU VARIANT=latest\|v11`. Single latest host klippy; v11 is emergency-only, not a co-equal daily mode. |
| Install | **Stock `.tgz` (primary)** + **full `.img` (recovery/clean, P4)** | `.tgz` stays inside the recovery envelope; `.img` deferred behind rehearsed un-brick. |
| Version tracking | **Pinned-recent** | Reproducible images; deliberate bumps. |

---

## 5. MCU Firmware (both-switchable)

Two MCUs: **mainboard** (motion/heaters) and **eboard** (toolhead/extruder). Stock = Klipper v11. ReForge default = latest (matched to host commit), with v11 as an emergency fallback.

```
mcu/
├── configs/
│   ├── mainboard/  Klipper menuconfig defconfig (arch, comms, pins)
│   └── eboard/     defconfig for toolhead board
├── fallback/
│   ├── mainboard-v11.bin   carved from stock control-2.2.3 blob (in fw-analysis/)
│   └── eboard-v11.hex
└── flash/
    ├── flash_mcu.sh        host-side flasher (stock flasher tools as reference)
    └── UPDATE_MCU.cfg      gcode macro: VARIANT=latest|v11
```

- Latest `.bin`/`.hex` built from the **same pinned Klipper commit** as host klippy.
- `UPDATE_MCU VARIANT=latest|v11` reflashes both boards and restarts; on-boot `S54mcu_update` auto-flashes if installed-fw-hash ≠ target.
- **Safety:** MCU reflash is host-side and stays inside the recovery envelope — a stock `.tgz` reflash restores v11. Mitigation against interrupted writes: `flash_mcu.sh` does write-verify-readback and refuses to proceed on mismatch; the v11 blob is always present on disk.
- **Single latest host klippy.** `VARIANT=v11` is a downgrade-MCU emergency path; it is not maintained as a co-equal daily configuration. **Clarification for planning:** the design intent is that v11 mode is a **pure MCU reflash** with the *same* host klippy — NOT a runtime-conditional host build. If bench testing shows latest host klippy cannot talk to v11 MCU without host-side changes, the forge-x v11 host-patches are applied as **optional runtime-loaded** extras toggled by the variant, never as a second host tree. (Planner: confirm which of these two is needed early — it affects the flasher + init scripts.)

---

## 6. Kernel & Display-Driver Port (highest-risk workstream)

Buildroot imposes no kernel-version ceiling (`BR2_LINUX_KERNEL` accepts built-in mainline/LTS choices, a custom version string, a tarball URL, or a git repo+commit). The constraint is the **SoC + board**, not Buildroot.

### SoC support status (T113-S3, sun8iw20, D1 sibling)

- Mainline Linux supports the SoC core since ~**v6.4**; mainline U-Boot since **2024.01**.
- **RGB-LCD parallel panel + DVP camera are NOT in mainline** — only the vendor **5.4 BSP** drives this board's display. LVDS/TCON/D-PHY work is still in progress upstream.

### Reference sources for the port

The vendor **5.4 BSP is an explicit reference** for both the display port and U-Boot bringup — we read parameters out of it rather than guessing:

- **Stock DTB** (`sunxi.dtb` from `kernel-2.1.6.tar.xz`) and any `.fex`/`sys_config` — decompile (`dtc`) for panel timings, TCON/DE wiring, backlight PWM, GPIO mux.
- **Vendor BSP kernel source** (Allwinner/linux-sunxi `sun8iw20` 5.4 tree) — the actual panel/TCON/DE2.0 driver implementation to translate into the mainline DRM idiom.
- **Stock boot0 / SPL + U-Boot env** in the golden eMMC dump (`p1`/`p2` region) — **DRAM/DDR3 timings, rank/size, eMMC boot params** to seed our mainline U-Boot DRAM config (§10.4).
- These are *reference for parameter extraction*, not code we ship — ReForge ships mainline U-Boot + mainline-LTS kernel with our own DT/driver derived from them.

### Decision: ship **latest mainline LTS** and **port the display driver ourselves**

This is the defining risk of the project. Workstream:

1. **Extract panel parameters** from the vendor 5.4 BSP / device-tree (`.fex`/DTS): panel timings (clock, h/v front-porch, back-porch, sync), bus format (RGB888/RGB666), TCON-LCD config, backlight (PWM) wiring, reset/enable GPIOs.
2. **Wire the mainline DRM path:** `sun4i-drm` + the sun8i display-engine (DE2.0) mixer + TCON-LCD → RGB/DPI output, with a `panel-dpi` / `panel-simple` (or a small custom panel driver) node carrying the extracted timings, in our DT (`kernel/dts/sun8i-t113s-flashforge-ad5m.dts`).
3. **Provide `/dev/fb0`** (DRM fbdev emulation) so GuppyScreen's framebuffer path works unchanged.
4. **Validate** on bench against a known image before trusting on-printer.
5. **DVP camera = out of scope for v1** (later port; stock-mod patched ustreamer path may bridge in the interim).

### Board-tailored kernel config (requirement)

`reforge_t113_defconfig` is a **board-minimal** kernel config, not a generic sunxi defconfig — tuned for *this* board to minimize RAM/flash footprint (128 MB budget) and boot time:

- Start board-minimal and enable only what the AD5M Pro actually uses; **cross-check against the captured stock `.config`** (`docs/board-notes/stock-kernel-config-5.4.61.txt.gz`, the exact `/proc/config.gz` from the live unit, 1017 `CONFIG_` lines) — it is the authoritative list of subsystems/drivers this hardware needs.
- Drivers to keep: T113-S3 core, eMMC (`mmcblk`), the console + MCU UARTs (`ttyS3` console @ `0x05000000`, plus the two MCU serial links), USB, RGB-LCD/DRM (the ported panel above), RTL8821CU wifi via **mainline `CONFIG_RTW88_8821CU`** (`rtw88_8821cu`/`rtw_8821c`/`rtw_usb`/`rtw_core`) + BT via `btusb`+`btrtl` — **no out-of-tree module needed** (rtw88 8821cu is mainline since 6.2, solid by 6.12; station-mode only, which is all a printer needs), ethernet.
- Strip: unrelated SoC/board support, unused buses/filesystems/netfilter, debug/tracing not needed in production, modules for absent peripherals. Target a small monolithic image (stock is essentially monolithic — one out-of-tree module).
- Honor the board's boot/partition reality from `docs/board-notes/`: `cma=16M`, `dsp0@p5` (HiFi4 DSP firmware) preserved, `androidboot.dramsize=128`, display reserve. The full cmdline + partition map are recorded there.

This is a Plan 5 (P4) deliverable; the reference data is already captured (P0).

### Fallback if the port stalls

The full-image (P4) display port is decoupled from getting the Klipper stack working:

- **P1–P3 ride the stock 5.4.61 kernel** (we ship no kernel) — GuppyScreen already works on the stock fbdev, so the screen is functional throughout early phases regardless of the port.
- If the mainline panel port is not ready when P4 begins, P4 ships in one of two reduced forms: **(a)** full image on the **vendor 5.4 BSP kernel** (display works, kernel old), or **(b)** **headless mainline** image (modern kernel, no on-device screen) — and the panel port continues as its own track.

So "latest Klipper" is unconditional; "latest *kernel with working screen*" is gated on the display port, with safe fallbacks either way.

> **Note for planning:** the display-driver port is effectively its own sub-project (DE2.0 mixer + TCON-LCD + panel DT + DRM fbdev). It should be sized and tracked as a **separate track-level plan**, not as a single P4 line-item. P1–P3 do not depend on it.

---

## 7. Partition, Install & Recovery

### eMMC layout

Respected as-is in P1–P3 — **no repartitioning, no kernel/bootloader writes.** `p6` = `/opt` rootfs, `p7` = `/data`. Klipper at `/opt/klipper`.

### (a) `.tgz` USB installer — primary, P1–P3

Stock-format: plain tar of xz sub-packages + `flashforge_init.sh`-compatible installer (with per-subpackage `md5sum.list`, same flow as stock — confirmed no signature check).

```
reforge-<ver>.tgz
├── software-<ver>.tar.xz   ReForge rootfs overlay (klippy, moonraker, mainsail,
│                             guppyscreen, init scripts) → /opt + /data/.reforge
├── control-<ver>.tar.xz    MCU fw (latest + v11 fallback) + flasher
├── library-<ver>.tar.xz    runtime libs — NO NetEase / cloud SDK
├── flashforge_init.sh      installer
└── md5sum.list
```

- **No `kernel-*.tar.xz`** → stock kernel/DTB/bootloader untouched → soft-brick fully recoverable by a stock `.tgz` reflash. This is the safety core of early phases.
- Installs to `/data/.reforge`, mounts over `/data`, chroots into the fresh Buildroot rootfs (xblax/forge-x pattern).
- `/etc/hosts` cloud-block applied on every boot — full host set per `FIRMWARE_5x_COMPAT.md` (FlashForge OTA/MQTT/VoxelShare/qvs/polar3d + NetEase IM/Yunxin backbone).
- **Dual-boot** to stock retained (toggle), since the stock stack remains on disk.

### (b) Full eMMC `.img` — recovery / clean install, P4 only

`genimage`-built **upstream mainline U-Boot** + (mainline-LTS) kernel + rootfs. **Gated** on: golden eMMC dump captured **and** restore rehearsed via eMMC reader. This is the only artifact that touches bootloader/kernel. Replacing the stock vendor bootloader with mainline U-Boot is the single highest-brick-risk step in the project (a bad SPL/DRAM init = no-boot, recoverable only via the eMMC reader) — see §10.4.

### Recovery (`recovery/`) — built FIRST, before any flash

The live unit's recovery profile is **eMMC dump/reader + stock `.tgz` reflash only — no FEL, no UART.** Therefore a bad bootloader/kernel = hard brick recoverable only by physically reading/writing eMMC. Mitigations:

1. `dump_golden.sh` — `dd if=/dev/mmcblk0` of the **full 7.28 GiB eMMC**, piped over SSH and gzipped locally (nothing stored on the space-limited device). **Gate-zero deliverable.** (The live unit already runs forge-x, so this golden image is a known-good, *booting* restore point — not pristine stock, which is acceptable and arguably preferable as a recovery baseline.)
2. Verify the dump is restorable via the eMMC reader (bench rehearsal, documented).
3. Keep a known-good **stock `.tgz`** staged on USB = one-step soft-brick restore.
4. Runbook: soft-brick → stock `.tgz`; hard-brick → reader-restore golden dump.

### Brick-risk ladder

| Phase | Touches | Recoverable by |
|---|---|---|
| P1–P3 (`.tgz`, no kernel) | rootfs / userland only | stock `.tgz` reflash ✅ |
| P3.5 MCU reflash | MCU fw | stock `.tgz` (restores v11) ✅ |
| P4 (full `.img`) | u-boot + kernel + rootfs | eMMC reader + golden dump ⚠️ |

Everything dangerous is quarantined to P4, behind the rehearsed reader-restore.

---

## 8. Milestones / Phasing

Each phase is independently shippable and stays inside the recovery envelope until P4.

| Phase | Deliverable | Touches device | Gate to exit |
|---|---|---|---|
| **P0 Recovery** | Golden eMMC dump (in progress) + staged stock `.tgz` + restore runbook | read-only | Dump captured; reader-restore rehearsed before any P3 flash |
| **P1 Build system** | Fresh Buildroot `BR2_EXTERNAL`, `reforge_defconfig`, rootfs → `rootfs.tar`; boots in `qemu-arm` where feasible | none | Reproducible clean rootfs build in CI |
| **P2 Core stack** | Latest klippy + Moonraker + Mainsail packaged; GuppyScreen package; init scripts; `/etc/hosts` block | none | Services start in chroot / qemu |
| **P3 `.tgz` install** | Stock-format `reforge-<ver>.tgz`, installs to `/data/.reforge`, chroots, **stock kernel untouched** | rootfs/userland | First on-device flash; soft-brick recoverable; klippy connects to **stock v11 MCU**, Mainsail + GuppyScreen up, zero cloud callouts |
| **P3.5 MCU** | Latest mainboard+eboard fw; `UPDATE_MCU VARIANT=latest\|v11`; write-verify flasher | MCU fw | Latest host↔latest MCU verified; v11 fallback proven |
| **P4 Full image** | `uboot/` upstream U-Boot + `kernel/` mainline-LTS + **ported display driver**; `genimage` `reforge.img` | **u-boot+kernel** | golden-dump reader-restore **rehearsed first**; U-Boot SPL/DRAM bench-validated; display port validated (or documented fallback per §6) |

First on-device flash = **P3**, only after P0 verified. P4 (the only kernel/bootloader touch, plus the display-port risk) is last and double-gated.

**P4 variant-selection gate (explicit decision, not implicit).** Before P4 ships, choose its end-state deliberately, each with its own done-criteria:

| P4 variant | Ships when | Trade-off |
|---|---|---|
| **P4-full** — mainline U-Boot + mainline-LTS kernel + ported display | display port validated on bench | the goal; highest effort |
| **P4-bsp** — mainline U-Boot + **vendor 5.4 BSP kernel** + working screen | display port stalls but full image wanted | screen works, kernel old |
| **P4-headless** — mainline U-Boot + mainline-LTS kernel, **no on-device screen** | modern kernel wanted before port lands | no GuppyScreen on device (web UI only) |

The choice is a recorded checkpoint with sign-off — P4 does not "fall into" a variant by default.

---

## 9. Testing & Validation (no-flash-until-mature)

The live printer is held back from flashing until the image is mature and recovery is proven.

- **CI / static (P1–P2):** reproducible Buildroot build; `qemu-arm` boot smoke-test of rootfs; klippy import + config-parse; Moonraker unit start; MCU configs compile.
- **Chroot test (P2–P3):** install the `.tgz` into a chroot on a Linux host (forge-x pattern); start klippy/moonraker against a virtual/dummy MCU; confirm services + Mainsail serve — all before any device flash.
- **On-device (P3+, gated):** flash `.tgz`; verify klippy ↔ **stock v11 MCU first** (lowest-risk combo); Mainsail reachable; GuppyScreen renders on stock fbdev; cloud-block verified (`tcpdump`/`netstat` show no egress to blocked hosts). Only then P3.5 (MCU→latest).
- **Kernel/display (P4):** bench-validate the ported panel against a known framebuffer image before on-printer use.
- **Recovery drill (before P4):** deliberately restore the golden dump via the reader on the bench and confirm boot — prove the un-brick path *before* trusting it.
- **Acceptance:** each phase has a written checklist in `docs/`; each gate is signed off before the next phase starts.

---

## 10. Open Questions / Risks

1. **Display-driver port (§6)** — highest risk. Effort is uncertain until the BSP panel parameters are extracted and the mainline DE2.0/TCON path is wired. Fallbacks defined, but the "mainline-LTS + working screen" goal could slip.
2. **128 MB RAM** — the whole stack (klippy + Moonraker + Mainsail static serve + GuppyScreen) must fit. GuppyScreen chosen specifically for this; needs measurement under load (the `Timer too close` / OOM class of failures the prior mods hit).
3. **MCU board configs** — mainboard/eboard pin maps must be reverse-engineered/confirmed against the RE'd configs in xblax `mcu_configs` before trusting a latest-fw flash.
4. **Upstream U-Boot for P4** — mainline U-Boot (≥2024.01) supports T113, but the board's SPL/DRAM init (DDR3 timings, rank/size) and eMMC boot path must be matched to *this* board before it will boot. A wrong SPL = dead unit recoverable only via the eMMC reader, so U-Boot is bench-validated against the golden dump and rehearsed before it ever touches the printer. The stock vendor bootloader is kept in the golden image as the restore baseline.
5. **Golden dump is forge-x state, not stock** — fine as a booting restore point; if a pristine-stock baseline is also wanted, capture a stock `.tgz` separately.
6. **klippy CPU / Python interpreter overhead** — open investigation, low priority. klippy's real-time hot path is **already native C** (`klippy/chelper/*.c` → shared lib via ctypes; stepcompress, iterative solver, `trapq`), with the MCU firmware doing the rest; Python is glue (config, gcode parse, reactor). Therefore:
   - **First lever (do it, Plan 2):** build `chelper` with Cortex-A7/NEON-tuned flags (`-O2 -mcpu=cortex-a7 -mfpu=neon-vfpv4`) via the Buildroot toolchain. Free, targets the actual hot path.
   - **PyPy:** rejected — JIT would speed the Python glue but its RAM footprint is too large for 128 MB (OOM risk). CPython stays (lowest RAM; RAM is the binding constraint, not raw Python speed).
   - **AOT-compile klippy (Nuitka/Cython/mypyc):** deferred. High effort + fragile (Klipper relies on dynamic `importlib` of `extras/` and the runtime reactor) for a marginal steady-state gain, since the hot path is already C. Revisit only if gcode-parse CPU is *measured* as a real bottleneck.
   - Note: the AD5M `Timer too close` / `Move queue overflow` errors are scheduling/RAM-pressure issues fixed by the forge-x patches already in §3 (TRSYNC_TIMEOUT, lookahead flush), **not** interpreter-speed issues — compiling Python would not address them.
7. **Moonraker — keep upstream, do NOT rewrite (open investigation, measure-then-trim).** Moonraker is the API server (HTTP REST + WebSocket JSON-RPC on :7125) that bridges klippy's raw Unix socket to every frontend — Mainsail, **GuppyScreen**, mobile apps, OctoEverywhere all speak the Moonraker API. It is the de-facto, under-specified API contract ("the spec is what Moonraker does"). A rewrite would have to reproduce that whole surface (file metadata/thumbnails, history lmdb, job queue, update manager, power, webcams, auth, spoolman, notifications) bit-for-bit or frontends break subtly, then chase upstream forever — high risk, perpetual maintenance, **unproven** RAM gain (much of the footprint is data it must still hold). **Measured on the live unit (forge-x, STOCK-screen):** klippy RSS **21.4 MB**, Moonraker **17.2 MB**, stock `firmwareExe` Qt UI **10.5 MB**; MemTotal 108 MB, ~30 MB zram swap already in use (RAM *is* the binding constraint). Moonraker (17 MB) is *smaller* than klippy (21 MB), so it is not even the largest target. The real, safe RAM relief — proven by the prior mods — is elsewhere: **drop the stock Qt UI** (10.5 MB freed in ReForge, which doesn't run it), use **GuppyScreen** (native LVGL C++, *no Python*) instead of a Python screen, reduced-memory video streamer, and **disable unused Moonraker components** (`update_manager`, `spoolman`, `announcements`, `notifier`, extra sensors — config-driven, near-zero risk). Plan: ship upstream Moonraker trimmed, **measure RSS on-device under load**, and only if it is then the binding constraint, treat a scoped lighter API server (implementing exactly the Mainsail+GuppyScreen subset; a Rust/Go reimplementation) as its **own long-term R&D track**, never a v1 commitment.

---

## 10b. RAM budget & memory optimization (128 MB is the binding constraint)

Measured on the live unit (forge-x): MemTotal **108 MB**, ~**30 MB swap already in use**. Swap is a plain **64 MB eMMC swapfile** (`/data/.mod/.forge-x/root/swap`) — *uncompressed, flash-backed*. klippy RSS 21 MB (Python 3.7), Moonraker 17 MB (Python 3.11, a *different* interpreter), stock Qt `firmwareExe` 10.5 MB. No `MALLOC_*` tuning; swappiness 60; ext4 rw rootfs.

**The stock 5.4.61 kernel has NO `CONFIG_ZRAM`/`ZSMALLOC`/`ZSWAP`/`KSM`/`SQUASHFS`** (verified against the captured `/proc/config.gz`) — only the zstd/lzo crypto compressors. That is *why* forge-x uses an eMMC swapfile: on the stock kernel it has no compressed-swap option. This splits ReForge's memory work by phase:

### P1–P3 (riding the stock kernel — available now)
- **Single shared `python3`** for klippy + Moonraker (one `libpython`, COW-shared read-only pages) — biggest available win (Plan 2, §10.7).
- **`MALLOC_ARENA_MAX=2`** (or 1) in the klippy + Moonraker init env — glibc otherwise spawns up to `8×CPU` per-thread arenas, bloating RSS. Free RSS cut. (Plan 2 init scripts.)
- **Lazy numpy** — only loaded for shaper calibration, kept out of steady-state RSS (already Klipper's behavior).
- **Strip + precompile Python** (`.pyc`, drop unused stdlib modules).
- **Drop the stock Qt UI** (10.5 MB; ReForge doesn't run it) + **GuppyScreen** (C++/LVGL, no Python).
- **Trim Moonraker components** (§10.7).

### P4+ (our own mainline-LTS kernel — unlocks compressed memory)
- **zram + zstd**: replace the eMMC swapfile with compressed-RAM swap (~2–3× on anon pages, no flash wear, far faster than eMMC swap) + high `vm.swappiness`. **The headline win the stock kernel cannot provide.** Enable `CONFIG_ZRAM`, `CONFIG_ZSMALLOC`, `CONFIG_CRYPTO_ZSTD` in `reforge_t113_defconfig`.
- **squashfs + zstd read-only rootfs**: clean, reclaimable file pages + smaller flash. Enable `CONFIG_SQUASHFS` (+zstd).
- **KSM**: option, but marginal (COW already shares the Python pages) and costs A7 CPU — **likely skip**; revisit only if measured.
- **jemalloc `LD_PRELOAD`** for long-running Moonraker (fragmentation) — optional, measure first.

Discipline throughout: **measure RSS on-device under load before optimizing** — the binding cost may not be where intuition says (cf. §10.6, §10.7).

## 11. Provenance

- `forge-x/docs/FIRMWARE_5x_COMPAT.md` — stock 5.x analysis, OTA format, cloud host list, MCU v11 bug→fix table.
- `fw-analysis/x-5.1.4/flashforge_init.sh` — stock installer flow (the `.tgz` format we mirror).
- `xblax/` (`flashforge_ad5m_klipper_mod`) — Buildroot `BR2_EXTERNAL` structure, package patches, MCU board configs — **HW-bringup reference only** (we do not fork it).
- `zmod/` (ghzserg) — `UPDATE_MCU` reflash pattern.
- Live unit probe (`192.168.0.158`, hostname `kunos`) — kernel `5.4.61 armv7l`, eMMC layout, current forge-x install.
- **Vendor 5.4 BSP** (stock `sunxi.dtb`, Allwinner/linux-sunxi `sun8iw20` kernel source, stock boot0/SPL in the golden dump) — **parameter-extraction reference** for the mainline display-driver port and U-Boot DRAM/SPL bringup (§6). Reference only; not shipped.
</content>
</invoke>
