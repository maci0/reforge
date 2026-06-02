# ReForge Plan 3 — `.tgz` Installer, qemu Test Harness & Stock-UI Spike

**Status:** Implemented (branch plan3-installer) — installer + qemu harness + stock-UI spike (GO/Option-A)
**Date:** 2026-06-01
**Depends on:** Plan 1 (Buildroot foundation, merged), Plan 2 (core stack, merged — `output-guppy` full-stack rootfs).
**Parent spec:** `docs/specs/2026-05-31-reforge-firmware-design.md` (§7 install/recovery).

> **CORRECTION (2026-06-02 hardware trial — supersedes two premises below):**
> 1. *"klippy will not connect to the stock v11 MCU / driving the printer needs Plan 3 +
>    Plan 4 together"* is **WRONG**. ReForge's vanilla Klipper **drives the stock v11 MCUs**
>    (both `mcu` + `eboard` connect, real temps, klippy `ready`) with no MCU reflash. Plan 4
>    only restores the version-locked **adxl345/input-shaper calibration** (`query_adxl345`
>    format changed v11→v13). The host↔MCU link itself works on stock firmware.
> 2. The stock firmwareExe config uses **vanilla Klipper sensors** (`MAX31856` load cell,
>    `MAX31865` TVOC, `[adxl345]`, `[probe] pin:!PB4`) — see `reference/ad5m-factory-config/`.
>    `flashforge_loadcell`/`flashforge_tvoc` (referenced in §6.2 / spike) are **xblax's v13
>    custom modules**, NOT the stock dependency. Full analysis:
>    `docs/2026-06-02-ad5m-mcu-firmware-and-config.md`.

---

## 1. Goal & Scope

Produce the **flashable ReForge installer** (stock-format `.tgz`) and **validate it entirely without flashing the printer**, using a qemu-system-arm test harness. Plus a **feasibility spike** for running the stock FlashForge touchscreen UI (`firmwareExe`) as a ReForge screen mode against upstream klippy.

### In scope
- The `reforge-<ver>.tgz` userland installer (overlay-on-stock, `flashforge_init.sh`-compatible).
- On-device boot/overlay/chroot glue, screen-mode selector, dual-boot, cloud-block, uninstall.
- A qemu-system-arm harness: a test-only virt kernel + the stock rootfs (from the golden dump) + ReForge rootfs, with a framebuffer — to test install, boot, GUI render, and GUI↔klippy.
- Stock-UI spike: extract + analyze + live-qemu-test `firmwareExe` vs upstream klippy → REPORT + decision.

### Explicitly OUT of scope (locked decisions)
- **No device flash.** Plan 3 builds + validates the installer; the real on-device flash is deferred until the eMMC-reader golden-restore is rehearsed.
- **MCU firmware** — the `control-` subpackage is an **empty reserved stub**. Building/flashing matching upstream MCU firmware is **Plan 4**. Consequence: a flashed ReForge boots + is web-reachable, but **klippy will not connect to the stock v11 MCU**, so *driving the printer needs Plan 3 + Plan 4 together*.
- **Full motion/print simulation** in qemu — not feasible without real hardware; the harness proves install/boot/web/GUI-render/GUI↔klippy-connect, not motion.
- Full implementation of STOCK screen mode — Plan 3 only does the **spike**; implementation is decided from its findings.

### Key constraints carried from the parent spec
- Stock OTA `.tgz` = plain tar of xz subpackages + `flashforge_init.sh`; **no signature check**.
- Overlay model: install to `/data/.reforge`, mount over `/data`, chroot — **stock kernel/partition/`firmwareExe` untouched** ⇒ soft-brick recoverable by stock `.tgz` reflash; dual-boot + stock-UI possible.
- Recovery profile: eMMC dump/reader + stock `.tgz` reflash only; **no FEL/UART**. Golden dump already captured (`recovery/`).

---

## 2. Architecture & Boundaries

Three independent units, **none touch the device**:

```
reforge/
├── packaging/                      builds the flashable installer (output: one .tgz)
│   ├── build-tgz.sh                assembles reforge-<ver>.tgz from output-guppy
│   ├── flashforge_init.sh          installer (stock-compatible; overlay+chroot)
│   └── tgz-layout/                 subpackage staging
│       ├── software-<ver>.tar.xz   ReForge full-stack rootfs + install glue + init scripts
│       ├── library-<ver>.tar.xz    runtime libs, NO NetEase/cloud SDK
│       └── control-<ver>.tar.xz    EMPTY STUB (MCU reserved for Plan 4)
├── install/                        on-device boot glue (shipped inside software-)
│   ├── (Plan-2 init scripts: S00cloudblock … S35zram … S60klipper …)
│   ├── reforge-boot                chroot launcher (mount /data, chroot /data/.reforge, start init)
│   ├── screen-mode selector        HEADLESS (default) / GUPPY / STOCK(spike)
│   └── dual-boot / SKIP_MOD glue   (forge-x pattern: boot untouched stock)
├── validation/                     proves the installer WITHOUT flashing
│   ├── loopback-install-test.sh    ext4 loopback = fake /data → run installer → assert overlay+chroot
│   └── qemu-harness/               the emulated test bed (§4)
│       ├── kernel/                 test-only virt armv7 kernel (Tina source → virt; never shipped)
│       ├── stock-rootfs/           stock p6 extracted from golden dump → bootable ext4
│       └── *.sh                    boot + update-process + render tests
└── spike-stockui/                  feasibility investigation (no device, no proprietary commits)
    ├── extract.sh                  firmwareExe + Qt deps from fw-analysis stock images
    ├── analyze.sh                  ldd/strings/RE → klippy socket, gcode/objects, FF modules
    └── REPORT.md                   works/breaks vs upstream klippy → go/no-go decision
```

**Boundary rules:**
- **packaging** only emits `reforge-<ver>.tgz`; never flashes.
- **validation** runs entirely on the Linux host (loopback ext4 + chroot + qemu-system-arm).
- **spike** is read-only analysis of stock binaries we already hold (`fw-analysis/`); commits a REPORT + scripts, **never the proprietary `firmwareExe`**.
- the **`control-` MCU slot is an empty stub**; Plan 4 fills it without changing the installer.

Each unit is independently testable: packaging → a `.tgz`; validation → pass/fail; spike → a report.

---

## 3. The Installer

**`reforge-<ver>.tgz`** (stock tar format) contains:
| Subpackage | Contents |
|---|---|
| `software-<ver>.tar.xz` | ReForge full-stack rootfs (from `output-guppy`) + `flashforge_init.sh` + boot/init glue |
| `library-<ver>.tar.xz` | runtime libs — **no NetEase/cloud SDK** |
| `control-<ver>.tar.xz` | **empty stub** (MCU reserved, Plan 4) |
| `md5sum.list` | per-subpackage (same as stock; no signature check) |

**Install flow** (`flashforge_init.sh`, host-side, run by the stock USB updater; mirrors zmod/forge-x):
1. arch/PID sanity (`armv7l`, `Adventurer5M`/`Pro`, PID 0023/0024) — bail on mismatch.
2. extract subpackages to **`/data/.reforge`** — **never touches `/opt`, stock rootfs, kernel, partitions**.
3. install boot hook (`reforge-boot`): on boot, mount over `/data`, `chroot /data/.reforge`, start ReForge init chain.
4. screen-mode selector persisted in config: **`HEADLESS` (default, safest)** / `GUPPY` / `STOCK` (pending spike).
5. **dual-boot**: a `SKIP_MOD` USB marker / setting → boot skips ReForge → untouched stock runs (forge-x pattern).
6. `/etc/hosts` cloud-block every boot.

**Reversibility:** stock partition/kernel/`firmwareExe` untouched ⇒ uninstall = remove `/data/.reforge` + boot hook (`reforge-uninstall.tgz`), or flash a stock `.tgz`. Soft-brick → stock reflash.

**Carried caveat (in installer docs):** without Plan 4's MCU firmware, ReForge boots + serves Mainsail/Moonraker but **klippy won't connect to the v11 MCU** → no printing. P3 delivers an installable, bootable, web-reachable ReForge.

---

## 4. qemu Test Harness (the no-device test bed)

A real emulation platform so we can test install, boot, GUI render, and GUI↔klippy without the printer.

**4a. Test kernel** (`validation/qemu-harness/kernel/`, **never shipped**):
- Built from the **Tina vendor `sun8iw20` 5.4 source** (already cloned for the zram work, in-repo at `modules/zram-bsp/tina-bsp-kernel`), reconfigured for **qemu `-M virt`**: `ARCH_MULTI_V7` + virt machine + **virtio-blk/net/gpu** + **DRM/fbdev** + virtio-input/evdev. Vendor source ⇒ closest ABI match to the stock 5.4 userland.
- **`/dev/fb0` pinned to the printer's exact panel** (measured on the live unit): **800×480 visible, 32 bpp (xRGB8888), virtual 800×960 (double-buffered), mode 800x480p-67**. Implement via a fixed `simple-framebuffer` DT node at 800×480×32 (deterministic), or virtio-gpu forced with kernel `video=800x480-32` + `fbcon`/panning `virtual_y=960`. This makes firmwareExe/GuppyScreen render **pixel-identical to the real screen** (screenshots match the printer).
- **Backend note:** GuppyScreen (LVGL) drives the **fbdev** path; firmwareExe is **Qt-embedded** (qws/EGLFS-style) and may want a slightly different fb/input config. Provide both a plain fbdev `/dev/fb0` and a virtio-input/evdev touch device; expect per-app tuning in §4d/§4e.
- **Risk + fallback:** a sunxi BSP kernel may resist `virt` (same class of issue as the failed stock-`uImage` boot). If so, fall back to a **generic Buildroot armv7 virt kernel** — glibc userland is largely kernel-agnostic; we lose only vendor-driver fidelity (irrelevant under virt). The harness must work on the fallback if the vendor path stalls. The 800×480×32 fb spec applies to either kernel.

**4b. Stock-FW image** (`qemu-harness/stock-rootfs/`):
- Extract the **stock rootfs (`mmcblk0p6`) from the golden eMMC dump** → a bootable ext4 image. Stub absent hardware (MCU serials → host PTYs).

**4c. Update-process test:**
- **Minimum bar (gating):** the *filesystem-ops* update test — run the installer (`flashforge_init.sh`) against the stock rootfs's `/data` (in a chroot or a booted minimal harness rootfs under qemu) → assert ReForge lands in `/data/.reforge` + boot hook installed → boot the **ReForge** rootfs under the test kernel and confirm it comes up. This proves the install logic + ReForge boot **without** needing a full stock-firmware boot under virt.
- **Stretch:** full stock-firmware boot under qemu, then run the install end-to-end as the stock updater does (USB `.tgz` → updater → install → reboot → ReForge). Attempt it; if stock-boot-under-virt stalls (§7 risk 2), the minimum bar above is the accepted pass and full-stock-boot is deferred.
- Also test uninstall / stock reflash (filesystem-level).

**4d. Stock-UI live spike** (turns §6 from static→live):
- In the qemu stock env (virtio-gpu `/dev/fb0`), run **firmwareExe against ReForge's upstream klippy** → observe render / connect / temps-move-status / breakage. Screenshot-able evidence.

**4e. ReForge-in-qemu:** boot the ReForge rootfs under the test kernel + virtio-gpu → render **GuppyScreen**, exercise the full stack (Moonraker live API already proven in Plan 2; now with a framebuffer + simulated MCU).

**Honest hard parts:**
1. **vendor-kernel-on-virt** may force the generic-kernel fallback.
2. **MCU simulation** — klippy needs an MCU to fully start. We can get klippy *up + objects queryable* (enough to test GUI connect/render) via a stub/linux-MCU; **full motion/print sim is out of scope** (real-hardware territory).
3. **firmwareExe touch input** under qemu needs a virtio-input shim.

So the harness proves: install flow, boot, web stack, GUI render, and GUI↔klippy connect — **not** motion.

---

## 5. Stock-UI Spike

**Source (no device):** extract `firmwareExe` + its Qt-embedded libs from `fw-analysis/software-5.1.4.tar.xz` (+ runtime from `library-*.tar.xz`, minus the cloud SDK).

**Analysis:** `ldd`/`strings`/light RE → the Qt libs needed; the **klippy socket path + protocol** firmwareExe speaks; the gcode/objects/macros it queries; the **FlashForge custom klippy modules** it depends on (`flashforge_loadcell`, `flashforge_tvoc`).

**Live test (via §4d):** firmwareExe vs ReForge upstream klippy in qemu → record render/connect/control/breakage.

**Output:** `spike-stockui/REPORT.md` — works/breaks matrix + recommendation: implement STOCK mode as-is / port FF modules for parity / drop it. **No code beyond report + scripts.**

**Legal (firm):** `firmwareExe` is FlashForge **proprietary**. ReForge **never bundles or redistributes it.** The spike analyzes it locally from the user's own stock images. If STOCK mode is later implemented, it runs the `firmwareExe` **already present on the device's own stock partition** (preserved by the overlay) — ReForge ships only a launcher, never the binary. The repo commits **zero proprietary blobs** (gitignore enforced; CI check that no `firmwareExe`/Qt blobs are tracked).

---

## 6. Phasing & Done Criteria

| Step | Deliverable |
|---|---|
| **P3.1 Packaging** | `build-tgz.sh` → `reforge-<ver>.tgz` (subpackages + installer + md5sum) |
| **P3.2 Installer** | `flashforge_init.sh` overlay/chroot + screen-mode selector (HEADLESS default) + dual-boot/SKIP_MOD + cloud-block + uninstall pkg |
| **P3.3 qemu harness** | virt test kernel (Tina→virt, else generic) + stock-rootfs-from-dump + virtio-gpu fb |
| **P3.4 Validation** | loopback install test + **qemu end-to-end update test** (stock boots → installs ReForge → ReForge boots) + GuppyScreen renders in qemu |
| **P3.5 Stock-UI spike** | extract + analyze + live qemu test → `REPORT.md` + go/no-go decision |

**Done criteria:**
- `reforge-<ver>.tgz` builds reproducibly from `output-guppy`.
- Install validated in **loopback AND qemu**; ReForge boots emulated; web stack live; GuppyScreen renders at the pinned **800×480×32** fb.
- Update process passes at the **minimum bar** (filesystem-ops install → ReForge boots under the test kernel); full stock-boot-driven update is a stretch goal (§4c).
- Stock-UI spike `REPORT.md` delivered with a go/no-go decision (live evidence from §4d).
- **No device flashed**; forge-x + recovery posture intact.
- No proprietary blobs committed; cloud-block verified; uninstall path works.
- Installer docs state the caveat: ReForge boots + web-reachable, but **printing needs Plan 4 (MCU)**.

---

## 7. Open Questions / Risks

1. **Vendor kernel on qemu virt** (§4a) — main risk; generic-kernel fallback defined, but loses vendor-userland fidelity. Decide early via a spike build.
2. **Stock rootfs boots under a non-T113 kernel** (§4b) — init/services expect T113 devices; needs stubbing. May be fiddly; the *update-process* test (filesystem ops) is more robust than a full stock boot, so prioritize that if a full stock boot stalls.
3. **MCU simulation depth** (§4) — only "klippy up + queryable" is targeted; if even that needs a real MCU dictionary, capture one from the device (read-only) to feed a klippy linux-MCU/stub.
4. **firmwareExe under qemu** — Qt-embedded + fb + input may not run cleanly emulated; if blocked, the spike falls back to static analysis + a deferred on-device live test (when P3 is eventually flashed).
5. **Stock-UI vs upstream-klippy** — likely partial; the spike's whole point is to quantify before investing. FF custom modules (`flashforge_loadcell/tvoc`) are the known gap.

---

## 8. Provenance & path bases

**In-repo** (under `reforge/`): the golden eMMC dump (`recovery/golden-kunos-*.img.gz` — stock rootfs source for §4b), the Tina vendor kernel source (`modules/zram-bsp/tina-bsp-kernel` — virt test kernel base for §4a), the full-stack rootfs (`output-guppy/` — software-subpackage source), Plan-2 init scripts.

**External sibling working dirs** (one level *up*, beside `reforge/` — NOT in-repo; scripts must use the `../` base or an absolute path): `../fw-analysis/x-5.1.4/flashforge_init.sh` (stock installer-flow reference), `../fw-analysis/*/software-*.tar.xz` (firmwareExe source for the spike), `../forge-x/` (overlay/chroot/screen-mode/dual-boot/SKIP_MOD patterns). The proprietary `firmwareExe` lives only in `../fw-analysis/` and is **never** copied into the repo (§5 legal).

Measured-from-device fact baked into §4a: panel `800×480×32`, virtual `800×960`, mode `800x480p-67`.
</content>
