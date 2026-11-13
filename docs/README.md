# docs/

Current **reference docs** sit at this level and track the tree. Dated **snapshots**
(specs, plans, research, RE reports) live in subdirectories, each with its own index.

## Reference (current)

| path | what |
|---|---|
| [`architecture.md`](architecture.md) | system architecture, runtime stack, data flow, phase status |
| [`deployment-modes.md`](deployment-modes.md) | live USB vs `.tgz` install vs full replacement, and the installer paths |
| [`build-process.md`](build-process.md) | host requirements, pins, Buildroot build, kernels, `.tgz` and live image |
| [`boot.md`](boot.md) | stock boot chain (BROM → U-Boot → init), intervention points and brick safety, forge-x hook, stock USB-update detection, installed-ReForge service chain, eboard MCU handshake |
| [`live-mode.md`](live-mode.md) | run the stack from USB without the installer; first boot writes `/reforge` on the stock rootfs |
| [`ota.md`](ota.md) | git-free updates and last-known-good rollback (qemu gate `make qemu-ota`) |
| [`optimizations.md`](optimizations.md) | tuning levers with measured memory and size impact (canonical numbers) |
| [`security-findings.md`](security-findings.md) | 15 stock-firmware security findings and their closure status per mode |
| [`REPO-LAYOUT.md`](REPO-LAYOUT.md) | repository structure (product / vendor / lab); source of truth for layout |
| [`BACKLOG.md`](BACKLOG.md) | open issues and unscheduled ideas |
| [`lab-notebook.md`](lab-notebook.md) | append-only dated log of sessions, findings and decisions |

## Snapshots (dated, per-directory index)

| dir | what |
|---|---|
| [`research/`](research/README.md) | findings grouped by kernel and SoC, memory, UI/camera/video, printer stack |
| [`reverse-engineering/`](reverse-engineering/README.md) | stock firmware RE: `firmwareExe`, stock Klipper and MCU firmware, stock kernel and modules, byte-identical kernel build, kernel genealogy. The per-version firmware changelog and checksummed blob archive live in the separate `fw-archive/` repository |
| [`board-notes/`](board-notes/README.md) | hardware reference: device overview, partition map, forge-x boot and camera, stock-rootfs provenance, [stock bringup rebuild audit](board-notes/stock-bringup-rebuild.md) |
| [`specs/`](specs/README.md) | design specs: firmware design, OTA, installer |
| [`plans/`](plans/README.md) | implementation plans 1 to 3, OTA, BSP kernel rebuild, immutable ReForge (OverlayFS pointer swap, not yet implemented) |
| [`screenshots/`](screenshots/README.md) | qemu renders, boot console, bootsplash |
| [`releases/`](releases/v0.6.0.md) | per-release notes (only v0.6.0 has one) |

`specs/`, `plans/` and `research/` record decisions as written and are not rewritten
after later refactors; a dated `## Update` or status note is appended when an entry is
re-verified or superseded.

## Docs next to their code

| path | what |
|---|---|
| [`../README.md`](../README.md) | project front page: status, quick start, live mode, install, policy |
| [`../CONTRIBUTING.md`](../CONTRIBUTING.md) | development checks and source/artifact conventions |
| [`../packaging/README.md`](../packaging/README.md) | installer and uninstaller, competing-mod pre-flight, `SKIP_MOD` dual boot |
| [`../br-external/README.md`](../br-external/README.md) | Buildroot external tree layout |
| [`../vendor/README.md`](../vendor/README.md) | pinned third-party inputs and `fetch.sh` |
| [`../modules/zram-bsp/README.md`](../modules/zram-bsp/README.md) | zram + zsmalloc against the stock 5.4.61 BSP kernel (shipped via `S35zram`) |
| [`../tests/README.md`](../tests/README.md) | test taxonomy: smoke, unit, loopback, qemu harness |
| [`../tests/qemu-harness/README.md`](../tests/qemu-harness/README.md) | qemu rig with production-shaped eMMC and USB |
| [`../tools/README.md`](../tools/README.md) | build, release, recovery and OTA tooling |
| [`../tools/recovery/RUNBOOK.md`](../tools/recovery/RUNBOOK.md) | recovery: USB `.tgz` (Path A), eMMC reader (Path B) |
| [`../tools/recovery/recovery-sources.md`](../tools/recovery/recovery-sources.md) | where stock recovery `.tgz` files come from and how they are verified |
| [`../tools/ota/README.md`](../tools/ota/README.md) | FlashForge firmware update checker and its host tests |
| [`../reference/README.md`](../reference/README.md) | stock and Forge-X config captures with provenance |
| [`../lab/README.md`](../lab/README.md) | experiments, not shipped, kept for reproducibility |
