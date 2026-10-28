# Forge-X Buildroot-only memory levers

Date: 2026-10-28. Tested local Forge-X `1.4.2-beta-4` fixture; no product changes.
The Tina BSP, its libc/Python, stock Klippy and kernel remain outside this work.

## What transfers from Reforge

| Lever | Fit for Forge-X's mod Buildroot | Evidence / decision |
|---|---|---|
| **Thumb-2 + `-Os`, then LTO** | Rebuild the mod's Python, shared libraries and native extensions, retaining glibc and ARM hard-float ABI | Best next **build** experiment. Bundled Python 3.11.10 records `-O3`; its exported `Py_Initialize`, `PyObject_Malloc`, `PyEval_EvalCode` functions have ARM addresses. Reforge previously measured −4.9 MB stack PSS for its combined Thumb-2/size/purge change, but that includes stock-side Klippy and is **not a Forge-X savings estimate**. No new Forge-X compiler variant built here. |
| **Tuned jemalloc for Moonraker** | Add source-built jemalloc to the mod and preload it in `S65moonraker` only | Runs and passes API checks; longer-run mean −1.64 MiB PSS, with substantial overlap/noise. Candidate for workload testing, not established production savings. |
| **Remove unused optional Moonraker features** | Remove `[octoprint_compat]` and disabled `[webcam Example]` when unused | Longer-run mean −1.88 MiB PSS, the most consistent trim tested. Combined treatment; cannot attribute the entire difference to OctoPrint. Losing OctoPrint compatibility affects clients using that API. |
| **Lazy updater imports** | Port Reforge's lazy `PackageDeploy` / `PythonDeploy` imports to Forge-X's older ZipDeploy implementation | Not tested here. System updates are disabled already, so PackageKit can potentially stay unloaded. Forge-X still uses a `git_repo` updater: lazy Git imports alone cannot avoid that backend. Preserve update functionality. |
| Newer GCC, same libc family | Rebuild only the mod's userspace with a newer toolchain | Reforge's old −10.16 MB result bundled compiler/library/build differences, including Klippy; cannot transfer that number to this mod. Measure after Thumb-2/`-Os`. |
| Smaller native GUI build | Size-optimize GuppyScreen and its dependencies inside the mod | Valid build candidate; not measured in this Feather-mode test. Must check rendering and responsiveness. |

Already present in the tested Forge-X checkout: BusyBox httpd, Moonraker and GuppyScreen
`MALLOC_ARENA_MAX=2`, Moonraker `TMPDIR` on storage, and `file_system_observer: none`.
Those are not new wins to count again. Sharing Reforge's single Python between Klippy and
Moonraker would cross the requested boundary: stock Klippy uses Tina Python 3.7, while the
mod uses Python 3.11. No kernel, CMA, device-tree or stock-libc changes are proposed.

For the first build variant, use `BR2_ARM_INSTRUCTIONS_THUMB2=y` and
`BR2_OPTIMIZE_S=y`, inspect actual Python compiler commands to ensure a later `-O3` does
not override them, and test LTO separately with `BR2_ENABLE_LTO=y` where supported.
Retain the Cortex-A7/hard-float ABI. Smaller files are not themselves proof of resident
memory savings; repeat PSS and API/GUI checks. Smaller code can change CPU performance.

## Tests performed

24 fresh QEMU boots, Cortex-A7, 128 MiB, two guest CPUs, Feather mode, swap off, no MCU.
Same image fixtures and virt test kernel throughout. The QEMU bootstrap skips the stock
firmware UI; experiment mutations touch only mod config/init scripts and a library inside
its Buildroot chroot. No printer or production filesystem was changed.

Five treatments, three boots each, initially with `SETTLE=60` seconds after a 15-second
Klippy lead. Three promising/control treatments then repeated three times each with
`SETTLE=180`. These are separate cohorts; compare within a cohort. First short round was
serial, remaining short rounds ran in batches of up to three, and nine long runs ran
concurrently with separate image copies on a 32-thread/128-GB host. Guest limits stayed
identical. Sampling begins roughly 40 seconds after boot plus the settle interval, rather
than at a fixed time after Moonraker reports ready. Background update/network work was
not synchronized, so these remain exploratory idle measurements.

PSS values below are KiB, mean ± sample standard deviation; delta is relative to the
same cohort's default. PSS accounts for shared pages; RSS and virtual address space are
not interchangeable with it.

| Treatment | 60s Moonraker PSS | Δ | 180s Moonraker PSS | Δ |
|---|---:|---:|---:|---:|
| Default | 32,668 ± 1,151 | — | 33,745 ± 1,309 | — |
| Trim OctoPrint + example webcam | 31,715 ± 364 | −953 | 31,821 ± 359 | −1,924 |
| Tuned jemalloc | 31,344 ± 1,388 | −1,324 | 32,066 ± 1,505 | −1,679 |
| glibc trim + no tcache | 32,461 ± 1,851 | −207 | not repeated | — |
| Trim + remove update services/history config | 32,366 ± 718 | −302 | not repeated | — |

The glibc treatment sets `MALLOC_TRIM_THRESHOLD_=0`,
`MALLOC_MMAP_THRESHOLD_=131072` and `GLIBC_TUNABLES=glibc.malloc.tcache_count=0`,
keeping the existing arena cap. It does not demonstrate a useful reduction.

Jemalloc is Reforge's source-built **5.3.1**, 399,708 bytes, with:

```sh
LD_PRELOAD=/usr/lib/libjemalloc-probe.so
MALLOC_CONF=narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0
```

The exact library hash and source fixture hashes are recorded in the
[measurement data](2026-10-28-forgex-buildroot-memory.json). The tested shared object
matches the local source-build output. Its symbol requirements fit the mod's glibc 2.38;
this is a test injection, not a deployable Forge-X package recipe. Rebuild against
Forge-X's SDK before shipping. Every jemalloc run records the process environment and
an executable mapping of that library, confirming it was actually loaded.

All 24 `/server/info` responses had **zero failed components and zero warnings**;
Klippy, Moonraker and httpd were present in every memory snapshot. Expected components
were checked: trimmed runs lacked OctoPrint compatibility, lean runs lacked update_manager
and feather_updates, and **history remained loaded in all runs**. Moonraker treats history,
webcam and announcements as core components: merely deleting config sections does not
remove them. Removing the updater loses Forge-X/GUI/web-client update features without a
clear gain in this test, so retain it.

Do not stack the treatment deltas: the combination was not measured. Three samples and
variable startup/background activity do not establish statistical confidence or print-load
behavior. The longer runs preserve the direction of the trim/jemalloc means, but allocator
samples overlap baseline. This is enough to prioritize further tests, not promise 3.5 MiB
of combined savings. No allocator throughput, upload/timelapse stress or real printing test
was performed. **Do not preload jemalloc into stock Klippy**: Reforge previously observed
real-hardware `c_helper.so` heap corruption with that combination.

## Reproduction

The harness now supports independently named image copies and the three Moonraker knobs:

```sh
FX_SET="display='FEATHER' use_swap='OFF'" SETTLE=180 \
  tests/qemu-harness/mem-probe-forgex.sh control

FX_SET="display='FEATHER' use_swap='OFF'" SETTLE=180 \
  FX_MOONRAKER_PROFILE=trim \
  tests/qemu-harness/mem-probe-forgex.sh trim

FX_SET="display='FEATHER' use_swap='OFF'" SETTLE=180 \
  FX_MOONRAKER_JEMALLOC="$PWD/build/output/target/usr/lib/libjemalloc.so.2" \
  tests/qemu-harness/mem-probe-forgex.sh jemalloc
```

Use `FX_MOONRAKER_MALLOC=1` for the glibc trial and
`FX_MOONRAKER_PROFILE=lean` for the update-removal trial. Use distinct labels for parallel
runs. Raw serial log paths/hashes, individual PSS measurements and input hashes are in the
JSON data. Original fixture hashes were rechecked unchanged after the experiments.
Harness `bash -n`, ShellCheck and result assertions passed. No unrelated build/test suite
was rerun for these test-harness and research-document changes.
