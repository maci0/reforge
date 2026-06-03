# Cedar HW H.264 encoder probe (Stage 2)

A from-scratch userspace app that drives the AD5M's **Allwinner Cedar VE hardware H.264
encoder** via the vendor `libvenc` stack — to prototype a low-bandwidth camera stream
(H.264 → browser WebCodecs) instead of MJPEG. Background + the full options analysis:
[`docs/research/2026-06-03-camera-streaming-options.md`](../../docs/research/2026-06-03-camera-streaming-options.md).

## Status: runs, VE inits, blocked at encoder memory init

Working so far:
- Soft-float build matches the device ABI (the device libs are `0x5000202` soft-float).
- Binary runs; **Cedar VE initializes** (`VeInitialize: ic_version=0x1301000010210`).
- The full cedarc VENC API + struct layouts were recovered from the on-device libs' DWARF
  (`gdb ptype`/`sizeof`/`offsetof`), so the structs are driven by byte-offset = ABI-exact.

Blocker:
- `VideoEncInit` fails inside `H264InitMemory` with `h264Context->pBSMamager == NULL`
  (`venc_init_fail`). Ruled out: `memops` choice (`MemAdapterGetOpsS` vs the ION ops
  `__GetIonMemOpsS`), VBV size (matched the demo's 12 MB), every `VencH264Param` value
  (matched the demo's profile=High/CABAC), and `memops->open()`.
- The differentiator vs the stock `vencoderDemo` (which inits fine, then crashes later in
  `H264EncEncode`): the demo's **first `VENC_IndexParamProcSet` (1027)** call passes an
  internal **context pointer** (a lib address) that can't be reconstructed from outside the
  closed lib.

## Next steps
1. **Trace `libsdk_camera.so`** (the stock Android camera HAL) — it drives this exact VE
   successfully; capture its VENC init order + what the ProcSet pointer references, mirror it.
2. Or RE the `libvenc_codec.so` `H264InitMemory` path (what `pBSManager` actually needs).
3. Then finish the pipeline: camera MJPEG → NV12 → this encoder → Annex-B over WebSocket →
   browser `WebCodecs VideoDecoder`.

## Files
- `enc_nv12_h264.c` — the encoder app (NV12 file → H.264 file). Header comment has the full
  status + the recovered offsets.
- `build.sh` — cross-compile (needs a soft-float `arm-linux-gnueabi` gcc; see the script).
- `devlibs/` — the device's proprietary `libvenc*.so` (gitignored; fetch per `build.sh`).

## Reproduce the encode attempt (on device)
```sh
# generate a 30-frame 640x480 NV12 test clip with stock python3.7:
python3.7 -c 'W,H,N=640,480,30; uv=b"\x80"*(W*H//2); f=open("in.nv12","wb"); [f.write(bytes(((x+(n*12))&0xFF) for x in range(W))*H) or f.write(uv) for n in range(N)]'
./enc in.nv12 out.h264 640 480 30 15 1500
```
