# gdb on the AD5M — live symbol-injection into `firmwareExe`

How gdb is used on this printer (researched on the live unit, `root@192.168.0.158`).

## The binary
- **GNU gdb 7.10.1**, `/usr/bin/gdb` (present on host and inside the forge-x chroot).

## Why it's used — the core trick
The stock QT UI app `/opt/PROGRAM/software/5.1.4/firmwareExe` is **NOT stripped** — it exports
mangled C++ method symbols **and static instance pointers** (`instMainWindow`, `instSettings`,
…). forge-x exploits this: attach gdb to the **running** `firmwareExe` and **call its C++ methods
directly**, driving the touchscreen UI from a shell script with no screen interaction. This is
how the mod restarts Klipper, dismisses dialogs, etc., "like the original QT factory app does it."

## The pattern
```sh
pid=$(ps | grep "[f]irmwareExe -1" | awk '{print $1}')   # -1: avoid matching helpers
gdb -q -batch \
  -ex "set auto-solib-add off" \      # fast attach: don't pull in all .so symbols
  -ex "attach $pid" \
  -ex "call (RET) MANGLED(INSTANCE_PTR, args...)" \
  -ex "detach" -ex "quit"
```
- **Instance pointers** are static globals you pass as the C++ `this`:
  - `_ZN10MainWindow14instMainWindowE`  → `MainWindow::instMainWindow` (MainWindow*)
  - `_ZN8Settings12instSettingsE`       → `Settings::instSettings`
  - `_ZN12CancelDialog16instCancelDialogE`, `_ZN19CompletePrintDialog23instCompletePrintDialogE`
  - `Config` is a singleton: `_ZN6Config11getInstanceEv()` (or `_ZN6Config17m_singletonConfigE`)
- **Methods** are itanium-mangled: `_ZN10MainWindow11closeCameraEv` = `MainWindow::closeCamera()`.

## forge-x scripts that use it
| Script | What it does |
|---|---|
| `.shell/restart_klipper.sh` | `MainWindow::on_settings_clicked()` → `Settings::saveCfg()` (saves config **and** restarts Klipper, the factory way) → `MainWindow::on_home_clicked()`. The forge-x Klipper-restart mechanism. Falls back to Moonraker API (`zmoon.sh restart_klipper`) if `firmwareExe` isn't found. `--hard` mode instead kills `klippy.py` + runs `/opt/klipper/start.sh`. |
| `.shell/close_dialogs.sh` | Dismisses stuck on-screen dialogs: `CancelDialog::setStateClear()`, `CompletePrintDialog::…`, etc. |

## Camera on/off (control-panel camera) — found this session
The control-panel camera is `firmwareExe` itself (`MainWindow`/`CameraControl`/`InputCamera`),
which holds `/dev/video0`. The forge-x `camera` var + `S98camera` (mjpg_streamer on :8080) is a
**separate** path for web UIs and is independent of the touchscreen camera.

Turn the control-panel camera **OFF** (releases `/dev/video0`):
```sh
pid=$(ps | grep "[f]irmwareExe -1" | awk '{print $1}')
gdb -q -batch -ex "set auto-solib-add off" -ex "attach $pid" \
  -ex "call (void) _ZN10MainWindow11closeCameraEv(_ZN10MainWindow14instMainWindowE)" \
  -ex "detach" -ex "quit"
```
Turn it **ON**: `MainWindow::openCamera()` → `_ZN10MainWindow10openCameraEv`.

**Gotcha:** `MainWindow::doSetCameraStatus(bool)` (`_ZN10MainWindow17doSetCameraStatusEb`) gates on
the persistent `Config` flag (`Config::getCameraStatus`/`setCameraStatus`) and **no-ops if the flag
is already at the target value**. A live preview started from the panel does not set that flag, so
`doSetCameraStatus(0)` does nothing — call `closeCamera()`/`openCamera()` directly instead.
(Verified: `Config::getCameraStatus()` read `0` while `video0` was held; `closeCamera()` released it.)

## Other gdb use in this repo (VE encoder bring-up)
`lab/venc/` and `lab/venc-scratch/` use a gdb breakpoint on the closed encoder lib's
`rc_init_frame` to poke float fields (`set *(float*)($r0+4)=15.0` …) and bypass a divide-by-zero,
so the encode reaches the HW submit. See `lab/venc/README.md`.

## Safety notes
- Attaching **pauses `firmwareExe` (the whole UI)** for gdb's duration — keep scripts `-batch`,
  `auto-solib-add off`, and `detach` promptly.
- Calls run in whatever thread gdb attached to; prefer simple, self-contained methods (the forge-x
  scripts and the camera calls above are safe in practice — `firmwareExe` stays alive).
- `ps | grep "[f]irmwareExe -1"` (the `-1` and the `[f]` bracket) avoids matching gdb itself or
  other helpers.
