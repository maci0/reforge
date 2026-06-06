# Rendering the printer UIs in qemu — findings

How ReForge renders the **stock FlashForge UI** and **GuppyScreen** under
`qemu-system-arm` (the virt test kernel + an 800×480 framebuffer), what it takes
to make each reach a real screen with no MCU, and where each currently stands.

All harnesses here are **fully rootless** (no sudo): ext4 images are baked from a
staging dir with `mke2fs -d` or patched in place with `debugfs` (size-verified —
`debugfs write` silently truncates a file's tail, so every inject verifies the
written size and retries); the stock rootfs is sliced from the golden image by
**GPT byte-offset + `dd`** (no losetup); qemu runs unprivileged (cortex-a7 TCG
needs no kvm), so its `-monitor unix:` socket is user-owned and `socat`
screendump needs no sudo.

---

## Stock UI (`firmwareExe`) — SOLVED: clean home screen

`tests/qemu-harness/stockui-render.sh` → `make qemu-stockui`. Output:
`build/stockui-home.ppm`. Committed shot: `docs/screenshots/stockui-home-qemu-800x480.png`.

### The two independent startup gates

`firmwareExe` (the stock Qt4/QWS app) checks **two** things at boot; both must
pass before it leaves its modals for the home screen. The earlier
`stock-ui-spike.md` was wrong that a ready klippy alone unblocks the UI.

1. **eboard MCU serial handshake.** firmwareExe (`MainWindow::detectMcu()` →
   `openSerial` → `Serial::recvWaitOk`) opens `/dev/ttyS1` (eboard) and
   `/dev/ttyS5` (main) @230400. qemu virt has **no 8250 UART** (only PL011
   `ttyAMA*`), so those nodes never exist → the *"No detected eboard mcu."* modal.
   The protocol is **not** gcode: the MCU emits `start` on reset, then firmwareExe
   streams `A` **ACK bytes** and expects the MCU to **echo each `A`** back.
   `tests/qemu-harness/stockui/mcu-sim.py` emulates this on a raw pty (no echo),
   emits `start` **once** (re-emitting it on every symlink self-heal spammed the
   handshake → restart), echoes the `A` ACKs, and self-heals its `/dev/ttyS1`
   symlink against udev churn. It is launched **late** (right before `ffstartup`)
   so udev coldplug can't remove the node first; auto_run waits for `/dev/ttyS1`.
2. **klippy "ready".** firmwareExe connects to klippy's API socket `/tmp/uds`
   (0x03-framed JSON-RPC). `tests/qemu-harness/stockui/fake-klippy.py` answers the
   small subset it polls (`objects/query` + a few gcode methods) as a ready
   printer.

### Scrubs + dialog clearing (for a clean, privacy-safe shot)

The golden dump carries the **source device's live state**, so the render edits
the rootfs copy in place:

- `/opt/config/PowerOff` (a power-loss-recovery flag, `PowerFlag:ON`) → **removed**,
  else firmwareExe prompts *"recovery print?"* to resume the dumped device's
  interrupted print.
- `/opt/config/Adventurer5M.json` `printerName`/`printerSerialNumber` → `REFORGE-DEMO`
  (never ship the real serial).
- `general.CheckAppFrist` → `false` in the same JSON. This single flag gates
  firmwareExe's `checkAppTip()` → the *"Please upgrade the slicer software to
  V1.7.3 or later"* nag (root-caused by disassembly: `Config::getCheckAppFrist()`
  reads `general.CheckAppFrist`; if non-zero, the modal is built). The same
  one-line config fix is proposed to forge-x (PR DrA1ex/ff5m#68) and was applied
  to the live printer on request.
- **E0120 restart modal.** firmwareExe does **one** self-restart in qemu (a
  watchdog/recovery artifact), surfacing a *"E0120: Restarted. Please copy the
  logs!"* dialog — previously hidden behind the slicer nag. The harness adds a
  `virtio-keyboard-pci` and synthesises **Enter** (`sendkey ret`) after settle;
  the Ok button is focused, so this dismisses it → the clean home screen.

Result: nav rail, Adventurer 5M Pro art, live temp panels, light/network/camera
tiles, no overlay (1475 distinct colours).

---

## GuppyScreen — PARKED: stack reaches "ready" but LVGL won't paint

`tests/qemu-harness/guppy-render.sh` → `make qemu-guppy`. Output:
`build/guppy-home.ppm` (currently **blank**).

GuppyScreen talks **Moonraker** (websocket), which talks **klippy** (`/tmp/klippy_uds`).
With no MCU, real klippy never reaches "ready". `tests/qemu-harness/guppy/fake-klippy.py`
is a **Moonraker-grade** Klipper API stand-in: it completes Moonraker's full
handshake — `info` (state ready) → `list_endpoints` → `objects/list` (advertising
`virtual_sdcard`/`display_status`/`pause_resume` + a rich object set) →
`objects/subscribe`/`objects/query` → `register_remote_method` — and pushes
unsolicited `process_status_update` events.

**Verified working at the protocol level:** Moonraker reports
`klippy_connected:true, klippy_state:"ready", missing_klippy_requirements:[]`, and
GuppyScreen connects, subscribes to every object, and logs `done init`.

**But GuppyScreen never paints `/dev/fb0`.** Confirmed by dumping the framebuffer
**in-guest** to a second virtio-blk disk and converting host-side — genuinely
black, so this is **not** a virtio-gpu scanout-flush issue (the fb is a correct
800×480×32; firmwareExe paints the same fb fine). Adding the status pushes did not
change it. This is a GuppyScreen **LVGL display-backend** issue under qemu —
likely needs real panel hardware or a guppy/LVGL-driver rebuild. **Parked.**
`make qemu-guppy` remains useful as a full-stack "ready" rig for Moonraker/OTA/API
testing.

---

## Related

- Stock recovery / golden image provenance + 1:1 rebuild via Tina SDK:
  `lab/stock-image-repro/findings.md`.
- AD5M vs AD5M Pro firmware delta (same board/firmware; model-skin + JSON flags):
  `lab/ad5m-vs-pro/findings.md`.
- Original (now partly superseded) spike: `docs/research/ui-camera/stock-ui-spike.md`.
- Screenshot gallery + captions: `docs/screenshots/README.md`.
