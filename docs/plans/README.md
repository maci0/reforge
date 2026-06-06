# plans/

Implementation plans for ReForge. **Snapshots:** each plan records the implementation
strategy as written, with status updates appended (not rewritten) as work lands. The
phases that survived implementation are folded into the reference docs
([`../architecture.md`](../architecture.md), [`../boot.md`](../boot.md),
[`../ota.md`](../ota.md), [`../optimizations.md`](../optimizations.md)).

Filenames are `YYYY-MM-DD-<slug>.md`. Plans here are roughly in dependency order:
P1 → P2 → P3 → OTA → kernel-rebuild → immutable. P4 (MCU firmware) and P5
(mainline-kernel + display driver) are not yet started; tracked in
[`../BACKLOG.md`](../BACKLOG.md).

## Plans (oldest → newest)

| date | plan | status | what |
|---|---|---|---|
| 2026-05-31 | [`plan1-recovery-and-buildroot-foundation`](2026-05-31-plan1-recovery-and-buildroot-foundation.md) | ✅ landed | Recovery posture (golden dump + RUNBOOK Path A/B), Buildroot external tree, vendor pins, qemu-virt test kernel. |
| 2026-05-31 | [`plan2-core-stack`](2026-05-31-plan2-core-stack.md) | ✅ landed | Klipper + Moonraker + Mainsail + GuppyScreen on Buildroot, chrooted overlay model. zram, screen modes (HEADLESS / GUPPY / STOCK). |
| 2026-06-01 | [`plan3-installer`](2026-06-01-plan3-installer.md) | ✅ landed | Stock-format `.tgz` installer; `flashforge_init.sh`; `S01reforge` boot hook; loopback + qemu validation; `SKIP_MOD` dual-boot. |
| 2026-06-01 | [`reforge-ota`](2026-06-01-reforge-ota.md) | ✅ landed | GitHub-Release-driven OTA via Moonraker's `update_manager`; per-component zips; reserved-app handling via `0002-zip-updater-for-reserved-apps.patch`; LKG + trial-N-fails rollback. |
| 2026-06-04 | [`bsp-kernel-rebuild-and-diff`](2026-06-04-bsp-kernel-rebuild-and-diff.md) | ✅ host-rebuild reproducible | Host-only rebuild of the stock 5.4.61 BSP kernel (vendor source + captured `.config` + GCC 9.5.0). Vermagic byte-identical; pushed to fully byte-identical with Linaro GCC 5.3.1 (see [`../research/kernel/2026-06-04-byte-identical-kernel-reproduction.md`](../research/kernel/2026-06-04-byte-identical-kernel-reproduction.md)). |
| 2026-06-05 | [`immutable-reforge`](2026-06-05-immutable-reforge.md) | 🟦 plan ready (phase 1 pending) | Versioned-OverlayFS layout + atomic install/OTA/rollback via `current`-symlink pointer swap, plus true Mode 1 live with `upperdir=tmpfs`. **Supersedes the LKG dir-dance once landed.** Substrate proved (overlay spike + on-hw sanity); phases 1–5 enumerated, phase 1 implementation pending. |

## Not yet planned (tracked in [`../BACKLOG.md`](../BACKLOG.md))

- **Plan 4 — MCU firmware**. ReForge ships against stock MCU firmware v11. Replacing the
  MCU side requires either a vendored eboard firmware build or the upstream MCU bringup.
- **Plan 5 — Mainline kernel + display driver + own boot.img**. The Mode 3
  destination per [`../deployment-modes.md`](../deployment-modes.md). Per-peripheral
  mainline status mapped in [`../research/kernel/2026-06-01-t113-mainline-kernel-support.md`](../research/kernel/2026-06-01-t113-mainline-kernel-support.md).

## Specs that drive these plans

Design specs (not the implementation plan itself, the requirements/architecture spec):

- [`../specs/2026-05-31-reforge-firmware-design.md`](../specs/2026-05-31-reforge-firmware-design.md) — the foundational firmware spec; anti-cloud posture; chroot model; brick-safety tiers.
- [`../specs/2026-06-01-plan3-installer-design.md`](../specs/2026-06-01-plan3-installer-design.md) — install / boot / uninstall / dual-boot design that plan3 implements.
- [`../specs/2026-06-01-reforge-ota-design.md`](../specs/2026-06-01-reforge-ota-design.md) — OTA design that the `reforge-ota` plan implements.
