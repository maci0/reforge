# Contributing

ReForge is experimental firmware for the FlashForge Adventurer 5M family. The
[README](README.md) describes the current hardware validation and limitations.

Use the [repository map](docs/REPO-LAYOUT.md) to choose where a change belongs.
Product code lives in `br-external/`, `modules/`, and `packaging/`; build tools and
validation live in `tools/` and `tests/`. Keep investigations in `lab/` and captured
printer configs in `reference/`, with their origin documented.

## Development checks

On a Linux host with Bash, Make, Python 3, and ShellCheck installed:

```sh
make lint
make unit
git diff --check
```

Run checks relevant to the change. Firmware builds require the dependencies listed
in [build-process.md](docs/build-process.md) and `./vendor/fetch.sh` to populate the
pinned source trees and toolchains. Hardware and QEMU checks have additional
requirements documented in [tests/README.md](tests/README.md).

Describe what changed, why, the checks run, and whether a result was observed in
QEMU or on hardware. Keep historical findings intact and update current docs when
paths or behavior change.

## Source and generated files

Keep upstream source trees pinned as submodules. Carry BSP modifications in
`vendor/kernels/patches/` and preserve the license headers and provenance of copied
source. Record new dependency pins in `pins.lock` and the relevant build recipe.

Build output, downloaded toolchains, recovery images, extracted FlashForge binaries,
and local credentials stay out of Git. Inspect `git status` and the staged diff
before committing; do not force-add ignored artifacts. Existing kernel modules in
`modules/*/dist/` are intentional tracked build outputs with source and build scripts
alongside them.

## License

Contributions to ReForge's original code are made under [GNU GPL version 3](LICENSE).
Preserve any existing license notices when modifying third-party files.
