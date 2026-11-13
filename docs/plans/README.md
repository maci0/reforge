# plans/

Implementation plans for ReForge. **Snapshots:** each plan records the implementation
strategy as written, with status updates appended (not rewritten) as work lands. The
phases that survived implementation are folded into the reference docs
([`../architecture.md`](../architecture.md), [`../boot.md`](../boot.md),
[`../ota.md`](../ota.md), [`../optimizations.md`](../optimizations.md)).

Filenames are `YYYY-MM-DD-<slug>.md`. Plans here are roughly in dependency order:
P1 → P2 → P3 → OTA → kernel-rebuild → immutable. P4 now has an optional
source-built Klipper 13 host/MCU package; P5 has a mainline size-proxy build,
with board boot/display validation still open. Remaining work is tracked in
[`../BACKLOG.md`](../BACKLOG.md).

## Plans (oldest → newest)

| date | plan | status | what |
|---|---|---|---|
| 2026-05-31 | [`plan1-recovery-and-buildroot-foundation`](2026-05-31-plan1-recovery-and-buildroot-foundation.md) | ✅ landed | Recovery posture (golden dump + RUNBOOK Path A/B), Buildroot external tree, vendor pins, qemu-virt test kernel. |
| 2026-05-31 | [`plan2-core-stack`](2026-05-31-plan2-core-stack.md) | ✅ landed | Klipper + Moonraker + Mainsail + GuppyScreen on Buildroot, chrooted overlay model. zram, screen modes (HEADLESS / GUPPY / STOCK). |
| 2026-06-01 | [`plan3-installer`](2026-06-01-plan3-installer.md) | ✅ landed | Stock-format `.tgz` installer; `flashforge_init.sh`; `S01reforge` boot hook; qemu validation; [legacy loopback test](../../tests/README.md#loopback-install-test) needs layout updates; `SKIP_MOD` dual-boot. |
| 2026-06-01 | [`reforge-ota`](2026-06-01-reforge-ota.md) | ✅ landed | GitHub-Release-driven OTA via Moonraker's `update_manager`; per-component zips; reserved-app handling via `0002-zip-updater-for-reserved-apps.patch`; LKG + trial-N-fails rollback. |
| 2026-06-04 | [`bsp-kernel-rebuild-and-diff`](2026-06-04-bsp-kernel-rebuild-and-diff.md) | ✅ host-rebuild reproducible | Host-only rebuild of the stock 5.4.61 BSP kernel (vendor source + captured `.config` + GCC 9.5.0). Vermagic byte-identical. The follow-up attempt with Linaro GCC 5.3.1 ([`../research/kernel/2026-06-04-byte-identical-kernel-reproduction.md`](../research/kernel/2026-06-04-byte-identical-kernel-reproduction.md)) left a 5.9 MB byte difference; the current build (2026-10-26) matches the stock raw `Image` except its 20-byte build ID ([stock bringup audit](../board-notes/stock-bringup-rebuild.md)). |
| 2026-06-05 | [`immutable-reforge`](2026-06-05-immutable-reforge.md) | 🟦 plan ready (phase 1 pending) | Versioned-OverlayFS layout + atomic install/OTA/rollback via `current`-symlink pointer swap, plus true Mode 1 live with `upperdir=tmpfs`. **Supersedes the LKG dir-dance once landed.** Substrate proved (overlay spike + on-hw sanity); phases 1–5 enumerated, phase 1 implementation pending. |

## Follow-up work (tracked in [`../BACKLOG.md`](../BACKLOG.md))

- **Plan 4 — MCU firmware**. Stock-compatible Klipper 11 remains the default.
  The optional [Klipper 13 host/MCU package](../../br-external/package/klipper13/README.md)
  is source-built; this does not establish physical flashing or printing validation.
- **Plan 5 — Mainline kernel + display driver + own boot image** (the stock path loads
  `uImage` + `sunxi.dtb` from p1; see [`../boot.md`](../boot.md#1-the-boot-chain-verified)). The Mode 3
  destination per [`../deployment-modes.md`](../deployment-modes.md). Per-peripheral
  mainline status mapped in [`../research/kernel/2026-06-01-t113-mainline-kernel-support.md`](../research/kernel/2026-06-01-t113-mainline-kernel-support.md).

## Specs that drive these plans

Design specs (not the implementation plan itself, the requirements/architecture spec):

- [`../specs/2026-05-31-reforge-firmware-design.md`](../specs/2026-05-31-reforge-firmware-design.md) — the foundational firmware spec; anti-cloud posture; chroot model; brick-safety tiers.
- [`../specs/2026-06-01-plan3-installer-design.md`](../specs/2026-06-01-plan3-installer-design.md) — install / boot / uninstall / dual-boot design that plan3 implements.
- [`../specs/2026-06-01-reforge-ota-design.md`](../specs/2026-06-01-reforge-ota-design.md) — OTA design that the `reforge-ota` plan implements.
