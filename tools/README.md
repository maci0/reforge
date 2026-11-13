# tools/ — dev / ops tooling

Helpers that build or operate ReForge. **Not shipped inside the firmware image.**

| path | what |
|---|---|
| `build/` | Buildroot entry (`build.sh`, `env.sh`), BSP/mainline kernel builders, and stock bootloader/kernel/board-data reconstruction and comparison tools. Current reproduction commands: [stock bring-up audit](../docs/board-notes/stock-bringup-rebuild.md). |
| `recovery/` | golden-dump tooling + `RUNBOOK.md` + `recovery-sources.md` (pinned stock recovery/factory image URLs+hashes). Dumps (`*.img.gz` and their sidecars) and `archive/` are gitignored. |
| `release/` | Release archives, live USB images, release metadata, and a legacy live-trial helper. |
| [ota/](ota/README.md) | FlashForge firmware update checker and its host tests. |
| `lint/` | ShellCheck runner for tracked project scripts. |

See `docs/REPO-LAYOUT.md` for how this fits the product / vendor / lab split.

`release/verify-live-trial.sh` is a legacy helper, not a current write-audit gate:
it still probes loop-on-FAT and tmpfs `/data`, and its printed zero-eMMC-write
verdict is not supported by checking install-directory absence. Current live images
use F2FS p2 and bind eMMC `/data`; see [live mode](../docs/live-mode.md).

The live-mode/OTA harnesses have a separate [legacy residue-path limitation](../docs/live-mode.md#the-install-residue-invariant).
