# Camera streaming — is there a better way than MJPEG? (research)

> **Update (partly superseded):** the "real win = H.264 via the Cedar VE" thesis here is a dead
> end — the T113-S3 has **no H.264 encoder in silicon** (JPEG/MJPEG only), per
> [2026-06-04-cedar-ve-encode-and-camera-fw.md](2026-06-04-cedar-ve-encode-and-camera-fw.md). What
> shipped is **ustreamer** MJPEG passthrough on `:8080` (`S72camera`), not the mjpg-streamer path
> this doc calls "current". The MJPEG/WASM analysis below still stands.

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
  (Cedar) → HW H.264-encode (Cedar)`. The VE can do both.
- **Encode driver state (the load-bearing detail):**
  - **Mainline `cedrus` is decode-only** — MPEG2 (5.0), H264 (5.2), H265 — **no encode**.
  - **Hardware encode is real but out-of-tree.** The Allwinner VE has done HW **H.264 (baseline
    profile) + JPEG/MJPEG encode since the sun5i/sun7i era** — linux-sunxi: *"the video engine can
    only encode h264 in baseline profile."* Open implementations exist for that **legacy VE**:
    Jens Kuske's libcedrus, and PoCs like `milosladni/sunxi-tvin2jpeg_h264` (HW H264 + JPEG
    encoder for A10/A13/A20). Separately, Bootlin shipped an open V4L2 **H.264 encoder** driver
    (2023) for the **V3/V3s/S3** camera SoCs. So the capability is well established across
    generations — just never mainlined (no stable stateless-encoder uAPI yet).
  - **Baseline-only is fine for us:** a camera monitor wants low latency, and baseline H.264 (no
    B-frames) is exactly the low-latency, trivially-decodable profile — every browser / WebCodecs
    handles it. The profile limit is not a blocker for this use case.
  - **BUT every open encoder targets a different VE generation than ours.** The sun5i/sun7i PoCs
    (A13 etc.) use the **legacy VE register interface**; Bootlin's V4L2 encoder targets the
    **V3/V3s/S3** camera VE. The **T113 is the newer D1-class VE** (sun8iw20p1, H265-decode-capable)
    — different programming model, so neither the A13 PoC nor the V3/S3 driver runs on it as-is.
    (Naming trap: the "**S3**" in *T113-S3* is Allwinner's **stacked-DRAM package suffix**,
    **unrelated** to the V-series "S3/V3s" camera SoCs.) The emerging cedrus-encode work is moving
    toward newer parts (an **H616 cedrus-encoder** test effort + the FOSDEM-2024 stateless-encode
    uAPI push), and T113≈D1 may eventually ride that — but **no open V4L2 encoder exists for the
    T113 today**. Porting the legacy/V3 encode work to this VE = dedicated driver effort.
  - **What works on the T113 right now is the proprietary `cedarx`/`libvenc` blob** — the device
    already ships `libvenc_h264.so` / `libvenc_jpeg.so` / `libVE.so`, and the stock camera app
    uses exactly that stack. `rosimildo/videoenc` is a working example of Cedar H.264 encode via
    `libvenc` on Allwinner.
- Net: the off-the-shelf Klipper tools **don't work out-of-box** —
  `ayufan/camera-streamer` (HW MJPEG/H264/WebRTC) and `ustreamer` both target the **Raspberry Pi**
  V4L2 stateful encoder, no Allwinner Cedar backend. The H.264 path therefore means either (a) a
  **custom pipeline over the vendor `libvenc`** (works today, closed blob), or (b) **porting the
  open cedrus stateless encoder** to the T113 VE generation (open, but real driver work). Either
  way the transcode consumes VE/CMA buffers — bounded but non-trivial on the 16 MB CMA budget.

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

## Prototyping the vendor `libvenc` H.264 pipeline on the device (works today)

The closed `cedarx`/`libvenc` stack is already installed, **and so is a ready-made CLI test
tool** — `/usr/bin/vencoderDemo` (links `libvencoder.so`/`libvenc_h264.so`/`libVE.so`,
`/dev/cedar_dev`). It is a complete **file→file hardware encoder**, so the HW H.264 path can be
proven with **zero custom code**:

```
vencoderDemo -h        # options:
#  -i input.yuv  -if 0(=YUV420SP/NV12)  -f 0(=h264 | 1=jpeg | 3=h265)
#  -s 640x480 (src)  -d 640x480 (dst)  -b <kbps>  -qp_min/-qp_max  -n <frames>  -o out.h264
```

Staged plan (each stage independently verifiable):

- **Stage 0 — prove HW H.264 encode.** *Attempted live 2026-06-03 — partial result, documented
  so the next attempt starts ahead:*
  - VE hardware + driver **init OK**: `vencoderDemo` triggers `enable_cedar_hw_clk` (dmesg), and
    `/dev/cedar_dev` + `/dev/ion` (the VE memory backend) are present; CMA had 27 MB free (not a
    limiter).
  - **But `vencoderDemo` segfaults inside the encode call** — for **both** `-f 0` (H264) and `-f 1`
    (JPEG). gdb: `SIGSEGV in H264EncEncode (libvenc_codec.so)` at `ldr r4,[r3,#40]` with **`r3=0`**
    → a **NULL encoder-context member** at encode time. So the generic Tina sample does **not**
    fully initialize *this* BSP's `libvenc` build (almost certainly the input frame needs an
    **ION physical address** the demo's CLI path doesn't wire — both codecs share the same
    buffer-setup, hence both crash). `/etc/cedarx.conf`/`cedarc.conf` are decoder-only, no help.
  - The path that **does** drive this VE successfully is FlashForge's stock **`libsdk_camera.so`**
    — an **Android camera HAL** (`android::V4L2CameraDevice`, `Libve_*`) that allocates via ION.
  - **Revised next step:** don't rely on the stock demo. Either (a) trace how `libsdk_camera`
    sets up the ION input buffer + VENC init and mirror it, or (b) go straight to the Stage-2
    custom app using the VENC API with **explicit ION-allocated input** (`VencQueueInputBuffer`
    with both virtual *and* physical addrs). The hardware is proven reachable; the gap is the
    correct ION buffer init, not the encoder itself.
- **Stage 1 — camera MJPEG → NV12.** The sensor is MJPEG-only, so decode to NV12 first. Device
  `ffmpeg` has **no cedar encoder and no hwaccels** (minimal build), but it can CPU-decode MJPEG
  cheaply at 640×480: `ffmpeg -f v4l2 -input_format mjpeg -i /dev/video0 -pix_fmt nv12 -f rawvideo - `.
  (Later: replace CPU JPEG-decode with the VE's HW JPEG **decoder** via `cedrus`/`libvecore` to
  drop CPU further.)
- **Stage 2 — custom VENC app.** *Attempted live 2026-06-03 — substantial progress, blocked at
  encoder memory init; code + harness in [`lab/venc/`](../../../lab/venc/).* Findings:
  - Recovered the **full cedarc VENC API + struct layouts** from the on-device libs' DWARF
    (`gdb ptype`/`sizeof`/`offsetof`) and wrote `enc_nv12_h264.c` driving structs by byte-offset
    (ABI-exact). API is the canonical `VideoEncCreate/VideoEncInit/VideoEncSetParameter/
    GetOneAllocInputBuffer/AddOneInputBuffer/VideoEncodeOneFrame/GetOneBitstreamFrame`.
  - **ABI gotcha:** the device `libvenc*.so` are **soft-float** (`0x5000202`, `/lib/ld-linux.so.3`)
    — the ReForge buildroot toolchain is hard-float and **cannot** be used. Built with a
    soft-float **Linaro `arm-linux-gnueabi`** gcc instead.
  - The binary **runs and the Cedar VE initializes** (`VeInitialize: ic_version=0x1301000010210`),
    reaching `H264InitMemory` — but init fails there: **`h264Context->pBSMamager == NULL`**
    (`venc_init_fail`). Ruled out by tracing the working stock demo and matching it: `memops`
    choice (`MemAdapterGetOpsS` vs the ION ops `__GetIonMemOpsS`), VBV size (12 MB), all
    `VencH264Param` values (profile=High/CABAC), and `memops->open()`.
  - **Software init fully SOLVED** (continued RE): the `pBSManager==NULL` wall is that
    `VideoEncCreate(codecType)` **dlopen's the codec plugin by type** — `0` (`VENC_CODEC_H264`)
    → the **broken** `libvenc_codec.so` (the stock `vencoderDemo` crashes here too), `2`
    (`VENC_CODEC_H264_VER2`) → the **working** `libvenc_h264.so`; you must also **not link
    `-lvenc_codec`** (its broken `H264Init` interposes). Plus `memops=__GetIonMemOpsS()`,
    `veOpsS=GetVeOpsS(0)` (the type arg is required), and RC framerate fields. With these,
    `VideoEncInit` succeeds, the input ION buffer is valid, and `h264EncFrame` submits the encode.
  - **BLOCKED at the VE hardware (BSP-level):** `h264EncFrame: "h264 encoder wait interrupt
    overtime"` — the VE never raises its completion IRQ (no kernel fault). `VideoEncodeOneFrame`
    → -1, 0 bytes. **Identical across all vendor demos** (`vencoderDemo` crashes earlier;
    `demoVencVdec`/`encoderTest` reach encode, emit 0 bytes). The cedar driver supports encode
    IRQs, so the VE itself isn't completing — the standalone `libvenc` path doesn't set up what
    the integrated **`libsdk_camera`** HAL does (ISP+VE pipeline).
  - **Conclusion:** standalone HW H264/H265 encode is blocked on this firmware at the
    VE-completion level; it needs the `libsdk_camera` HAL (ISP+VE) path, not a standalone app.
    **MJPEG (`mjpg_streamer`) stays the working camera path.** Full write-up + the RE'd encoder:
    [`lab/venc/`](../../../lab/venc/).
- **Stage 3 — transport + browser decode.** Emit the H.264 **Annex-B** elementary stream over a
  WebSocket; a ~50-line HTML page feeds NAL units to **WebCodecs `VideoDecoder`**
  (`codec:"avc1.42E01E"` = baseline). Alternatively reuse on-device gstreamer for RTP
  (`gst-inspect-1.0` confirms `h264parse`, `rtph264pay` are present) toward a WebRTC bridge.
  Validate end-to-end latency + bitrate vs the current MJPEG.

This proves the win **today** on the closed blob; only Stage 2's glue app is new code. The
result is a low-CPU, ~5–10× lower-bandwidth stream than MJPEG.

## Open driver — porting / reverse-engineering plan

Goal: replace the closed `libvenc` with an **open V4L2 (stateless) encoder** for the T113 VE, so
ReForge can ship HW H.264/JPEG encode without the vendor blob. We start with a big head start —
**the BSP ships the kernel-side VE driver source**: `vendor/kernels/tina-bsp-kernel/drivers/media/cedar-ve/`
(`cedar_ve.c`, `cedar_ve.h`, `ve_mem_list.h`, `flush_cache.S`). That driver is the *plumbing*
(VE MMIO mapping to userspace, clocks, reset, CMA/IOMMU buffers, the `/dev/cedar_dev` ioctls); the
**encode register programming lives in the closed userspace `libvenc`** — that's the RE target.

Plan:
1. **Pin the VE generation.** Read `cedar_ve.c` for the compatible/variant, VE register base,
   clock/reset, and ioctl set. The T113 (sun8iw20p1) is **D1-class**; map it against known gens
   (legacy sun5i, V3/S3, H6/H616) to pick the closest open reference.
2. **Trace the vendor encode.** Run `vencoderDemo -f 0` (deterministic via `-c` compare) and
   capture the register sequence. The userspace lib `mmap`s the VE registers (not all via
   ioctl), so use **MMIO tracing**: `mmiotrace`/ftrace on the VE region, or instrument `cedar_ve.c`
   to log writes, or a devmem snapshot diff around `VencInit`/per-frame. Capture (a) init, (b)
   reference-frame/buffer setup, (c) the per-frame encode kick + bitstream readout.
3. **Warm up on JPEG, then H.264.** Do the **JPEG/MJPEG encoder first** — a far simpler register
   sequence (no motion estimation, no inter-frame), ideal to learn this VE's encode block — then
   tackle **H.264 baseline** (CAVLC, QP-only, no B-frames — which is also the HW's documented
   limit, so the profile target matches exactly).
4. **Cross-reference open work.** Map the captured sequence against Bootlin's **cedrus H.264
   encoder** (V3/S3) source, the **H616 `v4l2-cedrus-enc-test`**, and the linux-sunxi
   **VE_Register_guide** to interpret fields rather than blind-decode.
5. **Implement + validate.** Write it as a V4L2 stateless M2M encoder modeled on Bootlin's
   `cedrus-enc` (so it can ride the emerging stateless-encode uAPI and make
   `ustreamer`/`camera-streamer` usable unmodified once they speak that uAPI). Validate
   bit-exact / decodable against `vencoderDemo -c`.
6. **Upstream.** Align with the Bootlin/Kocialkowski stateless-encoder effort so the T113/D1 VE
   becomes a supported encoder variant rather than a private fork.

Effort is real but bounded by two assets most RE efforts lack: the **vendor kernel driver
source** (plumbing already solved) and a **deterministic reference encoder** (`vencoderDemo`) to
diff against. Start with JPEG encode as the cheap proof-of-method.

## Sources
- [ayufan/camera-streamer](https://github.com/ayufan/camera-streamer) (HW MJPEG/H.264/WebRTC; Pi-targeted) · [streaming.md](https://github.com/ayufan/camera-streamer/blob/main/docs/streaming.md)
- [rosimildo/videoenc — Allwinner Cedar H.264 encoder demo (libvenc)](https://github.com/rosimildo/videoenc)
- [Bootlin — open-source V4L2 H.264 encoder for Allwinner V3/V3s/S3 (2023, out-of-tree)](https://bootlin.com/blog/open-source-linux-kernel-support-for-the-allwinner-v3-v3s-s3-h-264-video-encoder/) · [CNX coverage](https://www.cnx-software.com/2023/11/17/allwinner-vpu-open-source-h264-hardware-video-encoder-linux-driver/)
- [linux-sunxi: Cedrus](https://linux-sunxi.org/Cedrus) (mainline = decode-only) · [VE encode JPEG/H264 (H3/A20 PoC thread)](https://linux-sunxi.narkive.com/dAlIku99/ve-encondig-jpeg-h264-for-h3)
- [bootlin/v4l2-cedrus-enc-test — H616 Cedrus encoder issue](https://github.com/bootlin/v4l2-cedrus-enc-test/issues/1) · FOSDEM 2024 "V4L2 Stateless Video Encoding" (Kocialkowski)
- [linux-sunxi: VE_Register_guide](https://linux-sunxi.org/VE_Register_guide) · [milosladni/sunxi-tvin2jpeg_h264 (HW H264+JPEG encode PoC)](https://github.com/milosladni/sunxi-tvin2jpeg_h264)
- On-device: `/usr/bin/vencoderDemo` (cedarx VENC sample, file→file HW H264/JPEG/H265 encode). In-repo: `vendor/kernels/tina-bsp-kernel/drivers/media/cedar-ve/` (kernel VE driver source — `cedar_ve.c`).
- [WebCodecs API (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/WebCodecs_API) · [w3c/webcodecs #732 (1-in-1-out latency)](https://github.com/w3c/webcodecs/issues/732)
- [Mainsail/Crowsnest streaming backends](https://docs.mainsail.xyz/crowsnest/faq/backends/)
- Device probe (this unit): `v4l2-ctl --list-formats-ext` → MJPG-only; `/dev/cedar_dev` + `libvenc_h264/h265/jpeg.so` present.
