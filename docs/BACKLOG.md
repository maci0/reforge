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

## immutable / atomic ReForge — OverlayFS2 (or similar) for transactional updates and true Mode 1 live

**Status (2026-06-05):** spike complete — see
[`docs/research/2026-06-05-overlayfs-on-bsp-spike.md`](research/2026-06-05-overlayfs-on-bsp-spike.md).
All five open questions below are answered. OverlayFS builds clean as a 122 KB
loadable module from the vanilla BSP source, mounts with correct semantics, and
costs ~192 KiB MemAvailable per mount on the test rig — well inside our budget.
The direction can be elevated from "parked" to a concrete implementation plan;
proposed next-step delivered as [`docs/plans/2026-06-05-immutable-reforge.md`](plans/2026-06-05-immutable-reforge.md), covering the
versioned-overlay layout + atomic install/OTA/rollback path + true-Mode-1 live
with `lowerdir=/data + upperdir=tmpfs`.

A future architectural direction worth investigating, parking here for design /
prior-art work before any implementation.

**Two motivations, one substrate:**

1. **Atomic updates for Mode 2 / Mode 3** (`docs/deployment-modes.md`). Today the
   installer + OTA write directly into `/data/.mod/.reforge/` — a power loss
   mid-update can leave a half-installed mod (we mitigate with LKG bookkeeping +
   a trial-N-fails rollback, but that's bookkeeping over a non-atomic write).
   An overlay-fs structure where each version is a distinct lower layer and
   updates swap which one is the upper would make installs and rollbacks
   atomic by construction (commit = pointer swap, rollback = drop the upper
   and remount). Same model openSUSE MicroOS / Fedora Silverblue / NixOS use,
   adapted to a `/data/.mod/.reforge/<version>/` layout instead of btrfs subvols.
2. **True Mode 1 live** (`docs/deployment-modes.md` §"Mode 1 — Live"). An
   overlay with `lowerdir=/data` + `upperdir=tmpfs` gives the live launcher a
   `/data` that shows the user's existing gcodes but writes go to RAM — the
   pull-stick-and-everything-is-as-it-was semantics we want for a true
   trial mode, without depending on Mode 3's own-kernel work.

**Open questions to investigate before scheduling:**

- **OverlayFS in stock kernel:** `CONFIG_OVERLAY_FS` is **not** set in the
  stock 5.4.61 BSP build (`docs/board-notes/stock-kernel-config-5.4.61.txt.gz`).
  Can we build it as a loadable module against the BSP source (same recipe as
  `modules/f2fs-bsp/`), or is it kernel-config-only? `fs/overlayfs/Kconfig`
  marks it `tristate "Overlay filesystem support"` so module build is
  reachable in theory; need to verify the BSP source compiles it as `=m` cleanly.
- **OverlayFS2 vs the stock 5.4 overlayfs:** OverlayFS in 5.4 has known issues
  with concurrent writes, redirect_dir, and metacopy that newer kernels fix.
  How much of "OverlayFS2" (the term sometimes refers to specific OCI-friendly
  improvements) is actually a separate filesystem vs. just newer overlayfs
  semantics? Map exactly what we need (overlayed lower + writable upper +
  workdir, no redirect_dir, no nested overlays for v1) to what 5.4 supports.
- **Memory implications:**
  - Per-mount overhead of one overlayfs instance (the in-kernel struct +
    inode cache): expected small, but on a 128 MB box every MB matters.
  - tmpfs `upperdir` size for Mode 1 live: needs to cap somewhere short of
    eating RAM. A few hundred MB is plenty for SAVE_CONFIG appends + a
    moonraker DB but blows the budget if the user uploads gcodes (which
    can easily be 50–500 MB each). Probably want a separate Mode 1 policy:
    `[virtual_sdcard] path` is **not** in the overlay; uploads go to a
    distinct tmpfs path with its own size cap.
  - Page cache implications of stacking: every read from a lower layer page
    can mean two cache lookups; not free but small.
- **Atomic-install layout choice:**
  - `/data/.mod/.reforge/versions/<ver>/` lower layers, `/data/.mod/.reforge/current` pointer
  - vs. side-by-side `mod` + `mod.new`, atomic rename swap (today's approach,
    not actually overlay-fs at all)
  - vs. real subvol-style (would need btrfs on `/data` — huge change)
  - The pointer-swap-overlay option is the most ReForge-friendly: small,
    no filesystem swap, works on ext4 `/data`.
- **Mode 3 alignment:** when ReForge ships its own kernel (Plan 5),
  CONFIG_OVERLAY_FS is trivially `=y` and we get OverlayFS "for free". Any
  Mode 2 design that uses overlay would carry over to Mode 3 with minimal
  changes — worth designing for that future even if we don't ship it on
  the stock kernel.

**Suggested next step:** a short research note (`docs/research/`) that
benchmarks overlayfs-as-module on the stock 5.4.61 BSP (does it load, does it
mount cleanly, what's the per-mount RSS overhead, what's the cold-read penalty
on a klippy startup) before any architectural commitment. Probably a half-day
spike.

## Mode 3 net stack: switch to iwd, skip ConnMan

For Mode 3 (full replacement, Plan 5) the network daemon should switch from
`wpa_supplicant` to `iwd`. Reasons aligned with the deployment-modes
roadmap:

- Mainline-LTS kernel + `rtw88` driver for the RTL8821CU (mainline since
  5.16) has proper, well-tested cfg80211 support — unlike the current
  Realtek-vendor staging driver, which has unknown nl80211 completeness for
  iwd's full API surface.
- iwd is genuinely smaller and cleaner: ~900 KB binary + ~150 KB `ell` lib,
  no `libssl`/`libcrypto` dependency (vs wpa_supplicant ~1.2 MB + OpenSSL),
  ~2–3 MB RSS at runtime (vs ~5–6 MB).
- D-Bus interface is more uniform than `wpa_cli` action scripts for the
  "am I online?" / "current SSID" / "signal strength" queries Mainsail and
  GuppyScreen are likely to want eventually.

**Skip ConnMan** even in Mode 3. A single-network printer doesn't need
the full connection-manager state machine; the +3 MB glib2 dependency
fully erases iwd's RSS savings and then some. A 30-line shell wrapper
over `iwd` D-Bus calls is plenty for our use case.

**Note (2026-06-05):** iwd was added to the Mode 2 rootfs as an
*available* binary (not the default daemon), enabled via
`BR2_PACKAGE_IWD=y` so we can A/B `iwctl` against `wpa_supplicant` on
the AD5M's rtl8821cu USB driver and prove the staging driver's nl80211
implementation supports iwd before committing to it in Mode 3. The
default daemon in net-up.sh stays `wpa_supplicant -Dnl80211` until that
experiment passes.

## wifi event marker: `[ -f /run/reforge-wifi-up ]` primitive

Forge-x's `.shell/boot/wifi_reconnect.sh` maintains a `$WIFI_CONNECTED_F`
marker file via `wpa_cli` action-script hooks: `touch` on `CONNECTED`,
`rm -f` on `DISCONNECTED`. Other forge-x components answer "am I online?"
with a single `[ -f "$WIFI_CONNECTED_F" ]` test — no `wpa_cli status`
parsing, no `ip link` polling, no syscall round-trip.

ReForge has the actual association logic (`packaging/live/net-up.sh`) but
not the marker. Adding it is a ~20-line shell script + one
`wpa_cli -B -a <script> -i wlan0` line in `net-up.sh` after
`wpa_supplicant` launch.

Proposed file: `br-external/board/reforge/rootfs-overlay/mod/.shell/wifi-event.sh`.
Proposed marker path: `/run/reforge-wifi-up` (tmpfs — auto-clears each boot,
so a stale marker can't survive a crash; no eMMC writes).

See [`docs/board-notes/fw-upgrade-mechanisms.md`](board-notes/fw-upgrade-mechanisms.md)
"Footnote A — `/bin/wifi_reconnect` is a misnomer" for the analysis of
stock vs forge-x wifi_reconnect scripts (both are logging stubs, not
reconnectors). Tiny utility, no urgency, parked here so it isn't lost.

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

## Cloud-block hardening: iptables for IP-literal stock endpoints

The current cloud-block (`/etc/hosts`) handles hostname-based stock endpoints
(VoxelShare, NetEase IM, sz3dp, etc.) but misses the **IP-literal** ones that
`firmwareExe` hardcodes:

- `http://10.33.11.172:32112/api/updates/check` (FlashForge internal dev update server)
- `http://10.33.23.222` (legacy update host)
- `rtmp://115.231.29.49:2045/...` (test RTMP)

A LAN with one of these subnets present (e.g. corporate network, or attacker
spoofing) would route the connection through. Closing the gap is one iptables
rule per subnet, added to `reforge-boot` alongside the existing `/etc/hosts`
edit:

```sh
iptables -A OUTPUT -d 10.33.11.0/24 -j REJECT
iptables -A OUTPUT -d 10.33.23.0/24 -j REJECT
iptables -A OUTPUT -d 115.231.29.49 -j REJECT
```

Source of the IP literals: `docs/security-findings.md` finding #6,
`docs/reverse-engineering/firmwareexe-ota-update.md` §1.

Estimated work: < 30 minutes. Worth doing as part of the next reforge-boot
edit pass.

## Sigstore / cosign signatures on ReForge OTA artifacts

Today's ReForge OTA fetches per-component zips from a GitHub Release. The
integrity story is "you trust this GitHub repository" \u2014 there's no signature
verification on the downloaded zip beyond the implicit TLS-to-github.com trust.

This is one notch better than stock (stock = MD5 with the manifest *inside*
the package, see `docs/security-findings.md` finding #5), but it's still
weaker than what we should ship. Two upgrade paths:

1. **Sigstore / cosign**: sign each release zip with a project signing key
   (or with a sigstore Fulcio-issued cert), embed the signature alongside
   the artifact, verify on the device before extracting. The device-side
   verifier is `cosign verify-blob`-equivalent in ~150 lines of go or python.
2. **Minisign**: same idea, much smaller code footprint (one C source file,
   no go toolchain). Single project signing key, public key shipped in the
   image. Closer to the embedded-firmware norm.

Either is good. Minisign is the smaller commitment; cosign carries the
sigstore-ecosystem trust-root benefits if we ever want to rotate keys
without re-flashing every device.

Tracked here so the OTA design (`docs/specs/2026-06-01-reforge-ota-design.md`)
gets revisited when this is scheduled. Not blocking; current OTA works.
