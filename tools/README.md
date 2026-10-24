# tools/ — dev / ops tooling

Helpers that build or operate ReForge. **Not shipped inside the firmware image.**

| path | what |
|---|---|
| `build/` | `build.sh` + `env.sh` — the build entry point, driven by the top-level `Makefile` (`make rootfs`/`defconfig`/`clean`). Resolves paths and invokes Buildroot with `BR2_EXTERNAL=br-external`, `O=build/output`. |
| `recovery/` | golden-dump tooling + `RUNBOOK.md` + `recovery-sources.md` (pinned stock recovery/factory image URLs+hashes). Large images live in gitignored `archive/`. |
| `release/` | Release archives, live USB images, release metadata, and hardware trial verification. |
| [ota/](ota/README.md) | FlashForge firmware update checker and its host tests. |
| `lint/` | ShellCheck runner for tracked project scripts. |
| `build-chelper-hardfloat.sh` | Build a hard-float Klipper C helper for the Forge-X shared-Python experiment in `contrib/`. |

See `docs/REPO-LAYOUT.md` for how this fits the product / vendor / lab split.
