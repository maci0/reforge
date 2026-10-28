# Forge-X Python core: Thumb-2/`-Os`, then LTO

Scope: disposable Forge-X `1.4.2-beta-4` mod Buildroot images. The Tina BSP kernel,
stock Python/Klippy, mod libc, stdlib, installed native extensions and production OS
are unchanged. This is a **CPython core experiment**, not a rebuild of the entire
Forge-X Buildroot or its GUI/libraries. The Forge-X checkout contains no Buildroot
source configuration/recipe to reproduce the complete mod environment.

## Source builds

The fixture records Python **3.11.10**, GCC **11.4.0**, ARM code and `-O3`.
Three source builds use Python 3.11.10 and the same Reforge GCC **15.3.0**, targeting
Cortex-A7, NEON-VFPv4 and ARM hard-float:

1. ARM/`-O3`, no LTO: controls for compiler/configuration differences from the fixture.
2. Thumb-2/`-Os`, no LTO: compare with the source-built ARM control.
3. Thumb-2/`-Os` plus GCC full LTO: compare separately with the non-LTO Thumb build.

Only stripped `python3.11` and `libpython3.11.so.1.0` are injected into the disposable
mod filesystem. The existing Moonraker virtualenv points to that executable. No libc,
loader, native extension or Python bytecode file is replaced. CPython's pymalloc,
shared-library ABI and Python version remain unchanged. Source-build configuration
is shared between the new variants; it does not reproduce every original Buildroot
patch/configuration choice. Compare the two new non-LTO builds to isolate the combined
ISA/optimization treatment, rather than assigning every fixture difference to flags.

Build inputs (upstream source archives):

- `Python-3.11.10.tar.xz`: [upstream Python archive](https://www.python.org/ftp/python/3.11.10/Python-3.11.10.tar.xz), SHA256 `07a4356e912900e61a15cb0949a06c4a05012e213ecd6b4e84d0f67aabbee372`.
- `glibc-2.38.tar.xz`: [upstream GNU archive](https://ftp.gnu.org/gnu/glibc/glibc-2.38.tar.xz), SHA256 `fb82998998b2b29965467bc1b69d152e9c307d2cf301c9eafb4555b770ef3fd2`.

A host Python 3.11.10 is built from the same source for cross-build freezing. A separate
**glibc 2.38 development sysroot** is built from source for linking, using Reforge's
Linux 5.4.61 headers. That sysroot is never deployed: ABI tests and boot trials use the existing
Forge-X loader/libc. Required GLIBC symbol versions are checked against 2.38. Reforge's
compiler wrapper is bypassed to avoid importing its product-specific flags.

[The builder](../../../tools/build/build-forgex-python-trial.sh) records actual compile
flags, artifact hashes and compiler version. `OPT` removes CPython's default `-O3`,
then the requested optimization is passed in `CFLAGS`; the actual `ceval.c` command
is checked for the last optimization flag. Thumb mode is also verified through the
odd ELF `Py_Initialize` symbol value, rather than assuming an ELF ISA attribute alone
proves every function uses Thumb.

CPython 3.11's LTO configure logic matches `*gcc*` against the compiler command's name.
An initial wrapper named `cc` accepted `--with-lto=full` but emitted no LTO flags. That
candidate was **excluded**. The corrected `trial-gcc` wrapper enables actual `-flto`
compilation/linking; the builder rejects an LTO candidate lacking these flags.

## File sizes

Stripped library sizes; these are **not resident RAM measurements**:

| Build | `libpython3.11.so.1.0` bytes | Change |
|---|---:|---:|
| Shipped fixture, GCC 11.4 | 4,295,036 | reference |
| Source ARM/`-O3`, GCC 15.3 | 4,502,576 | +207,540 vs fixture |
| Source Thumb-2/`-Os`, GCC 15.3 | 2,847,808 | −1,654,768 vs source ARM (−36.8%) |
| Source Thumb-2/`-Os` + LTO | 2,826,896 | −20,912 vs non-LTO Thumb (−0.73%) |

## Runtime checks

All three builds run against Forge-X's existing glibc and installed OpenSSL 3.2.3 /
SQLite 3.44.2 extensions. The [workload](../../../tests/qemu-harness/python-core-workload.py)
checks JSON round trips, SHA256, zlib, SQLite queries, ctypes calls into libc, SSL context
creation and an asyncio event loop. It then measures three batches of 5,000 JSON round
trips under QEMU user emulation:

| Build | Median seconds |
|---|---:|
| Fixture | 1.250 |
| Source ARM/`-O3` | 1.244 |
| Thumb-2/`-Os` | 1.542 |
| Thumb-2/`-Os` + LTO | 1.695 |

This small emulated workload took about **24% longer** with Thumb/`-Os` than the source
ARM control. LTO was another **10% slower** in this run. These measurements are exploratory,
not a hardware throughput or printing-latency prediction; host activity and QEMU's
translation affect timings. Do not call size optimization performance-neutral.

## Booted memory measurements

**18 fresh QEMU boots** used Cortex-A7, two guest CPUs, 128 MiB RAM, Feather mode,
swap off, a 15-second Klippy lead and 180-second settle period. The first nine boots
compared fixture/source ARM/Thumb variants concurrently (three each). A second cohort
compared non-LTO Thumb with LTO (three each, concurrently). Three final fresh boots
collected per-library resident-page measurements (one per source build). Each boot
used independent disposable image copies. Compare within cohorts; do not pool them.
Background network/update work was not synchronized, so these remain exploratory idle
measurements. No real MCU was present; Klippy's expected error state is not a print test.

| Cohort | Variant | Moonraker PSS, mean ± sample SD (KiB) |
|---|---|---:|
| Thumb trial | Shipped fixture | 32,186 ± 610 |
| Thumb trial | Source ARM/`-O3` | 32,508 ± 692 |
| Thumb trial | Thumb-2/`-Os` | 32,417 ± 2,232 |
| LTO trial | Thumb-2/`-Os` control | 31,719 ± 927 |
| LTO trial | Thumb-2/`-Os` + LTO | 31,152 ± 573 |

Thumb's mean difference versus the same-compiler ARM control is only **−91 KiB**,
with substantial overlap. LTO's separate-cohort difference is **−567 KiB**, also with
overlap. Neither establishes a reliable whole-process saving. Against the shipped
fixture, the first-cohort Thumb mean is actually +231 KiB. Do not promise a total RAM
reduction from the smaller on-disk file.

The independent page-accounting boots explain why total PSS alone is inconclusive:

| Source build | libpython RSS/PSS (KiB) | Library private clean / dirty (KiB) | Total Moonraker PSS (KiB) |
|---|---:|---:|---:|
| ARM/`-O3` | 3,208 / 3,208 | 2,380 / 828 | 32,090 |
| Thumb-2/`-Os` | 2,004 / 2,004 | 1,180 / 824 | 33,420 |
| Thumb-2/`-Os` + LTO | 1,992 / 1,992 | 1,168 / 824 | 32,890 |

**libpython's observed resident footprint falls 1,204 KiB (about 1.18 MiB) with
Thumb/`-Os`; LTO saves only another 12 KiB.** This is one page-accounting boot per variant,
not an established repeatable system-wide saving. Total anonymous PSS is almost identical
in these boots (25,664 / 25,656 / 25,660 KiB), while other file-backed mappings vary enough
to offset the library reduction. Resident Python code savings and whole-process savings
are different claims.

All 18 raw snapshots contain `/server/info` with zero failed components and warnings;
updater, Forge-X updater and OctoPrint compatibility remain loaded. Running source-build
artifact hashes and libpython mappings match the selected variants. Original firmware
fixture hashes were rechecked unchanged. The three final launchers completed normally.
Six LTO-cohort host launchers returned 2 in their final summary step after the shell source
was edited while they waited for QEMU; their guest probes completed and powered down.
Their raw logs were independently parsed and checked for complete snapshots, API results
and artifact hashes. No incomplete guest run is included.

[Retained measurement data](2026-10-28-forgex-python-opts.json) includes all individual
values, source/artifact hashes, actual compiler commands, ELF section sizes, workload
checks and raw serial-log hashes. `bash -n`, ShellCheck and artifact/flag/ABI assertions
passed. No default or production package is changed by this experiment.

Decision: Thumb/`-Os` demonstrably reduces the observed libpython resident pages and disk
size, with a slowdown in the emulated workload. LTO adds little library-size/resident
benefit in this test. Measure real hardware throughput, GUI behavior and print-load memory
before deploying either. Rebuilding other Buildroot libraries remains separate work.

## Reproduction

The retained local build root is `build/forgex-python-opts`. Download the two pinned archives
from the Python and GNU upstream release servers and verify their hashes above. Extract
them there. Build host Python out of tree using `--without-ensurepip --disable-test-modules`
and `make -j12`. For the glibc development sysroot, copy Reforge's sysroot `usr/include`
into a new `sysroot/usr/include`, then configure/build glibc out of tree with:

```sh
# Set TRIAL to the absolute build/forgex-python-opts path and CROSS to Reforge's
# absolute build/output/host/bin/arm-buildroot-linux-gnueabihf- prefix.
CC="${CROSS}gcc.br_real -mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard" \
  AR="${CROSS}ar" RANLIB="${CROSS}ranlib" \
  "$TRIAL/glibc-2.38/configure" --prefix=/usr \
    --host=arm-linux-gnueabihf --build=x86_64-pc-linux-gnu \
    --with-headers="$TRIAL/sysroot/usr/include" --disable-werror \
    --enable-kernel=5.4 CFLAGS='-O2 -g0'
make -j16
make install DESTDIR="$TRIAL/sysroot"
```

Build each Python variant into a new output directory:

```sh
tools/build/build-forgex-python-trial.sh thumb-os \
  "$TRIAL/Python-3.11.10" "$TRIAL/sysroot" \
  "$TRIAL/host-python/python" "$TRIAL/new-thumb-os"
# Repeat with arm-o3 and thumb-os-lto, using distinct fresh output directories.
FX_SET="display='FEATHER' use_swap='OFF'" SETTLE=180 \
  FX_PYTHON_ARTIFACTS="$TRIAL/new-thumb-os/artifacts" \
  tests/qemu-harness/mem-probe-forgex.sh python-thumb-os
```

Omit `FX_PYTHON_ARTIFACTS` for the shipped fixture control. Snapshots record the running
executable path, both core artifact hashes and libpython mappings to verify the intended
candidate actually loaded. Keep all other experiment knobs unset. No hardware flashing.
