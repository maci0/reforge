# Camera streaming — is there a better way than MJPEG? (research)

Date: 2026-06-03. Question: forward the camera stream **1:1** and decode browser-side in
**WASM/JS** instead of the current mjpg-streamer path — is that better? Researched against
the **actual hardware** (live probe) plus the streaming ecosystem.

## Hardware facts (probed on the live unit)

- **Camera = UVC webcam `U0AS01A-0`, MJPEG-only.** `v4l2-ctl --list-formats-ext /dev/video0`
  enumerates a single pixel format: `'MJPG' (Motion-JPEG, compressed)`, resolutions up to
  1920×1080 @ 30 fps. **No YUYV, no raw, no native H.264** off the sensor.
- **T113 has a hardware video engine (Allwinner "Cedar" VE).** `/dev/cedar_dev` exists and the
  vendor encode libs are present: `libVE.so`, `libvenc_h264.so`, `libvenc_h265.so`,
  `libvenc_jpeg.so`, `libvencoder.so`. So **hardware H.264/H.265/JPEG encode is available** —
  via the proprietary `cedarx`/`libvenc` stack (not a mainline V4L2 M2M encoder).
- forge-x today: `S98camera` → `mjpg_streamer` `input_uvc.so … -b 1` (single buffer) +
  `_REDUCE_MEM_PARAMS`, default 640×480 @ 15 fps.

## Verdict on the specific idea (MJPEG 1:1 → WASM/JS decode)

**No benefit — and likely worse.** Because the camera *already emits MJPEG*:

1. `mjpg_streamer` is **already a 1:1 forwarder** — it muxes the camera's JPEG frames into
   `multipart/x-mixed-replace` with **no re-encode** (near-zero CPU). There's no transcode to
   remove; "forward 1:1" is the current behaviour.
2. The browser already decodes those JPEGs with its **native, hardware-path JPEG decoder**
   (an `<img>`/multipart swap, or `createImageBitmap`). A **WASM/JS JPEG decoder would be
   slower** and burn main-thread/CPU on the client for zero quality or bandwidth gain.

So moving JPEG decode into WASM is a step sideways at best. The only way "decode in the
browser" pays off is by switching to a **better codec** — i.e. inter-frame compression
(H.264/H.265), which MJPEG fundamentally lacks (every frame is an independent JPEG).

## Where the real win is — H.264 via the Cedar HW encoder → browser decode

MJPEG's weakness is **bandwidth**: each 640×480 frame ≈ 30–60 KB, no inter-frame delta, so
~0.5–1 MB/s, scaling badly toward 1080p. H.264 with P-frames is typically **5–10× smaller**
for equal quality. The T113 can encode it **in hardware** (Cedar), so the printer CPU stays
free. Two viable transport/decode options on the client:

- **WebCodecs `VideoDecoder`** — decodes H.264 in-browser, hardware-accelerated, low resource;
  feed it the elementary stream over WebSocket. Modern, simple. Caveats: some reported
  latency / "1-in-1-out" quirks for live low-latency use; browser support is good but not
  universal on old clients.
- **WebRTC** (what `ayufan/camera-streamer` does on the Pi) — lowest latency, robust, but
  heavier (signalling, ICE). Overkill for a print monitor where ~0.5–1 s latency is fine.

### The catch — why it's a spike, not a drop-in
- The camera gives **MJPEG, not raw**, so H.264 needs a **transcode**: `MJPEG → HW JPEG-decode
  (Cedar) → HW H.264-encode (Cedar libvenc_h264)`. The VE can do both, but it's the
  **proprietary vendor stack**, not mainline V4L2 M2M.
- Therefore the obvious off-the-shelf tools **don't work out-of-box here**:
  - `ayufan/camera-streamer` (the Klipper SOTA: HW MJPEG + H.264 + WebRTC) targets the
    **Raspberry Pi** V4L2 stateful encoder — it has no Allwinner Cedar backend.
  - `ustreamer` is MJPEG-focused (HW-JPEG offload on Pi), no Cedar H.264.
- Proof the building block exists: `rosimildo/videoenc` is an Allwinner Cedar H.264 encoder
  demo using the same `libvenc` family the T113 ships. So a **custom pipeline** (or a gstreamer
  build with the sunxi cedar plugins) using `libvenc_h264.so` is feasible — but it's real
  integration work, and the transcode consumes CMA/VE buffers (bounded, but non-trivial on the
  16 MB CMA budget).

## Options summary

| option | CPU | bandwidth | client | effort | notes |
|---|---|---|---|---|---|
| **A. MJPEG passthrough** (current, `mjpg_streamer -b 1`) | ~0 (no re-encode) | high (no inter-frame) | native JPEG | shipped | fine at 640×480; already low-RAM; **avoids the stock leak** |
| **A′. ustreamer (MJPEG)** | ~0 | high | native JPEG | low | more robust/lower-latency than mjpg-streamer; still MJPEG |
| **B. H.264 via Cedar HW → WebCodecs/WebRTC** | low (HW encode) | **5–10× lower** | WebCodecs / WebRTC | **high** | the real upgrade; needs custom `libvenc` pipeline (no Pi-style tool works); CMA/VE buffers |
| **C. H.264 software (x264)** | **pegs both A7s** | low | WebCodecs | med | ❌ rejected — no spare CPU during prints |
| **D. MJPEG 1:1 → WASM JPEG decode** | ~0 | high | WASM | med | ❌ no benefit — native JPEG decode already beats WASM |

## Recommendation

1. **For RAM** (the original concern): MJPEG passthrough with `-b 1` is already minimal; the
   memory *leak* was the **stock gstreamer/libsdk_camera** path, not MJPEG. Nothing to fix
   here beyond keeping the mod's streamer + only running the camera when needed.
2. **Drop the WASM-JPEG-decode idea** — it's a sideways move; native decode wins.
3. **If bandwidth/quality/1080p is the goal**, the right project is **H.264 via the Cedar HW
   encoder → WebCodecs** (or WebRTC). It's the genuinely better architecture and the hardware
   supports it, but it's a **spike**: build a `libvenc_h264` (or gstreamer-sunxi) transcode
   pipeline — no Pi-targeted tool (camera-streamer/ustreamer) supports Cedar out of the box.
   Validate VE/CMA buffer cost on the 16 MB CMA budget before committing.
4. Low-effort interim: evaluate **ustreamer** in place of mjpg-streamer (more robust, lower
   latency, still MJPEG) — but it's not a codec change, so no bandwidth win.

## Sources
- [ayufan/camera-streamer](https://github.com/ayufan/camera-streamer) (HW MJPEG/H.264/WebRTC; Pi-targeted) · [streaming.md](https://github.com/ayufan/camera-streamer/blob/main/docs/streaming.md)
- [rosimildo/videoenc — Allwinner Cedar H.264 encoder demo](https://github.com/rosimildo/videoenc)
- [WebCodecs API (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/WebCodecs_API) · [w3c/webcodecs #732 (1-in-1-out latency)](https://github.com/w3c/webcodecs/issues/732)
- [Mainsail/Crowsnest streaming backends](https://docs.mainsail.xyz/crowsnest/faq/backends/)
- Device probe (this unit): `v4l2-ctl --list-formats-ext` → MJPG-only; `/dev/cedar_dev` + `libvenc_h264/h265/jpeg.so` present.
