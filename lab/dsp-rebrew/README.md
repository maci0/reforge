# Stock FreeRTOS DSP reconstruction with Rebrew

This project targets the original Xtensa `aw_axi_cfg0` ELF, SHA-256
`61ed4f199ca3b15f96c245a709282e1a4798b14d0f23a5e2930577487ebd20d1`.
The full firmware reconstruction remains incomplete; the kernel C component
now matches byte-identically as documented below.

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
not byte-equality claims. The component proof below compares every byte in its
complete declared ranges. Remaining firmware code/data, the full ELF and the
partition tail still need reconstruction and verification. No firmware was flashed.

Standalone function proofs also verify: `fls` at `0x32020b10` (95 bytes,
including bundled branches), and `main` at `0x3200bb60` (28 bytes after four
native call relaxations). A wrong callee binding is rejected. These proofs
cover function code; referenced data and full firmware layout remain separate.
The `fls` binding has an earned `EXACT` result in Rebrew metadata. Reconstructions
are in `src/dsp0/`. The tracked `main-rebrew-proof.json` records exact code
bytes, symbol/section bindings and the wrong-callee control. Other generated
proof artifacts remain under `../../build/stock-dsp-rebuild/`.

The function-level Rebrew project uses the configured `build/` paths. The
component recipe below needs only pinned source files and the XCC image to
build; the stock ELF is an optional verification input.

Upstream validation passed 13,338 tests with 40 skips, coverage, lint, types,
audit, packaging, clean-wheel smoke, reproducible builds and provenance checks.
Release assets are the verified CI wheel, sdist, build manifest and SBOM from
the merge commit.

## Complete kernel C component

The stock-retained FreeRTOS C core and `heap_4` now reproduce byte-identically:
58 functions, 10,305 initialized bytes (code, padding, literals and read-only
data), and the placement/size of 263,152 bytes of BSS including its padding.
The seven source modules are compiled fresh; event groups and stream buffers
have no retained allocation in this stock component. The Xtensa port, application
hooks and C runtime remain external dependencies with explicit address bindings.
Their implementations and the full DSP firmware are not part of this match.

`kernel-layout.json` preserves recovered placement and external bindings, and
pins all 25 source inputs plus the compiler image and candidate configuration.
The recipe uses Rebrew 6.9.0's image runner with source mounted read-only. It
never reads the reference during compilation/linking and never copies reference
bytes into the build. Literal sharing follows the original native input order.
External function anchors are link context and are excluded from component bytes.

Use a checkout of `https://github.com/pdscomp/oc-freertos-dsp-xt` at
`91148809209fa0d5eb4591273fd08233cf9cc48f`. No prebuilt objects or generated
headers are needed. The stock verification ELF must have SHA-256
`61ed4f199ca3b15f96c245a709282e1a4798b14d0f23a5e2930577487ebd20d1`.
From the repository root, with `DSP_SOURCE` pointing to that checkout's
`freertos` directory and `STOCK_DSP` pointing to the stock ELF:

```sh
uv run --script lab/dsp-rebrew/rebuild-kernel.py "$DSP_SOURCE" build/dsp-kernel-a --reference "$STOCK_DSP"
uv run --script lab/dsp-rebrew/rebuild-kernel.py "$DSP_SOURCE" build/dsp-kernel-b
uv run --script lab/dsp-rebrew/check-kernel-rebuild.py "$DSP_SOURCE" build/dsp-kernel-a build/dsp-kernel-b "$STOCK_DSP"
cmp build/dsp-kernel-a/kernel-component.bin build/dsp-kernel-a/reference-component.bin
```

Each build directory must be new. `kernel.elf` includes external address anchors
and unused address-space gaps; its whole file is not the stock firmware.
`kernel-component.bin` concatenates the complete file-backed component ranges
in ascending address order; `kernel-proof.json` records those ranges and hashes.
BSS has no file payload and is checked separately as zero-fill allocation.
The component binary SHA-256 is
`cca2466dabfe9baad47f8aa090eceeda017f5e0339041db86833f693a8572a50`.

Two independent pristine-source builds produce identical ELFs. Nine checks
verify reproducibility and reject modified bytes in every file-backed range,
a changed component binary, a wrong function length, and a freshly recompiled
component with the `sprintf` binding shifted by four bytes. The complete
firmware, partition tail and hardware behavior remain unverified.

## Kernel version evidence

The candidate's seven kernel implementation files and `task.h` match upstream
V10.2.0 after line-ending normalization; the candidate declares Xtensa port 1.7.
The complete retained C component now matches stock, but that does not uniquely
identify its historical patch/vendor revision. The stock ELF retains no version
string or debug/symbol table. Compiling upstream V10.2.0 and V10.2.1 `tasks.c`
with their matching headers, the supplied compiler and candidate port/config
produced identical allocated sections and relocation records. The port README
still mentions kernel 10.0.0 and its release notes include 2.0 entries, so those
labels alone are not stock-version evidence.

See [version evidence](freertos-version-proof.json) and the exact
[upstream V10.2.0 source](https://github.com/FreeRTOS/FreeRTOS-Kernel/tree/233285746e7280e91239d64718ef52b32ee91f68/FreeRTOS/Source).
An original SDK/build manifest or another version-discriminating artifact is
still needed to identify the exact stock patch/vendor revision.
