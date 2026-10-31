# Stock FreeRTOS DSP reconstruction with Rebrew

This project targets the original Xtensa `aw_axi_cfg0` ELF, SHA-256
`61ed4f199ca3b15f96c245a709282e1a4798b14d0f23a5e2930577487ebd20d1`.
It is not yet a byte-identical reconstruction.

The compiler profile uses the supplied Docker image
`reforge/xtensa-xcc:14.04-ri2020.4-aw_axi_cfg0` (local image ID
`sha256:c398e497143e99013d9dd5e677cbc2f06e1ad446d74ab37eb9961c0fb5222165`).
Both a direct `xt-xcc -c` smoke compile and Rebrew’s own `run_toolchain`
Docker invocation succeeded on 2026-10-30.
Stock `.comment` records application inputs compiled with `-O3 -g3`;
runtime library inputs use their own flags.

From this directory:

```sh
export REBREW_TOOLCHAIN_OVERLAY_DIR="$PWD/toolchains"
rebrew toolchain status xtensa-xcc-14.04-aw_axi_cfg0 --json
rebrew doctor --json
```

Rebrew 6.9.0 is installed from the verified upstream CI wheel:
https://github.com/maci0/rebrew/releases/tag/v6.9.0
The contribution was merged through https://github.com/maci0/rebrew/pull/56.
Release artifacts are distributed through GitHub only.

Little-endian Xtensa ELF32 is supported. Typed comparison resolves standard
relocations with explicit bindings. Image-backed XCC projects use the matching
core linker for bundled/TIE instructions and longcall relaxation, and native
objdump for byte-checked disassembly. Unsupported assembly exports and
offset-only relocation masking fail explicitly. See upstream `docs/XTENSA.md`.

Local investigation artifacts are under `../../build/stock-dsp-rebuild/`:

- `stock.i64`, `ida.log`, `ida-stock.json`: IDA Pro 9.4 analysis of the stock ELF.
- `baseline-O2.elf`: unstripped build from the supplied candidate configuration.
- `candidate-O3.elf`: stripped build with the stock optimization setting.
- `candidate-cohort.elf`: stripped build with component selection aligned to
  the stock compiler-record cohort; this remains a hypothesis, not the recovered
  original configuration.
- `source/`: isolated copy of `/tmp/opencode/oc-freertos-dsp-xt` with build inputs.

`cohort-candidate.config` preserves the experimental component selection.
The cohort candidate has `.text` 87,232 bytes (stock 92,784), `.rodata` 23,912
(stock 24,384), `.data` 16,680 (stock 16,948), and BSS 281,840 (stock 281,832).
The stock source cohort contains `kernel/common/notifier/notifier.c` and
`drivers/hal/source/dma/sunxi_dma_core.c`, absent from the candidate source.
The stock `main` at `0x3200bb60` starts the sound card, starts the UART console
unconditionally, and starts the scheduler. The later candidate adds a console
availability branch and other configurable services.

Pattern matches that exclude PC-relative instructions are exploratory candidates,
not byte-equality claims. Complete function operands, code/data layout, the full
ELF, and the partition tail still need verification. No firmware was flashed.

Two functions are verified byte-identical: `fls` at `0x32020b10` (95 bytes,
including bundled branches), and `main` at `0x3200bb60` (28 bytes after four
native call relaxations). A wrong callee binding is rejected. These proofs
cover function code; referenced data and full firmware layout remain separate.
The `fls` binding has an earned `EXACT` result in Rebrew metadata. Reconstructions
are in `src/dsp0/`. The tracked `main-rebrew-proof.json` records exact code
bytes, symbol/section bindings and the wrong-callee control. Other generated
proof artifacts remain under `../../build/stock-dsp-rebuild/`.

A fresh checkout needs the stock ELF and candidate source/build artifacts at
the configured `build/` paths; these generated files are not tracked.

Upstream validation passed 13,338 tests with 40 skips, coverage, lint, types,
audit, packaging, clean-wheel smoke, reproducible builds and provenance checks.
Release assets are the verified CI wheel, sdist, build manifest and SBOM from
the merge commit. No complete DSP component is certified byte-identical yet.
