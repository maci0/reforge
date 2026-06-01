# Screenshots

GUI renders are captured from `qemu-system-arm` with `/dev/fb0` pinned to the printer's exact
panel (**800×480, 32 bpp**), via the QEMU monitor `screendump` (see
`tests/qemu-harness/README.md`) — **pixel-identical to the real 4.3" screen**. The boot
images are rendered from the actual qemu serial capture / the in-repo banner script.

## Bootsplash (fire/ember "ReForge")

![ReForge bootsplash](reforge-bootsplash.png)

The fire-gradient banner from `board/reforge/rootfs-overlay/usr/bin/reforge-banner` — shown on
the boot console (via `reforge-boot`) and on interactive login (`/etc/profile.d`). Steel anvil,
ember-hot base, tagline *"ReForge — Klipper, reforged"*. 256-color ANSI; degrades to plain text
on dumb terminals.

## Boot process

![ReForge boot console](reforge-boot-console.png)

The real ReForge userspace boot sequence captured from the qemu serial: cloud-block → sysctl →
zram swap → klipper → moonraker → busybox httpd (Mainsail) → guppyscreen → `Welcome to ReForge`.

> The zram line shows skipped here because the qemu **virt** test kernel is built without
> `PREEMPT`, so the stock-built `zram.ko` vermagic mismatches. On the **real stock 5.4.61
> kernel** the module matches and zram swap activates (see `modules/zram-bsp/`).

## GuppyScreen (ReForge's on-screen UI) — PARKED (renders blank in qemu)

![GuppyScreen in qemu, 800×480](guppyscreen-qemu-800x480.png)

**Status: not captured — known limitation, parked.** The committed shot is blank (2 colours).

The full stack *does* come up: `tests/qemu-harness/guppy/fake-klippy.py` is a Moonraker-grade
Klipper API stand-in that completes Moonraker's handshake as **ready** with no MCU. Verified —
Moonraker reports `klippy_connected:true, klippy_state:"ready", missing_klippy_requirements:[]`
and GuppyScreen connects, subscribes to the full object set, and logs `done init`. Yet
GuppyScreen never paints `/dev/fb0` — confirmed by dumping the framebuffer **in-guest** to a
second disk (genuinely black, so it is *not* a scanout-flush issue; the fb geometry is a correct
800×480×32). Pushing `process_status_update` events (so Moonraker emits `notify_status_update`)
did not change it either.

So this is a GuppyScreen **LVGL display-backend** issue under qemu's virtio-gpu, independent of
the printer-ready simulation. It likely needs real panel hardware or a guppy/LVGL-driver rebuild.
`make qemu-guppy` is still useful as a **full-stack "ready" rig** for Moonraker/OTA/API testing
even though the on-screen capture is blank. The reforge-render path (`make qemu-render`) is the
older non-blank attempt (also blank without a ready klippy).

## Stock UI boot phases (`firmwareExe`) under simulated hardware

The stock UI boot is ~90 s in qemu. Sampling the framebuffer across that window
(`tests/qemu-harness/shots-capture.sh`, screendumps at t = 4/8/12/18/25/40/60/90 s plus a
finer 18–30 s pass) yields a handful of visually distinct phases. Each frame is the pinned
**800×480** panel, captured exactly like the home shot below (rootless slice + sim + screendump).

### Phase 1 — loading / connecting ("Initialization…")

![Stock FlashForge UI initialising in qemu, 800×480](stockui-boot-loading-800x480.png)

The first thing `firmwareExe` paints: a dark canvas with the centred **"Initialization…"** card and
spinner, shown while it brings up Qt/QWS on `/dev/fb0` and waits on the eboard serial handshake +
klippy. (There is no separate green FlashForge bootlogo in this path — the Qt app owns the
framebuffer from a dark background straight through to the home screen.)

### Phase 2 — transient restart notice ("E0120: Restarted")

![Stock FlashForge E0120 restart notice in qemu, 800×480](stockui-boot-restart-800x480.png)

Mid-boot under qemu, `firmwareExe` self-restarts once and surfaces an **"E0120: Restarted. Please
copy the logs!"** dialog before recovering. Captured honestly as a real boot-time state — it clears
on its own and the UI proceeds to the home screen below. (On real hardware this is the watchdog/
recovery notice; here it's the in-qemu restart on the way up.)

## Stock UI (`firmwareExe`) — full home screen under simulated hardware

![Stock FlashForge home screen in qemu, 800×480](stockui-home-qemu-800x480.png)

The stock FlashForge UI booted all the way to its **clean home screen** in qemu: nav rail
(home / print / settings / info), the Adventurer 5M Pro printer art, live nozzle + bed
temperature panels, light/network/camera tiles — fully interactive, no overlay dialogs. ReForge
overlays the stock base, so the stock UI binary (`/opt/PROGRAM/.../firmwareExe`, soft-float
Qt4/QWS) and its Qt + tslib libs run straight from that base — no extraction, no recompile.

The render scrubs captured device state from the dump and clears the boot dialogs:
- `/opt/config/PowerOff` (a power-loss-recovery flag) is removed — else a *"recovery print?"* modal;
- the real serial in `/opt/config/Adventurer5M.json` → `REFORGE-DEMO` (top-left);
- `general.CheckAppFrist` → `false` in the same JSON — clears the *"upgrade the slicer to V1.7.3"*
  nag (root-caused to firmwareExe's `checkAppTip()`; the same one-line fix ships to forge-x);
- firmwareExe still does **one** self-restart in qemu (a watchdog artifact → the *E0120: Restarted*
  modal); the harness synthesises an **Enter** keypress via a virtio keyboard to dismiss it,
  leaving the clean home screen above.

Getting past startup needs **two gates satisfied** (firmwareExe checks them independently):
1. an **eboard MCU serial handshake** on `/dev/ttyS1` (+`/dev/ttyS5`) @230400 — qemu virt has no
   8250 UART, so `tests/qemu-harness/stockui/mcu-sim.py` emulates a gcode MCU on a pty;
2. a **klippy "ready"** reply on `/tmp/uds` — `tests/qemu-harness/stockui/fake-klippy.py` serves
   the JSON-RPC subset firmwareExe polls.

Reproduce with **`make qemu-stockui`** (fully rootless — debugfs inject + GPT-offset rootfs slice
+ unprivileged qemu). Capture lands at `tests/qemu-harness/build/stockui-home.ppm`.

### Without the MCU sim — the "No detected eboard mcu." modal

![Stock FlashForge MCU-absent modal](stockui-qemu-800x480.png)

Booting the same stock base with **no** MCU sim stops at firmwareExe's
**"No detected eboard mcu."** modal (gate 1 unmet) — the green/white dialog that motivated the
simulation above. Full works/breaks analysis: `docs/research/stock-ui-spike.md`.
