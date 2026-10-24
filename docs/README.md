# docs/

Living **reference docs** are at the top level (kept current). Dated **snapshots** (specs, plans,
research, RE reports) live in subdirs, each with its own index README.

## Reference (current)
| path | what |
|---|---|
| [`architecture.md`](architecture.md) | system architecture, runtime stack, data flow (diagrams) |
| [`boot.md`](boot.md) | **the boot reference**: stock chain (BROM→U-Boot→init) + intervention points + brick-safety + forge-x hook + stock USB-update detection, *and* the installed-ReForge service chain (incl. the eboard MCU handshake) |
| [`build-process.md`](build-process.md) | pins → vendor fetch → Buildroot → image → `.tgz` (diagram; now also builds the kernel — `make kernel` / `kernel-virt`) |
| [`deployment-modes.md`](deployment-modes.md) | the deployment matrix — live-USB vs `.tgz` install vs stock, and how they relate |
| [`live-mode.md`](live-mode.md) | run the stack from USB — brick-free hardware trials |
| [`ota.md`](ota.md) | git-free in-place updates + last-known-good rollback (diagrams; **implemented**) |
| [`optimizations.md`](optimizations.md) | **all tuning/optimizations + measured impact** (memory, size) — canonical numbers |
| [`security-findings.md`](security-findings.md) | **15 RE'd stock-firmware security findings** + per-mode closure status (Mode 1 → 2a → 2b → 3); the case for elevating Mode 2b. |
| [`REPO-LAYOUT.md`](REPO-LAYOUT.md) | **source of truth** for the repo structure (product / vendor / lab) |
| [`BACKLOG.md`](BACKLOG.md) | unscheduled ideas |

## Snapshots & findings (dated, per-dir index)
| dir | what |
|---|---|
| [`research/`](research/README.md) | dated findings, grouped: **Kernel & SoC** (T113 mainline support, BSP rebuild, byte-identical, brick-safe test, PID1), **Memory** (128 MB experiments), **UI/camera/video**, **printer stack** |
| [`reverse-engineering/`](reverse-engineering/README.md) | stock-firmware RE reports — full `firmwareExe` teardown, stock Klipper pin map, MCU firmware, stock kernel/modules + byte-identical build, **Tina-Auto kernel genealogy**,; the per-version firmware changelog + checksummed blob archive live in the sibling **`fw-archive/`** repo |
| [`board-notes/`](board-notes/README.md) | device/hardware reference: device overview, partition map, forge-x boot/camera, stock-rootfs provenance, USB-serial kmod |
| [`specs/`](specs/README.md) | design specs (dated) — archival: firmware-design, OTA, plan3-installer |
| [`plans/`](plans/README.md) | implementation plans (dated) — archival: plan1–3, [reforge-ota](plans/2026-06-01-reforge-ota.md), [bsp-kernel-rebuild-and-diff](plans/2026-06-04-bsp-kernel-rebuild-and-diff.md), [immutable-reforge](plans/2026-06-05-immutable-reforge.md) (OverlayFS pointer-swap — supersedes the LKG dir-dance once landed) |
| [`screenshots/`](screenshots/README.md) | qemu renders + boot console / bootsplash |

**Convention:** `specs/`, `plans/`, and `research/` are *snapshots* — they record decisions as
written and aren't rewritten on later refactors (a `## Update <date>` is appended if re-verified).
The reference docs above and `REPO-LAYOUT.md` reflect the current tree.

## Other docs in the repo (code-co-located)

Documentation that lives next to its subject. Worth knowing about:

| path | what |
|---|---|
| [`../README.md`](../README.md) | repo entry point: what / why / quick start / live mode / install / recovery / policy |
| [`lab-notebook.md`](lab-notebook.md) | append-only lab notebook — dated entries for major sessions, findings, decisions |
| [`../packaging/README.md`](../packaging/README.md) | installer + uninstaller flow; **competing-mod pre-flight check**; dual-boot `SKIP_MOD`; loopback / qemu validation |
| [`../tools/recovery/RUNBOOK.md`](../tools/recovery/RUNBOOK.md) | recovery procedures — USB `.tgz` (Path A), eMMC-reader fallback (Path B) |
| [`../tools/recovery/recovery-sources.md`](../tools/recovery/recovery-sources.md) | how stock recovery `.tgz` files are sourced + verified |
| [`../tests/qemu-harness/README.md`](../tests/qemu-harness/README.md) | the qemu test rig — how to boot ReForge under qemu virt with production-shaped eMMC + USB-as-sda |
| [`../tests/README.md`](../tests/README.md) | test taxonomy: qemu harness vs release/unit vs loopback |
| [`../modules/zram-bsp/README.md`](../modules/zram-bsp/README.md) | building zram + zsmalloc out-of-tree against the stock 5.4.61 BSP kernel for live mode |
| [`../br-external/README.md`](../br-external/README.md) | the Buildroot external tree (`BR2_EXTERNAL`) layout |
| [`../tools/README.md`](../tools/README.md) | build / release / recovery / OTA tooling index |
| [`../reference/README.md`](../reference/README.md) | stock firmware and Forge-X config captures with provenance |
| [`../CONTRIBUTING.md`](../CONTRIBUTING.md) | development checks and source/artifact conventions |
| [`../tools/ota/README.md`](../tools/ota/README.md) | the OTA test harness + mock GitHub release server |
| [`../lab/README.md`](../lab/README.md) | experiments / scratch — not shipped, kept for reproducibility |
| [`../contrib/forge-x-shared-python/README.md`](../contrib/forge-x-shared-python/README.md) | upstream contribution: shared Python interpreter for forge-x |
