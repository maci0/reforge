# forge-x: shared Python interpreter for klippy + moonraker (opt-in)

> **NEGATIVE RESULT (do not ship for memory).** Live-tested on a 5M Pro: it works —
> klippy runs Ready under moonraker's py3.11 with all macros intact — but it **regresses RAM
> by ~16 MB**. Stock klippy@py3.7 is the *lean* interpreter (Pss 7.3 MB Ready); py3.11 is
> much heavier (Pss **23.2 MB** Ready). COW-sharing libpython3.11 with moonraker saves only
> ~1 MB (Rss 4.1 / Pss 3.1 MB), nowhere near the +16 MB the py3.11 base/site-packages cost.
> The original premise (two interpreters = wasteful duplication) was backwards: the second
> interpreter (3.7) is the *small* one. Kept as a documented experiment + a reusable
> host-launch recipe; **not** a memory optimization. The real wins stay jemalloc + zram +
> vmtune.

The idea: run **klippy under moonraker's Python 3.11** instead of the separate stock
soft-float Python 3.7, so the two map the **same libpython3.11 inode** (COW-shared once
instead of resident twice) on the ~110 MB AD5M. It is reversible and flag-gated. The
sections below document how forge-x is actually laid out, the two launch models tried, and
why the win didn't materialize.

## The layout (why this is hard)

forge-x ships **two ABI worlds in two roots**:

| | interpreter | root | float ABI | loader |
|---|---|---|---|---|
| klippy | `/opt/Python-3.7.11` (3.7) | host `/` | **soft-float** | `ld-linux.so.3` |
| moonraker | `/root/moonraker-env` (3.11) | **chroot** `/data/.mod/.forge-x` | **hard-float** | `ld-linux-armhf.so.3` |

moonraker runs as `chroot /data/.mod/.forge-x .../python3`. Its hard-float python3.11 +
glibc 2.38 live **inside that chroot**; `/root/moonraker-env` does **not** exist in the
host root where `start.sh` runs. Walls:

1. Different version *and* float ABI → no page sharing today.
2. Stock `c_helper.so` is **soft-float** and cannot `dlopen` into a hard-float 3.11 process
   (`OSError: ... internal error`). Fixed by cross-building a hard-float `c_helper.so` from
   forge-x's own chelper sources — see `../../tools/build-chelper-hardfloat.sh`.
3. The host soft-float glibc and the chroot hard-float glibc share the same lib SONAMEs at
   `/lib` `/usr/lib`. They cannot occupy those paths simultaneously, so you can't just
   bind-mount the venv into the rootfs.

## Two launch models tried

**(a) klippy inside the chroot** (`chroot $MOD .../python3 klippy.py`). The chroot
bind-mounts `/opt/klipper`, `/opt/config`, `/tmp` (uds) and `/dev/ttyS1`+`/dev/ttyS5`, so
klippy connects to both MCUs. **But** klippy's `gcode_shell_command` macros (`S98camera`,
`screen`, `reboot`, `zmem`, …) exec **host rootfs** scripts that need the host userland;
inside the chroot they fault (`gcode.CommandError: Error running command {S98camera}`) and
klippy never reaches Ready. **Rejected.**

**(b) klippy from the host root, using the chroot's python (shipped here).** Keeps host `/`
as klippy's filesystem (macros work) while running the hard-float py3.11:

1. Add host symlink `/lib/ld-linux-armhf.so.3 → $MOD/lib/ld-linux-armhf.so.3` (the binaries
   hardcode that interp path, absent on the host).
2. Launch the **base** `$MOD/usr/bin/python3.11` (the venv wrapper is an older build that
   faults from host) with `PYTHONHOME=$MOD/usr`, `PYTHONPATH=<venv site-packages>`,
   `LD_LIBRARY_PATH=$MOD/usr/lib:$MOD/lib`, and the hard-float `c_helper.so`.
3. That `LD_LIBRARY_PATH` would break host soft-float macro children (busybox: libc ABI
   mismatch → `internal error`). klipper's `gcode_shell_command` `Popen` has no `env=`, so
   we patch it to spawn children with `LD_LIBRARY_PATH`/`PYTHONHOME`/`PYTHONPATH`/`VIRTUAL_ENV`
   stripped. With that, camera/screen/reboot run fine and klippy reaches Ready.

Model (b) is what `shared-python.sh` implements. It is correct and reaches Ready — it just
doesn't save memory (see banner).

## Klippy deps in the venv

moonraker-env already has jinja2/pyserial/numpy; klippy additionally needs **cffi +
pycparser + greenlet** (cp311 hard-float wheels from piwheels). On-device pip hangs on its
PyPI version-check, so the toggle **unzips the wheels** straight into the venv
site-packages (a wheel is a zip; sufficient for import-only deps).

## Enable / disable (reversible)

```sh
# on the device (after staging c_helper.hf.so + the 3 wheels here — see Build):
./shared-python.sh enable     # verify launch, patch start.sh + gcode_shell_command, add ld symlink, set flag, restart
./shared-python.sh disable    # clear flag, restore gcode_shell_command, drop ld symlink, restore soft .so, restart
./shared-python.sh status
```

The flag is `/opt/config/mod_data/shared_python`; `start.sh` falls back to the byte-for-byte
stock 3.7 launch when it's absent. `enable` self-checks (`verify_launch`) that the host
py3.11 can import the deps and dlopen the hard-float chelper **before** touching the launcher.

## Build the artifacts (off-device, once per klipper version)

```sh
# 1. hard-float c_helper.so from forge-x's klipper chelper (scp lacks sftp-server — tar over ssh):
mkdir -p /tmp/fx-chelper
ssh root@PRINTER 'tar -C /opt/klipper/klippy/chelper -cf - .' | tar -C /tmp/fx-chelper -xf -
../../tools/build-chelper-hardfloat.sh /tmp/fx-chelper "$PWD/c_helper.hf.so"
# 2. cp311 armv7 (hard-float) wheels:
mkdir -p wheels && cd wheels
for w in cffi/cffi-1.16.0-cp311-cp311-linux_armv7l \
         greenlet/greenlet-3.5.1-cp311-cp311-linux_armv7l \
         pycparser/pycparser-2.22-py3-none-any; do
  curl -fsSLO "https://www.piwheels.org/simple/$w.whl"; done
# 3. push this dir to the printer, then ./shared-python.sh enable:
#    tar -cf - shared-python.sh c_helper.hf.so wheels | ssh root@PRINTER 'mkdir -p /tmp/sp && tar -C /tmp/sp -xf -'
```

## Measured (live, 5M Pro)

```sh
for p in $(ps w | grep -E '[k]lippy.py|[m]oonraker.py' | awk '{print $1}'); do
  awk '/^Pss:/{s+=$2} END{print FILENAME": "s" kB"}' /proc/$p/smaps_rollup; done
```

| | stock py3.7 (Ready) | shared py3.11 host-launch (Ready) |
|---|---|---|
| klippy Pss | **7,275 kB** | **23,245 kB** (+16 MB) |
| libpython3.11 in klippy | — | Rss 4,104 / Pss 3,118 kB (~1 MB shared w/ moonraker) |

Net: ~16 MB worse. Functional in every other respect.

## Lessons (the reusable parts)

- **Running a chroot's binary from the host root, no chroot:** host symlink for its loader
  + `PYTHONHOME`/`PYTHONPATH`/`LD_LIBRARY_PATH` → it runs with host `/` as filesystem. Useful
  any time you want a forge-x-chroot tool to act on host paths.
- **`gcode_shell_command` leaks klippy's env to macros** (no `env=` on `Popen`); a hard-float
  `LD_LIBRARY_PATH` in klippy's env bricks host soft-float macro scripts. Strip it for children.
- **`internal error` from the loader == float-ABI mismatch**, not a generic failure.
- The hard-float `c_helper.so` MUST be built from the **same klipper version** on the device
  (the tool reads `SOURCE_FILES` from that chelper's `__init__.py`); it is host-side code,
  unrelated to MCU firmware v11/v13.
