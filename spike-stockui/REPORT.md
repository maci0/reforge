# ReForge P3 Task 8: Stock-UI Feasibility Spike Report

**Date:** 2026-06-01  
**Spike question:** Can the stock FlashForge `firmwareExe` (Qt4/QWS touchscreen UI) run as a
ReForge screen mode against ReForge's upstream Klipper?  
**Status:** DONE — static analysis complete, live test partially successful; render confirmed,
klippy-connect deferred to on-device test.

---

## 1. Static Analysis Findings

### 1.1 ELF Metadata

| Field | Value |
|-------|-------|
| Format | ELF 32-bit LSB, ARM EABI5 |
| ABI | soft-float (stock rootfs is soft-float; ReForge hard-float rootfs is incompatible) |
| Interpreter | `/lib/ld-linux.so.3` |
| Debug info | Yes — unstripped with debug_info (rich symbol table) |
| BuildID | `f24ce8943f96971f9eb291730f296989d7c96932` |

### 1.2 Klippy API Socket and Protocol

| Item | Value |
|------|-------|
| Socket probe | `/bin/ls /tmp/printer` (existence check before connect) |
| **Klippy socket path** | **`/tmp/uds`** |
| Socket type | UNIX domain stream socket, JSON-RPC (no HTTP/moonraker layer) |
| Klippy startup | firmwareExe shells: `/opt/klipper/start.sh &` |
| Stock start.sh | `python3.7 klippy.py printer.cfg -l /data/logFiles/printer.log -a /tmp/uds` |

**`/tmp/uds` is the standard `-a` argument accepted by upstream Klipper. No protocol gap.**

### 1.3 JSON-RPC Methods Used (all 5 are standard upstream Klipper)

| Method | Purpose |
|--------|---------|
| `objects/query` | Poll printer state (temps, axes, fans, filament, print status) |
| `gcode/script` | Send raw G-code commands |
| `gcode/subscribe_output` | Subscribe to gcode output log stream |
| `gcode/restart` | Soft restart klippy |
| `gcode/firmware_restart` | Firmware restart klippy |

### 1.4 Klippy Objects Required (full `objects/query` payload)

```
virtual_sdcard        pause_resume          fan_generic fanM106
fan_generic chamber_fan   print_stats       toolhead
gcode_move            webhooks              filament_switch_sensor e0_sensor
extruder              heater_bed            temperature_sensor weightValue
temperature_sensor tvocValue               gcode_button btn_power
```

### 1.5 FlashForge Custom Objects — The Gap (smaller than expected)

**`temperature_sensor weightValue`** — declared as `[temperature_sensor]` with
`sensor_type: MAX31856, sensor_pin: PD5`. MAX31856 EXISTS in upstream Klipper
(`spi_temperature.py`). Not a custom module — standard upstream sensor type.
firmwareExe reads this as a proxy load cell weight (temperature register = grams).

**`temperature_sensor tvocValue`** — declared as `[temperature_sensor]` with
`sensor_type: MAX31865, sensor_pin: PD4`. MAX31865 EXISTS in upstream Klipper.
TVOC display only; non-critical for print control.

**`gcode_button btn_power`** — standard upstream `buttons.py` module.

**`gcode_button check_level_pin`** — standard upstream `buttons.py` module.

**Conclusion: There are NO FlashForge-proprietary klippy Python modules.**
All objects are implementable with standard upstream Klipper + correct printer.cfg.

Custom klippy modules found in stock rootfs zmod (NOT required by firmwareExe directly):

| Module | Source | ReForge status |
|--------|--------|---------------|
| `load_cell_tare.py` | zmod plugin | Already present in ReForge upstream extras |
| `mod_params.py` | zmod-specific | Not needed |
| `feather_screen.py` | zmod alternative UI | Not needed |

### 1.6 Qt Embedded Display Requirements

| Setting | Value |
|---------|-------|
| Qt version | Qt 4.8.6 QWS mode (`-qws` arg) |
| Display backend | `QWS_DISPLAY=transformed:rot0:LinuxFB:mmWidth115:mmHeight170:0` |
| Framebuffer | `/dev/fb0` at size `480x800` (portrait — physical device is portrait) |
| Touchscreen | tslib at `/dev/input/event0` |
| Serial MCU | `/dev/ttyS1` (eboard), `/dev/ttyS5` |

FB mismatch in qemu: virtio-gpu is 800x480 landscape; firmwareExe expects 480x800 portrait.
Result: UI renders portrait into landscape fb (right half clipped). Non-fatal for testing.
On real hardware the fb is 480x800 portrait and the UI fills correctly.

**Soft-float ABI constraint:** firmwareExe is soft-float. It CANNOT run in ReForge's
hard-float rootfs (`output-guppy`). It must run in the stock soft-float environment.

---

## 2. Live Test Results

### 2.1 Test Environment
- Kernel: `build/zImage` (vendor 5.4.61, `-M virt`, `-cpu cortex-a7`)  
- Root: `stock-rootfs.ext4` copy (e2fsck journal recovery applied)  
- FB: `virtio-gpu-pci,xres=800,yres=480`  
- Timeout: 120 seconds, VNC + monitor socket for screendump  

### 2.2 Boot Sequence (key events from console log)

```
[t=4s]   zmod detected STOCK display mode: "Display: STOCK"
[t=8s]   "Booting stock firmware..."
[t=9s]   ffstartup-arm launched, environment set up from env.cfg
[t=10s]  firmwareExe started (PID 259), args: [-1 -D -qws]
[t=10s]  Qt4/QWS init OK: "YaHei - Kelvin" font loaded
[t=10s]  Tslib calibration warning (non-fatal): /etc/pointercal not found
[t=10s]  Serial init attempted: fd 14 opened, tcgetattr error (no /dev/ttyS1 in qemu)
[t=10s]  firmwareExe continues running (NOT crashed)
[t=120s] qemu SIGTERM (timeout), test ended
```

firmwareExe ran for the full 110 seconds remaining after startup. It did not crash.

**klippy was NOT started** in this test (zmod detected mmcblk0p7 absent, took a different
boot path that skipped auto_run.sh). The klippy-connect test is deferred to on-device.

### 2.3 Framebuffer Render Test

| Metric | Value |
|--------|-------|
| Screenshot | `build/stockui-screenshot.ppm` (800×480, gitignored) |
| Unique pixel values (1/16 sample) | **97** — definitively non-blank |
| Dominant color | `#19893e` (dark green, ~60%) |
| Secondary | `#ffffff` (white, ~39%), black text in center |
| Content | FlashForge boot splash / connecting screen |

**RENDER: PASS.** firmwareExe rendered the stock FF green/white UI to `/dev/fb0`
via Qt4 LinuxFB backend. The portrait UI is visible but clipped in landscape qemu fb.

### 2.4 Works/Breaks Matrix

| Feature | Status | Notes |
|---------|--------|-------|
| firmwareExe process start | **PASS** | PID 259, watchdog confirmed |
| Qt4/QWS init | **PASS** | No crash, fonts loaded |
| Framebuffer render | **PASS** | 97 unique pixels in screendump |
| Klippy socket connect | **NOT TESTED** | klippy not started in qemu test |
| Temperature display | **NOT TESTED** | requires klippy |
| Jog / Home / Print | **NOT TESTED** | requires klippy + MCU |
| FF calibration (load cell) | **NOT TESTED** | requires MCU + eboard |
| MCU serial (eboard) | **FAIL** (expected) | not emulated in qemu-virt |
| Camera streaming | **FAIL** (expected) | no device, cloud disabled |
| Cloud/NIM connectivity | **FAIL** (expected) | no cloud routes in qemu |

### 2.5 Why Klippy-Connect Was Not Tested in qemu

The stock rootfs zmod boot path in qemu diverges from on-device because `/dev/mmcblk0p7`
is absent. The fallback path skips `auto_run.sh` (which calls `/opt/klipper/start.sh`).
A crafted test would need to pre-start upstream Klipper in the qemu environment and
inject `/tmp/uds` before firmwareExe attempts to connect.

**Recommended on-device test:** Replace stock klippy with ReForge's upstream klippy
at `-a /tmp/uds`, then observe firmwareExe behavior — expected: connects, shows temps,
allows basic control. Missing objects (`weightValue`, `tvocValue`) should cause graceful
degradation (fields absent from query result, not a crash).

---

## 3. Gap Analysis Summary

| Gap | Type | Severity | Resolution |
|-----|------|---------|-----------|
| `temperature_sensor weightValue` | printer.cfg entry | Medium | Add `[temperature_sensor weightValue]` with MAX31856 + SPI pins to ReForge printer.cfg |
| `temperature_sensor tvocValue` | printer.cfg entry | Low | Add `[temperature_sensor tvocValue]` with MAX31865 + SPI pin to ReForge printer.cfg |
| `gcode_button btn_power` | printer.cfg entry | Low | Add `[gcode_button btn_power]` section |
| `load_cell_tare.py` | klippy extra | None | Already in ReForge upstream extras |
| Soft-float ABI | Environment | High (constraint) | firmwareExe must run in stock soft-float env, not ReForge hard-float rootfs |
| MCU eboard serial | Hardware | N/A | Not a software gap; on real hardware klippy handles MCU connection |
| OpenSSL 1.0.x | Library | Low | Present in stock rootfs `/opt/openssl-1.0.2d/`; not needed for local control |

**Total software gaps requiring new code: ZERO.**
The only work is `printer.cfg` additions (standard Klipper config, no custom code).

---

## 4. Go/No-Go Recommendation

### Recommendation: **GO — Option A: Implement STOCK screen mode**

**Rationale:**
1. firmwareExe **renders** to `/dev/fb0` (confirmed by qemu test)
2. firmwareExe uses **standard Klipper JSON-RPC** at `/tmp/uds` (no protocol gap)
3. All required klippy objects are **standard upstream Klipper** (no custom modules needed)
4. `load_cell_tare.py` already in ReForge extras
5. No FlashForge-proprietary klippy modules exist — only hardware-specific printer.cfg entries

### Implementation Path (~2 sprints)

**Sprint 1 — printer.cfg + boot hook:**
- Add to ReForge AD5M Pro printer.cfg:
  ```
  [temperature_sensor weightValue]
  sensor_type: MAX31856
  sensor_pin: PD5
  spi_software_miso_pin: eboard:PA6
  spi_software_mosi_pin: eboard:PA7
  spi_software_sclk_pin: eboard:PA5
  
  [temperature_sensor tvocValue]
  sensor_type: MAX31865
  sensor_pin: PD4
  
  [gcode_button btn_power]
  pin: !PC15
  press_gcode:
  ```
- In `reforge-boot`, `SCREEN_MODE=STOCK` path:
  1. Start upstream Klipper: `python3 /opt/klipper/klippy/klippy.py printer.cfg -a /tmp/uds &`
  2. Source `env.cfg` environment
  3. Launch `ffstartup-arm -f /opt/PROGRAM/ffstartup.cfg`

**Sprint 2 — on-device integration test:**
- Verify firmwareExe connects to upstream Klipper at `/tmp/uds`
- Check temp display, jog, print start/cancel
- Verify load cell tare works
- Screenshot regression

### Option B (port custom modules) — NOT NEEDED
No FF-specific klippy modules exist. There is nothing to port.

### Option C (drop stock UI) — VALID as default, not recommended for STOCK mode users
GuppyScreen (Task 7: PASS) is the preferred ReForge UI. STOCK mode is additive for users
who prefer the FF stock UX (familiar workflow, language strings, calibration flows).

---

## 5. Blob Guard Verification

```
spike-stockui/extracted/  is gitignored: YES (.gitignore line: spike-stockui/extracted/)
```

No proprietary blobs tracked. The `extracted/` directory contains firmwareExe + Qt/tslib
libs but is excluded from git by `.gitignore`.

---

*Evidence sources: static analysis of `fw-analysis/software-5.1.4/firmwareExe`
(SHA1: f24ce8943f96971f9eb291730f296989d7c96932), stock rootfs at
`validation/qemu-harness/build/stock-rootfs.ext4`, qemu live test log
`build/stockui-live-test2.log`, screendump `build/stockui-screenshot.ppm`.*
