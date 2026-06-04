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

### RESOLVED: the T113-S3 has NO H.264 encoder — JPEG/MJPEG only (and that works)

After recovering the correct T113 `VencBaseConfig` ABI (leading `bEncH264Nalu` flag + `memops`
pointer), the device's **own vendor library** runs the full H.264 encode — `VideoEncInit -> 0`,
`AllocInputBuffer -> 0` — then `H264EncFrame: wait interrupt overtime`. Live VE registers
(`ve_diag.ko`) show it frozen at `int_sts=0x80000260` (no FINISH bit), the `cedar_dev` IRQ
never increments, zero IOMMU faults, invariant across VE freq 200–576 MHz.

The reason is the silicon: **the Allwinner T113-S3 hardware video encoder does JPEG/MJPEG
only — not H.264** (it *decodes* H.264/H.265, but the encode block is JPEG/MJPEG; the H.264
encoder lives on the V3/V3s/S3, not the T113-S3). So driving `libvenc_h264` waits forever for
an interrupt that has no hardware to raise it.

**Proof the VE encoder is functional (HW JPEG completes):** same harness with
`VENC_CODEC_JPEG` → `encode -> 0`, **63 516-byte valid JPEG** (decodes as `mjpeg 640×480
yuvj420p`), and the **`cedar_dev` completion IRQ increments (2→3)** — which never happens for
H.264. Full detail: [`../../lab/venc-vendor/FINDINGS.md`](../../lab/venc-vendor/FINDINGS.md).

**Conclusion:** HW H.264 encode is **physically impossible** on the AD5M (no encoder silicon)
— stock FF uses **libx264 software** for this reason. The HW encoder this chip *does* have is
**JPEG/MJPEG**, which works; and the camera is MJPEG-native, so the HW-supported camera path
is MJPEG (passthrough today — see
[`2026-06-03-camera-streaming-options.md`](2026-06-03-camera-streaming-options.md)).
