# Cedar VE H.264 encode (re-attempt) + camera identity/firmware

Date: 2026-06-04. Live unit `root@192.168.0.158` (`kunos`). Two questions: (1) does the
T113 Cedar VE do **hardware** H.264 encode — re-attempted after the earlier wall; (2) what
does the webcam output **natively**, and is its firmware updatable. Short answers: **the
vendor HW-encode pipeline runs** (VeInitialize + VideoEncInit succeed and execution reaches
the codec `H264EncEncode` — revising the earlier "dead silicon" view; it now crashes on a
software NULL bitstream buffer, not the VE stall), and the camera is **MJPEG-only** with a
**fixed, non-updatable** firmware.

## Camera — native format + firmware

Probed `/dev/video0` (`v4l2-ctl --list-formats-ext`) and the USB descriptor:

| | |
|---|---|
| Pixel format | **`MJPG` (Motion-JPEG) — the only format** |
| Resolutions | up to 1920×1080@30 (also 1440×1080, 1280×960, 1280×720, …) |
| No | YUYV / raw / native H.264 — none enumerated |
| USB | VID:PID **`ab20:1276`**, module **`U0AS01A-0`** |
| **Firmware** | bcdDevice **`0x2011`**, rev string (serial) **`01.00.00`** |

**No camera FW update exists.** It is a fixed-function UVC module — firmware lives in the
module's own ROM, flashed by the module vendor, not user-updatable. FlashForge ships no
camera firmware: the AD5M OTA only carries `firmware/control/library/software` components
(`app_id` 35/36/37/38 — none is a camera package; see
[`../reverse-engineering/firmwareexe-ota-update.md`](../reverse-engineering/firmwareexe-ota-update.md)),
and no vendor flash tool is published for `ab20:1276`. The camera stays at `0x2011`/`01.00.00`.

Consequence: any H.264 stream needs an **MJPEG-decode → H.264-encode** round trip — the
sensor never emits raw or H.264 to encode from directly.

## Cedar VE H.264 encode — two paths, and a breakthrough

Two independent approaches, with an important revision of the earlier "dead silicon" view.

### (a) Open from-scratch reimpl — clock lever ruled out, still stalls

Re-ran [`../../lab/venc-scratch/`](../../lab/venc-scratch/) `t113_h264enc` (VE `0x1667`):
**same `0x80000260` stall**, header bits only, 0-byte output. New datum closing the last
untested lever — `clk_summary` shows every VE clock at the **correct rate and enabled**:
`pll-ve`=402, `ve` core=402, `bus-ve`=200, `mbus-ve`=396 MHz. So the open reimpl's stall is
not a clock issue; it is the undocumented input-conversion→MB-encode register programming.

### (b) Driving the vendor cedarx blobs — the pipeline RUNS (revises the conclusion)

The device ships the full vendor encode stack (`/usr/lib/libvencoder.so` + `libvenc_h264.so`/
`libvenc_codec.so` + `libVE.so`/`libMemAdapter.so`) and a demo `/usr/bin/vencoderDemo`.
Running the demo (h264, 640×480, NV12):

- `VideoEncCreate` OK; **`VeInitialize` runs, `ic_version = 0x1301000010210`** — the vendor
  lib initialises the VE.
- `VideoEncInit` **succeeds** and validates input — it explicitly **rejects 64×64 as below
  the VE minimum size**. (So the open reimpl's 16×16/64×64 tests were under the HW minimum, a
  plausible contributor to *its* stall.)
- Execution **reaches `H264EncEncode`** (the codec encode in `libvenc_codec.so`) and
  **SIGSEGVs** there: `ldr r4,[r3,#40]`, `r3=0` — the **output bitstream-buffer context
  (`encctx+24`) is NULL** (passed to `BitStreamFreeBufferSize` just before the fault).

This is a **software** blocker (a NULL bitstream buffer in the vendor demo / ABI), **not** the
VE register stall. **The HW encoder initialises and the encode pipeline executes** —
contradicting the earlier "completes no codec op / dead silicon" conclusion. The SoC's H.264
encoder is functional at the init/pipeline level. Details + the `vetest.c` harness:
[`../../lab/venc-vendor/`](../../lab/venc-vendor/).

### Status / next steps

HW H.264 encode is **not yet producing output**, but the blocker is now identified as
**userspace cedarx ABI/buffer setup**, not the silicon:

- The H3-era `vencoder.h` is the wrong ABI for the newer T113 cedarx (`VencBaseConfig` has a
  `memops` pointer and a different `eInputFormat` offset) — recovering the exact T113
  `VencBaseConfig` (matching Tina/T113 header or full RE of `libvencoder.so:VideoEncInit`)
  lets the high-level API manage the bitstream buffer internally, sidestepping the demo's
  NULL.
- The shipped FF demo crashes for both h264 and jpeg → a demo/ABI bug, not codec-specific.

Until then, the deployed path remains **x264 software** (what stock firmwareExe uses) +
**MJPEG passthrough** for the camera (MJPEG-native sensor — see
[`2026-06-03-camera-streaming-options.md`](2026-06-03-camera-streaming-options.md)).
