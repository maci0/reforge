# Backlog

Ideas/tasks not yet scheduled into a plan.

## microgit — a tiny git client (Zig) for Moonraker's update_manager

**Why:** Moonraker's `git_repo` updater shells out to the full `git` CLI. Shipping real
git costs ~5–10 MB rootfs (git + `git-remote-https` + libcurl) just to satisfy one consumer.
A purpose-built client that implements *exactly* what Moonraker calls — and nothing else —
could be a fraction of that.

**Exact surface Moonraker requires** (from `moonraker/components/update_manager/git_deploy.py`,
verified 2026-06-01): the client is invoked as `git -C <path> <cmd>` and its **stdout/exit
codes are parsed**, so output must be byte-compatible with real git for:

| subcommand | form used |
|---|---|
| clone | `clone --branch <b> --filter=blob:none <url> …` (**partial clone** — needs the GitHub partial-clone protocol) |
| fetch | `fetch --all -p` / `fetch <remote> --prune --progress` |
| pull | `pull --progress` |
| checkout | `checkout -q <branch>` |
| reset | `reset --hard <ref>` |
| clean | `clean -d -f` |
| branch | `branch --list --no-color` |
| remote | `remote <get-url/set-url>` |
| config | `config <args>` |
| for-each-ref | `for-each-ref … --sort='-creatordate' --contains=HEAD` |
| rev-parse | `rev-parse <args>` |
| rev-list | `rev-list <args>` |
| describe | `describe <args>` |
| cat-file | `cat-file -e <commit>^{commit}` |
| merge-base | `merge-base --is-ancestor <a> <b>` |
| log | `log <current>..<ref>` |
| status | `status --porcelain -b` |
| fsck | `fsck --full` |

**Hard parts (why it's non-trivial):**
- **Smart-HTTP transport over TLS** to GitHub (the bulk of the work): pkt-line protocol,
  `git-upload-pack`, ref advertisement, want/have negotiation.
- **Partial clone** (`--filter=blob:none`) — blob-filtering + on-demand blob fetch.
- **Pack/delta**: parse packfiles, apply ofs/ref deltas, zlib inflate, verify SHA-1.
- **Output compatibility**: `status --porcelain`, `for-each-ref --format`-style output,
  `describe`, `rev-list` counts must match git's text exactly (Moonraker parses them).
- Loose+packed object store, refs, basic config.

**Scope notes:** read-mostly (no push, no merge, no rebase, no working-tree staging beyond
checkout/reset/clean). Could lean on libz (or Zig's deflate) + the system TLS already present.

**Status:** idea only. Lower priority than the OTA design below — if reforge OTA ships via
self-published `zip` releases (no git on device), this is unnecessary; it only matters if we
want true upstream `git_repo` OTA.

## reforge OTA design (decide before implementing)

Shipping `git` does **not** enable host (klipper/moonraker) OTA on the buildroot image:
`/opt/*` are not git checkouts, there's no `pip`, and no `gcc` (klipper's chelper recompiles
on source change). Working options:

1. **`web` updater for Mainsail** — git-free, works today (Mainsail ships GitHub release zips).
2. **`zip` updater against our own prebuilt reforge releases** — publish bundles in CI with the
   correct thumb2/NEON `c_helper.so` (timestamped so klippy won't recompile) + vendored deps;
   no git/gcc/pip on device. This is the clean path to full host OTA.
3. Status quo: USB `.tgz` reflash (no OTA).

## live USB: vfat + f2fs partitions (drop loopback) — DONE 2026-06-04

~~Replace the current single-FAT + loop-mounted-f2fs-image live USB with a 2-partition
stick.~~ Done: `tools/release/build-live-usb.sh` now emits a partitioned `.img.gz`
(MBR + p1 vfat 64 MiB + p2 f2fs label=`reforge-live`); `packaging/live/flashforge_init.sh`
finds p2 by label (`blkid -L reforge-live`) with fallbacks to p1-sibling derivation and
an F2FS-magic scan, and mounts it directly. `loop.ko` (and its
`MODULE_IMPORT_NS(VFS_internal_…)` patch on `loop.c`) is no longer built or shipped
— `modules/f2fs-bsp/` now produces only `crc32_generic.ko` + `f2fs.ko`. UX cost as
expected: the stick is now flashed (`dd` or balenaEtcher) instead of "extract a
tarball onto FAT". See `docs/live-mode.md` for the updated flash procedure. The
2-partition layout is gated by the existing qemu live-mode + live-OTA harnesses
(both now pass `F2FS_DEV=/dev/vdb` to the launcher); real-hardware re-verification
pending the next trial.

## live klippy: respawn after CRC-mismatch auto-restart

On the first ReForge live boot after the printer has run forge-x, the AD5M MCUs still
hold forge-x's config CRC. ReForge's klippy connects, detects the mismatch, resets the
MCUs and "Restarts printer" to reconfigure them — but `mod/init.d/S60klipper` launches
klippy via `start-stop-daemon -S -b` with **no respawn**, so klippy exits on that restart
and is never relaunched → GuppyScreen sits at "waiting for printer". Manually relaunching
klippy once (MCUs now reset/clean) reaches `ready` immediately. Fix: supervise klippy in
live mode (respawn loop, or a watchdog that relaunches on exit) so the reset→reconfigure
cycle converges on its own. Found during the 2026-06-02 hardware MCU-link bring-up; the
link itself works (both MCUs, real temps) once klippy is relaunched.

## AD5M MCU firmware vs host Klipper version skew (adxl345 / input shaping)

The AD5M MCU firmware (build 2023-03-17) predates ReForge's host Klipper, and the
`query_adxl345` command format changed in between (`oid rest_ticks` vs `oid clock
rest_ticks`) → "MCU Protocol error: Command format mismatch" the moment klippy configures
the accelerometer. `[adxl345]`/`[resonance_tester]` are currently disabled in
printer.base.cfg to reach `ready`. To re-enable resonance testing / input-shaper
auto-cal, rebuild + flash the AD5M MCU firmware from a Klipper matching the host version
(careful: reflashing the mainboard MCU is higher-risk than host-side changes). Everything
else in the MCU protocol (steppers, heaters, thermocouples, both MCUs' 105 commands)
matches fine — this is the one version-locked feature.

## live mode: decouple from the stock rootfs (run our userspace in the chroot)

Today the launcher runs `net-up` and a few bring-up steps **pre-chroot, in stock's
userspace**, leaning on stock's `wpa_supplicant`/`udhcpc`/`/etc/wpa_supplicant.conf`.
That coupling is exactly what caused the 2026-06-02 wifi bugs (the network stored
`disabled=1`; `/etc/wifi/udhcpc_wlan0` is a procd service-wrapper, not a udhcpc event
script). Reduce reliance on the original rootfs:

- Move network bring-up **post-chroot**, using the f2fs's own `wpa_supplicant` + `udhcpc`
  + a conf we control (immune to stock's `disabled=1`/wrapper quirks). Read the SSID/PSK
  from stock once (read-only) and write our own clean conf to tmpfs.
- Leave only the unavoidable hard stock deps: the **kernel**, the vermagic-locked wifi
  `.ko` (`8821cu`), and the tiny `chroot`/`mount`/`insmod` bootstrap.
- Optional: `pivot_root` inside a private mount namespace (`unshare -m`) for cleaner
  isolation than `chroot`.

NOT `switch_root`: we are not PID1 (stock init launches us late via `auto_run`, with the
panel UI + many stock procs already running), `switch_root` is an initramfs-era tool that
would tear down the running stock system, and it wouldn't change the (stock) kernel or the
vermagic-locked driver anyway. Brick-safety comes precisely from being a non-invasive
guest under stock init (pull USB → pristine stock). Raised 2026-06-02.

## forge-x: one shared python for klippy + moonraker (drop the 2nd interpreter's RSS) — CLOSED (negative)

> **Closed 2026-06-03: net RAM LOSS, do not pursue.** Built end-to-end and live-tested on a
> 5M Pro (`contrib/forge-x-shared-python/`). klippy runs **Ready** under moonraker's py3.11
> from the host root (chroot interpreter via host loader symlink + PYTHONHOME/PYTHONPATH/
> LD_LIBRARY_PATH; a `gcode_shell_command` env-strip keeps host soft-float macros working),
> with MCUs + macros intact. **But it regresses RAM ~16 MB**: stock klippy@py3.7 Pss 7.3 MB
> Ready vs py3.11 23.2 MB; libpython3.11 COW-sharing with moonraker only reclaims ~1 MB. The
> premise was backwards — py3.7 is the *lean* interpreter, so consolidating onto the heavier
> py3.11 costs far more than the shared pages save. Reusable findings live in the contrib
> README (host-launch of a chroot binary; the gcode_shell_command env leak). Real wins stay
> jemalloc + zram + vmtune. Original analysis kept below for context.

forge-x runs **two** interpreters: stock klippy on **soft-float Python 3.7** (`/opt/Python-3.7.11`,
`ld-linux.so.3`) and moonraker on a **hard-float Python 3.11** venv (`/root/moonraker-env`,
`ld-linux-armhf.so.3`). Different version AND different float ABI ⇒ no COW sharing ⇒ real
double-RSS. Verified in the qemu virt harness: klippy *runs* under moonraker-env's 3.11 (all
python deps import once `cffi`+`pycparser`+`greenlet` cp311 hard-float wheels are added — moonraker-env
already has jinja2/pyserial/numpy), but it cannot `dlopen` the stock **soft-float** `c_helper.so`
into the **hard-float** 3.11 process → `OSError: ... internal error`.

Unblock = ship a **hard-float `c_helper.so`** (the only soft-float blocker; klipper compiles it on
the host with gcc, which the device lacks). `tools/build-chelper-hardfloat.sh <klippy/chelper>`
cross-compiles it from forge-x's OWN chelper sources (so the cffi cdef matches) using ReForge's
buildroot armhf toolchain — Cortex-A7 NEON-VFPv4 hard-float, mirrors `br-external/package/klipper/klipper.mk`.

Recipe (reversible):
1. `scp -r root@PRINTER:/opt/klipper/klippy/chelper /tmp/fx-chelper`
2. `tools/build-chelper-hardfloat.sh /tmp/fx-chelper` → hard-float `c_helper.so`; copy it back to
   `/opt/klipper/klippy/chelper/` on the device.
3. Vendor `cffi`+`pycparser`+`greenlet` cp311 armv7 (hard-float) wheels into
   `/root/moonraker-env/lib/python3.11/site-packages/`.
4. Point forge-x's `S60klipper` python at `/root/moonraker-env/bin/python3`.
Final confirmation must be on real hardware (klippy → MCU connect). The other direction
(moonraker on stock soft-float 3.7) is impossible — moonraker needs ≥3.8 and there's no soft-float
3.11. ReForge avoids all this: all-hard-float, one interpreter by design.
