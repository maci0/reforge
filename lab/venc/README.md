# Cedar HW H.264 encoder probe (Stage 2)

A from-scratch userspace app that drives the AD5M's **Allwinner Cedar VE hardware H.264
encoder** via the vendor `libvenc` stack — to prototype a low-bandwidth camera stream
(H.264 → browser WebCodecs) instead of MJPEG. Background + the full options analysis:
[`docs/research/2026-06-03-camera-streaming-options.md`](../../docs/research/2026-06-03-camera-streaming-options.md).

## Status: software init fully SOLVED; blocked at the VE hardware completion (BSP-level)

**The entire libvenc software layer was reverse-engineered and works** — this app reaches a
valid HW encode submission. The VE encode hardware then never signals completion, the **same
wall that breaks every vendor encode demo** on this firmware.

### Solved (undocumented anywhere — recovered by RE)
- **ABI:** device libs are **soft-float** (`0x5000202`, `/lib/ld-linux.so.3`); the ReForge
  hard-float toolchain can't link them — built with a **Linaro `arm-linux-gnueabi`** gcc.
- **`pBSManager==NULL` wall:** `VideoEncCreate(codecType)` **dlopen's the codec plugin by
  type**. `0` (`VENC_CODEC_H264`) → `libvenc_codec.so` = **broken** on this BSP (the stock
  `vencoderDemo` crashes here too). `2` (`VENC_CODEC_H264_VER2`) → `libvenc_h264.so` = the
  **working** encoder. Must **also not link `-lvenc_codec`** (its broken `H264Init` interposes).
- **Ops:** `VencBaseConfig.memops = __GetIonMemOpsS()` (the ION ops, not `MemAdapterGetOpsS`),
  `veOpsS = GetVeOpsS(0)` (`0` = `getVeAwOpsS`; the **type arg is required** — garbage → wrong
  ops → VE never completes).
- **RC config:** `VencH264Param.sRcParam` framerates (`uInputFrmRate@176`, `uOutputFrmRate@180`)
  + post-init `VENC_IndexParamFramerate`/`Bitrate`, else divide-by-zero in init / `rc_init_frame`.
- All struct layouts/offsets recovered from the libs' DWARF.

Result: `VideoEncInit` succeeds, the input ION buffer has valid phys addrs (`phyY=0x2c00000`),
the VE clock is on, and `h264EncFrame` submits the encode.

### Blocked (kernel/BSP, not a config tweak)
- `h264EncFrame: "h264 encoder wait interrupt overtime"` — the VE encode HW never raises its
  completion IRQ (no kernel fault in dmesg). `VideoEncodeOneFrame` → -1, 0 bytes.
- **Identical across all vendor demos**: `vencoderDemo` (crashes on the pBSManager bug),
  `demoVencVdec` and `encoderTest` (reach encode, produce 0 bytes). The cedar driver *does*
  support encode IRQs (`en_irq_flag`), so the VE itself isn't completing — the standalone
  `libvenc` path doesn't set up what the integrated camera HAL (`libsdk_camera.so`, Android)
  does (the full **ISP + VE** pipeline). A `rc_init_frame` float (`ctx+4`) divide is bypassed
  here with a gdb poke; even bypassed, the VE still times out — so it's not the blocker.

## libsdk_camera trace (what actually drives the VE) + why it's blocked

Traced `libsdk_camera.so` (the stock Android camera HAL):
- It uses the **same `libvenc` API** (`VideoEncSetParameter`/`VideoEncDestroy`/`VideoEncUnInit`/
  `VideoEncoderReset`) — not a different mechanism — via class **`RecordCamera`**
  (`RecordCamera::setVideoEncParm` / `::encode` / `::encode_rtsp`). Those are **imported** by
  libsdk_camera, i.e. **defined in the stock `firmwareExe`** (the QT app at
  `/opt/PROGRAM/software/5.1.4/firmwareExe`, 9.5 MB, **stripped**).
- libvenc also has an **ISP integration** (`VideoEncIspCreate`, `pEncIsp`, `nJustIspFlag`,
  `bUseCsiColorFormat`) — the stock encode feeds the VE from the camera/ISP, and supports
  `V4L2_PIX_FMT_H264` capture.

Decisive hardware fact: **`/proc/interrupts` IRQ 44 `cedar_dev` = 0 since boot** — the VE has
**never** raised a completion IRQ on this device. The VE clocks run (pll-ve/ve @ 402 MHz), but
the engine is dormant: forge-x runs `guppyscreen` + `mjpg_streamer` (USB-UVC **MJPEG**), the
stock `firmwareExe`/`RecordCamera` (the only thing that drives VE encode) is **not running**,
and a hung leftover `demoVencVdec` holding `/dev/cedar_dev` was ruled out (killed, no change).

So: my from-scratch app reaches a valid VE encode **submission**, but the VE never completes —
the same `wait interrupt overtime` that breaks every standalone vendor demo. The working config
lives in the stripped, non-running `firmwareExe::RecordCamera::setVideoEncParm`.

## Levers exhausted against the VE-completion wall
Every standalone encode (mine + all 3 vendor demos) hits `wait interrupt overtime`, VE IRQ=0:
- ✅ full software init solved (codec=2, no `-lvenc_codec`, `__GetIonMemOpsS`, `GetVeOpsS(0)`, RC fields)
- ✅ valid ION input (phyY=0x2c00000), VE clocks @402 MHz, `VideoEncoderSetFreq(402)`
- ❌ **no V4L2 M2M encoder** exists (only `uvcvideo` + `cedar_dev`); the kernel offers no
  alternative encode API.
- ❌ killing a hung `demoVencVdec` holding `/dev/cedar_dev` → no change.
- ❌ `VideoEncIspCreate` is **not** the missing step — `demoVencVdec` (which passes init) never
  calls it and still fails; `h264EncFrame` calls `set_isp_info`/`SetIspRegister` unconditionally.

## Hardware-level diagnosis (kernel module — `../ve-kmod/`)
Built a vermagic-matched diagnostic kernel module (`ve_diag.ko`, `5.4.61 SMP preempt ...
ARMv7 p2v8`) that ioremaps the VE registers (`0x01C0E000`) + GIC and dumps them during an
encode. Findings:
- **The VE is fully alive but STALLS:** during the encode `MACC_VE_STATUS` (enc int_sts
  @0xb1c) = `0x80000260` — the busy/working bit (31) is set, but the "done" bits (the `&0xf`
  the cedar ISR checks) **never set**. So the engine starts the op and hangs; it never reaches
  completion, so it never asserts its IRQ. **GIC irq98 = enabled, pending=0** (delivery is
  fine), VE **MMU regs @0xe00 = all 0 (MMU off)**, clocks @402 MHz, reset deasserted.
- **Root cause = a memory-address mismatch the VE can't resolve.** Register dump during encode
  (decoded via linux-sunxi VE_Register_guide: ISP bank @0xa00, AVC-encoder bank @0xb00):
  ISP/internal buffer addrs `ra78=0x01e00000 ra7c=0x01e80000` are **below DRAM base
  `0x40000000`** (System RAM = `0x40000000-0x47ffffff`), while another buffer `r0b4=0x40c7d000`
  is **full-physical**. The encoder's allocators hand the VE addresses in **two different
  spaces** (some DRAM-relative, some full-physical); with the VE MMU off and no DRAM-base offset
  applied, the relative ones point at nonexistent memory → the VE reads garbage and hangs.
- Fix attempts that did NOT resolve it: `LD_PRELOAD` shim forcing `address_macc=0x40000000`
  (`macc_shim.c` — the lib doesn't use it for buffer addrs); self-allocating the input via the
  ION memops (`palloc` needs the encoder's internal VE context, returns garbage standalone);
  the driver's `set_sys_cfg_by_self` SRAM-remap is "for codec test", not the DRAM base.
- **Resumable next step:** the exact per-buffer address computation lives in the **T113
  `libcedarc` source** (100ASK TinaSDK `package/allwinner/.../libcedarc/`). Reading how it
  derives each buffer's VE address (relative vs full, any shift/offset) pins the one allocator
  to make consistent. The diagnostic module gives live register read/poke to verify a fix.

## Proven from every angle: the VE never completes ANY operation
- **Encode:** `wait interrupt overtime`, `GetOneBitstreamFrame` → `gr=5, nSize0=0, pData0=NULL`
  (no output produced, not just unread).
- **Decode:** fed a valid H.264/MP4 to the vendor `demoVdecoder` — parses the stream, but
  produces **no decoded frames** and the IRQ stays 0.
- **`/proc/interrupts` IRQ 44 `cedar_dev` = 0 across both** and **since boot** — the VE has never
  raised a completion interrupt for encode *or* decode on this unit.
- All three vendor demos (`vencoderDemo`/`demoVencVdec`/`encoderTest`) fail identically.

So this is **not** encode-specific and **not** a config bug — the Cedar VE engine's completion
IRQ simply never fires. (Notable: the driver `#define SUNXI_IRQ_VE 90` but `cedar_dev` registers
at GIC hwirq **98** — a possible DT/IRQ-mapping mismatch, unverifiable without kernel access.)
Fixing it is a kernel/DT/VE-register effort (no `/dev/mem` here; production printer) — below
userspace, beyond this POC.

## Where it stands (accurate, not over-claimed)
The VE is fully **powered, clocked (402 MHz), reset-deasserted** (cedar driver
`reset_control_deassert`), **configured and kicked** (`h264_config_registers` + `_StartSlice`/
`SetH264RegVer2` write the encode + start registers), fed a **valid ION input** — yet it
**never raises its completion IRQ** (`cedar_dev` count = 0 since boot). Every standalone encode
(this app + all 3 vendor demos) fails identically; no userspace config or kernel lever I can
reach changes it, and `/dev/mem` is absent so the VE register state can't be read back.

So the blocker is at the **VE-encode-completion level**, below userspace — the engine is told to
encode but doesn't signal done. The only code that has ever driven this VE to completion is the
stock `firmwareExe`/`RecordCamera` pipeline (with ISP), which forge-x doesn't run; and the AD5M's
camera is **USB-UVC** (no MIPI sensor), so both stock and forge-x stream it as **MJPEG** and the
VE encoder is effectively unused on this unit. Whether the standalone path is missing a final
register/IOMMU/ISP step the HAL does, or the VE encode is simply non-operational for the USB
camera, can't be resolved without VE register access or the running stock pipeline.

**Practical outcome:** HW H.264/H.265 encode is not achievable standalone here. **MJPEG
(`mjpg_streamer`) is the working camera path** and is already in place. A genuine future attempt
would have to run/trace the stock `firmwareExe` camera-record path live (so the VE fires its IRQ)
and mirror its full setup — a large, hardware-coupled effort beyond this POC.

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
