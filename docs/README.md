# docs/

| path | what |
|---|---|
| [`optimizations.md`](optimizations.md) | **all tuning/optimizations + measured impact** (memory, size) |
| [`architecture.md`](architecture.md) | system architecture, runtime stack, data flow (diagrams) |
| [`build-process.md`](build-process.md) | pins → vendor fetch → Buildroot → image → `.tgz` (diagram) |
| [`boot.md`](boot.md) | **the boot reference**: stock chain (BROM→U-Boot→init) + intervention points + brick-safety + forge-x hook + stock USB-update detection, *and* the installed-ReForge service chain |
| [`2026-06-02-ad5m-mcu-firmware-and-config.md`](2026-06-02-ad5m-mcu-firmware-and-config.md) | AD5M **MCU firmware v11/v13**, stock vs xblax vs ZMod config, the canonical printer config |
| [`ota.md`](ota.md) | git-free in-place updates + last-known-good rollback (diagrams; designed) |
| [`live-mode.md`](live-mode.md) | run the stack from USB, zero eMMC writes — brick-free hardware trials |
| [`REPO-LAYOUT.md`](REPO-LAYOUT.md) | **source of truth** for the repo structure (product / vendor / lab) |
| [`BACKLOG.md`](BACKLOG.md) | unscheduled ideas (e.g. the Zig microgit; reforge OTA design) |
| `specs/` | design specs (dated) — archival snapshots |
| `plans/` | implementation plans (dated) — archival snapshots |
| `research/` | findings: memory experiments, T113 mainline support, stock recovery images, stock-UI spike, buildroot-vs-alpine, etc. |
| `board-notes/` | hardware probes + the captured stock kernel config |
| `screenshots/` | qemu-captured renders + the boot console / bootsplash (see its README) |

**Convention:** `specs/` and `plans/` are *snapshots* — they record paths/decisions as written
and are not rewritten on later refactors. `REPO-LAYOUT.md` reflects the current tree.
