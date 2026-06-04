# venc-vendor — driving the device's stock cedarx H.264 encoder blobs

Follow-up to `../venc-scratch/` (open reimplementation, which stalled at `0x80000260`).
This drives the **device's own vendor cedarx encode stack** via the canonical VENC API
(`VideoEncCreate → VideoEncInit → AddOneInputBuffer → VideoEncodeOneFrame`), prompted by
`rosimildo/videoenc` (a working blob-based AW encoder).

## Breakthrough (2026-06-04): the vendor encode pipeline RUNS — it is NOT a dead-silicon stall

The device has the full vendor encode stack under `/usr/lib/`: `libvencoder.so` (high-level
API) → `libvenc_h264.so`/`libvenc_codec.so` plugins → `libVE.so` + `libMemAdapter.so` +
`libcdc_base.so`. Running the device's own `/usr/bin/vencoderDemo` (h264, 640×480, NV12):

- `VideoEncCreate` succeeds; **`cedarc VeInitialize` runs and reports `ic_version =
  0x1301000010210`** — the VE is initialised by the vendor lib.
- `VideoEncInit` **succeeds** (size + format validated: it explicitly *rejects* 64×64 as
  "less than ve support min size" — so the open reimpl's 16×16/64×64 tests were below the
  HW minimum, a likely contributor to its stall).
- It reaches **`H264EncEncode`** (the actual codec encode, in `libvenc_codec.so`) and
  **SIGSEGVs** there — `ldr r4,[r3,#40]` with `r3=0`: the **output bitstream-buffer context
  (`encctx+24`) is NULL** (it is passed to `BitStreamFreeBufferSize` right before the fault).

So this is a **software** blocker (a NULL bitstream buffer in the vendor demo/ABI), **not**
the VE register stall (`0x80000260`) the from-scratch reimpl hit. The HW encoder hardware
initialises and the pipeline executes — contradicting the earlier "dead silicon / completes
no codec op" conclusion. The SoC's H.264 encoder is functional at the init/pipeline level.

## Open thread / next steps
- The H3-era `vencoder.h` (from `rosimildo/videoenc`) is the **wrong ABI** for the device's
  newer T113 cedarx: `VencBaseConfig` differs (it has a `memops` pointer at ~offset 24 — a
  zeroed/garbage value faults `VideoEncInit`; `eInputFormat` is not at the H3 offset 20, so
  the lib read the H264 profile value 77 as the colour format). `vetest.c` here builds against
  the device `libvencoder.so` and is the harness to finish once the exact T113 `VencBaseConfig`
  layout is recovered (either the matching Tina/T113 cedarx header, or full RE of
  `libvencoder.so:VideoEncInit`).
- Fix target: the NULL `encctx+24` bitstream buffer — either supply the output buffer via the
  high-level API path (which `libvencoder.so` manages internally, sidestepping the demo's
  low-level bug) once `VideoEncInit` is fed a correct `VencBaseConfig`, or repair the demo's
  buffer setup.
- JPEG (`-f 1`) and H.264 both crash the same demo path → demo/ABI bug, not codec-specific.

## Reproduce (on device)
```sh
# device has /usr/bin/vencoderDemo + /usr/lib/libvenc*.so
python3.7 -c 'W,H,N=640,480,5;f=open("in.nv12","wb");[f.write(bytes(((x+n*16)&0xFF) for x in range(W))*H) or f.write(bytes([0x80])*(W*H//2)) for n in range(N)]'
LD_LIBRARY_PATH=/usr/lib gdb -batch -ex 'run -i in.nv12 -o out.h264 -s 640x480 -d 640x480 -if 0 -f 0 -n 2 -b 2000' -ex bt /usr/bin/vencoderDemo
#   -> SIGSEGV in H264EncEncode (encctx+24 NULL bitstream buffer)
```
