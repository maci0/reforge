# forge-x: shared Python interpreter for klippy + moonraker (opt-in)

Run **klippy under moonraker's Python 3.11 venv** instead of the separate stock
soft-float Python 3.7, so the two processes **share one resident interpreter**
(libpython3.11 + common libs are COW-shared) — dropping the second interpreter's
resident set on the ~110 MB AD5M. Fully opt-in and reversible; built to be PR'd to
forge-x after a live trial.

## Why two interpreters today (the blocker)

forge-x ships **two different ABI worlds**:

| | interpreter | float ABI | loader |
|---|---|---|---|
| klippy | `/opt/Python-3.7.11` (3.7) | **soft-float** | `ld-linux.so.3` |
| moonraker | `/root/moonraker-env` (3.11) | **hard-float** | `ld-linux-armhf.so.3` |

Different version *and* float ABI → no page sharing → real double-RSS. You can't just
point klippy at the 3.11 venv: its stock `c_helper.so` is **soft-float** and a soft-float
`.so` cannot `dlopen` into the hard-float 3.11 process (`OSError: ... internal error`).

## What this does

1. Cross-builds a **hard-float `c_helper.so`** from forge-x's *own* klipper chelper
   sources (so the cffi cdef matches that klipper version) — `c_helper.hf.so`.
   See `../../tools/build-chelper-hardfloat.sh` (no gcc on the device; uses a cross
   toolchain off-device).
2. Adds klippy's C-ext deps to the 3.11 venv: **`cffi` + `pycparser` + `greenlet`**
   (cp311 hard-float wheels from piwheels — moonraker-env already has jinja2/pyserial/numpy).
3. Patches `/opt/klipper/start.sh` to a **flag-gated** interpreter select: when the flag
   is present it launches klippy with `/root/moonraker-env/bin/python3` + the hard-float
   `c_helper.so`; when absent it is byte-for-byte the stock 3.7 launch.

## Enable / disable (reversible)

```sh
# on the device (after staging c_helper.hf.so + the 3 wheels here — see Build):
./shared-python.sh enable     # patch start.sh (idempotent), swap in hard .so, set flag, restart klippy
./shared-python.sh disable    # clear flag, restore the soft .so, restart klippy (stock 3.7 again)
./shared-python.sh status
```

The toggle is just a flag file (`/opt/config/mod_data/shared_python`); `start.sh` falls
back to stock when it's absent, so `disable` (or removing the mod) leaves a stock launch.

## Build the artifacts (off-device, once per klipper version)

```sh
# 1. hard-float c_helper.so from forge-x's klipper chelper:
scp -r root@PRINTER:/opt/klipper/klippy/chelper /tmp/fx-chelper
../../tools/build-chelper-hardfloat.sh /tmp/fx-chelper ./c_helper.hf.so
# 2. cp311 armv7 (hard-float) wheels:
mkdir -p wheels && cd wheels
for w in cffi/cffi-2.0.0-cp311-cp311-linux_armv7l \
         greenlet/greenlet-3.5.1-cp311-cp311-linux_armv7l \
         pycparser/pycparser-2.22-py3-none-any; do
  curl -sO "https://www.piwheels.org/simple/$w.whl"; done
# 3. scp this whole dir to the printer, then ./shared-python.sh enable
```

## Memory impact

- **BEFORE** (measured live, idle): klippy@py3.7 Pss **14.3 MB** (its own libpython3.7) +
  moonraker@py3.11 (see forge-x/ReForge memory docs for the moonraker figure — it already
  carries the jemalloc/arena optimizations, so use the documented baseline).
- **AFTER**: klippy@py3.11 shares moonraker's already-resident libpython3.11 → klippy's
  unique resident drops to roughly its own code/heap (the interpreter pages are shared).
  The win is the libpython3.11 + common-lib pages counted **once** instead of twice.
  Confirm live with `smaps_rollup` Pss before/after (the qemu harness proved klippy runs
  under py3.11 + the hard-float `.so`; the exact MB is best measured on hardware because
  py3.7 vs py3.11 interpreter sizes differ).

> Measure on hardware:
> ```sh
> for p in $(ps w | grep -E '[k]lippy.py|[m]oonraker.py' | awk '{print $1}'); do
>   awk '/^Pss:/{s+=$2} END{print FILENAME": "s" kB"}' /proc/$p/smaps_rollup; done
> ```

## PR to forge-x

The forge-x-idiomatic version: make `start.sh`'s interpreter select read a
`mod_data/variables.cfg` entry (e.g. `shared_python = 1`) via `zconf.sh`, ship the
cross-built `c_helper.hf.so` + the wheels in the mod, and install the wheels into
moonraker-env at mod-install time. This `contrib/` package is the standalone proof +
the start.sh patch to lift into that PR.

## Caveats

- Only the **soft-float `c_helper.so`** blocks the unification; everything else (klippy's
  python code, the other deps) runs on 3.11.
- The hard-float `c_helper.so` MUST be built from the **same klipper version** running on
  the device (the tool reads `SOURCE_FILES` from that chelper's `__init__.py`).
- The other direction (moonraker on stock 3.7) is impossible — moonraker needs ≥3.8 and
  there is no soft-float 3.11.
