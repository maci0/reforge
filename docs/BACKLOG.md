# Backlog

Open issues and unscheduled ideas. Closed entries keep a status line and links to the
canonical record.

## microgit — a tiny git client (Zig) for Moonraker's update_manager

**Status: deferred.** Moonraker's `git_repo` updater shells out to the full `git` CLI
(about 5–10 MB of rootfs with `git-remote-https` and libcurl). A purpose-built client
would have to reproduce git's output byte for byte for the ~18 subcommands
`moonraker/components/update_manager/git_deploy.py` parses (checked 2026-06-01),
including smart-HTTP over TLS, `--filter=blob:none` partial clone and packfile deltas.
ReForge OTA ships through `zip`/`web` updaters instead ([ota.md](ota.md)), so this only
matters for upstream `git_repo` OTA, which would still lack `pip` and `gcc` on the device.

## reforge OTA design: DONE (option 2)

**Closed.** Shipped as `zip` updaters against ReForge's own prebuilt releases plus a `web`
updater for Mainsail; see [ota.md](ota.md) and the
[OTA design spec](specs/2026-06-01-reforge-ota-design.md).

## live USB: vfat + f2fs partitions (drop loopback) — DONE 2026-06-04

**Closed.** `make live-usb` writes a partitioned image (FAT p1 + F2FS p2) and the launcher
mounts p2 directly, so `loop.ko` is no longer built. Layout, flashing and the `kunos`
hardware check: [live-mode.md](live-mode.md#the-two-modules).

## immutable / atomic ReForge — OverlayFS2 (or similar) for transactional updates and true Mode 1 live

**Superseded (2026-06-05)** by the plan
[`plans/2026-06-05-immutable-reforge.md`](plans/2026-06-05-immutable-reforge.md) (phase 1
not implemented). Module build and per-mount cost:
[OverlayFS spike](research/kernel/2026-06-05-overlayfs-on-bsp-spike.md). The `/reforge`
mountpoint the merged view would attach to already exists in `reforge-boot`.

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

Historical bring-up issue, superseded by the [2026-06-04 protocol
correction](reverse-engineering/ad5m-mcu-firmware-and-config.md): the observed
`query_adxl345` mismatch was initially attributed to v0.11 versus v0.13 and
accelerometer sections were disabled during that trial. Source review places
the command change at v0.10 → v0.11; v0.11 and v0.13 use the same format.
The current package pins a v0.11 host and `printer.base.cfg` enables
`[adxl345]` and `[resonance_tester]`. That historical mismatch does not justify
reflashing a stock MCU. A coordinated firmware upgrade remains separate work.

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

NOT `switch_root` **for live / Mode 2**: we are not PID1 (stock init launches us late via
`auto_run`, with the panel UI + many stock procs already running), `switch_root` is an
initramfs-era tool that would tear down the running stock system, and it wouldn't change the
(stock) kernel or the vermagic-locked driver anyway. Brick-safety comes precisely from being a
non-invasive guest under stock init (pull USB → stock boot without install state; `/reforge` on p6 may remain). Raised 2026-06-02.

> **Update 2026-06-08:** `switch_root` *is* on the table for the **Mode 3** (own-kernel/PID1)
> path — distinct from the non-invasive live/Mode-2 guest above. Groundwork has started: the
> `/reforge` bind-mount seam in `reforge-boot` (the future pivot target) and the staged `dinit`
> package + `etc/dinit.d/` services (the future PID-1 init). See the dedicated entry below.

## forge-x: one shared python for klippy + moonraker — CLOSED (negative)

Closed 2026-06-03 after live testing on a 5M Pro: running klippy under moonraker's
Python 3.11 regressed RAM by ~16 MB (Pss 23.2 MB versus 7.3 MB for stock Python 3.7).
Sharing libpython3.11 with moonraker saved only ~1 MB. The Forge-X contribution and
its dedicated build helper have been removed from this repository. See the
[memory review](research/memory/2026-06-03-forge-x-memory-review.md) for the findings.

## Mode 2 install: stock UI still starts, cloud block misses it

Found by source review (2026-11-13), not yet observed on hardware: `reforge-boot`
`exec`s `/mod/start.sh`, which backgrounds every service and exits, so the stock `rcS`
continues and `/opt/auto_run.sh` launches `ffstartup-arm`/`firmwareExe` beside the
chroot. `S00cloudblock` runs inside the chroot and edits only the chroot's `/etc/hosts`.
Effects: the stock LAN and cloud surfaces stay up in Mode 2a, and the stock UI may
compete with ReForge for the MCU serial ports and framebuffer. Closure is Mode 2b
(PID-1 swap) or another way to stop `auto_run.sh` before its UI launch. See
[security-findings.md](security-findings.md).

## Cloud-block hardening: iptables for IP-literal stock endpoints

The current cloud-block edits the chroot's `/etc/hosts`, so it does not cover the
stock UI. Even a stock-side hosts block would miss these hard-coded IP literals:

- `http://10.33.11.172:32112/api/updates/check` (private dev update server)
- `http://10.33.23.222` (private legacy update host)
- `rtmp://115.231.29.49:2045/...` (public test-video endpoint)

**Blocked on kernel support:** the captured stock kernel and current device config
have `# CONFIG_NETFILTER is not set`. Netfilter's core is a boolean Kconfig option;
an iptables package or add-on module alone cannot enable it. An on-device firewall
needs a replacement kernel built with Netfilter, the required iptables matches and
REJECT target, plus the iptables userspace package. This is not a quick stock-kernel
script change and is not implemented. Such a kernel would be a separate, unplanned
variant: Mode 2a retains stock, while planned Modes 2b and 3 remove the stock UI and
close this particular surface. Mode 3's current board fragment also omits Netfilter.

Illustrative rules for such a kernel, not commands supported by current stock:

```sh
iptables -A OUTPUT -d 10.33.11.0/24 -j REJECT
iptables -A OUTPUT -d 10.33.23.0/24 -j REJECT
iptables -A OUTPUT -d 115.231.29.49 -j REJECT
```

With kernel support, these rules would cover the shared network namespace, including
stock `firmwareExe` outside the chroot. On an unchanged stock kernel, use external
network filtering on a router/firewall that actually carries the printer's traffic;
it cannot filter a direct LAN path that bypasses it. The planned on-device alternative
is Mode 2b, which stops the stock UI rather than filtering its connections.

Evidence: [stock kernel config](board-notes/stock-kernel-config-5.4.61.txt.gz),
`br-external/board/reforge/linux.config`, BSP `net/Kconfig`, and
[security finding #6](security-findings.md).

## Sigstore / cosign signatures on ReForge OTA artifacts

Today's ReForge OTA fetches per-component zips from a GitHub Release. The
integrity story is "you trust this GitHub repository" — there's no signature
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

## wire dinit as the Mode 3 switch_root PID 1

**Status (2026-06-08): groundwork landed, wiring pending.** Building toward
replacing the busybox-init + sequential `/mod/start.sh` S-loop with a real
supervised init for the own-kernel (Mode 3) path. Already in-tree:

- `dinit` 0.22.1 package (`br-external/package/dinit/`, `BR2_PACKAGE_DINIT=y`) —
  binaries shipped; the service definitions below are staged, not wired.
- Staged service descriptions (`…/rootfs-overlay/etc/dinit.d/{boot,prepare,
  cloudblock,zram,eboard,klipper,moonraker,httpd,camera,guppyscreen,helixscreen,ok}`) +
  `tests/release/dinit-services-test.sh` (in `make unit`). Inert today.
- The `/reforge` bind-mount seam in `reforge-boot` (the future pivot target).

Remaining for Mode 3: a PID-1 entry that `switch_root`s into `/reforge` and
`exec`s `dinit`, plus a selector for the conditional camera, GuppyScreen and
HelixScreen services. The staged Mode 2b `sbin/reforge-init` is separate: it
uses `pivot_root` into `/data/.mod/.reforge` and executes BusyBox init, not dinit. The Mode 3 work is gated on Plan 5;
until ReForge
ships its own kernel, the non-invasive chroot guest stays the shipping model.
Refs: [`docs/research/kernel/2026-06-05-replacing-pid1.md`](research/kernel/2026-06-05-replacing-pid1.md),
`…/etc/dinit.d/README.md`.
