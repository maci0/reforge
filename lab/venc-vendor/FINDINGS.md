# T113 Cedar VE H.264 HW encode — definitive register-level finding (2026-06-04)

Drove the device's **own vendor cedarx blobs** (`/usr/lib/libvencoder.so` + plugins) through
the full canonical encode, with the **correct T113 ABI** recovered from a live `VideoEncInit`
dump (`vetest.c`). This is the furthest the encode path has been driven.

## The vendor library runs the full encode — then the VE stalls in hardware

```
memops=…  640x480
VeInitialize ic_version = 0x1301000010210
VideoEncInit -> 0            # SUCCESS (correct VencBaseConfig: leading bEncH264Nalu flag + memops ptr)
AllocInputBuffer -> 0        # SUCCESS
H264EncFrame: h264 encoder wait interrupt overtime   # VE never completes
f0 encode -> -1
```

Recovered T113 `VencBaseConfig` (32 B): `bEncH264Nalu@0, nInputWidth@4, nInputHeight@8,
nDstWidth@0xc, nDstHeight@0x10, nStride@0x14, eInputFormat@0x18 (0=YUV420SP),
memops@0x1c (= MemAdapterGetOpsS())`. The H3-era header (offset-by-4, no memops) was why
earlier attempts faulted / read profile 77 as the colour format.

## Live VE registers during the encode (via `../ve-kmod/ve_diag.ko`, ioremap — concurrent)

Polled ~50× across the entire interrupt-wait — **completely frozen**:

```
enc int_ctl@0xb14 = 0x01000007   # FINISH interrupt IS enabled (bit0)
enc int_sts @0xb1c = 0x80000260   # busy(b31)+PUTBITS(b9)+b6+b5, NO FINISH(b0) — never changes
GIC irq98 (cedar_dev): enabled=1 pending=0 active=0   # never goes pending
MBUS VE_cnt@0xb0 = 800 (frozen)   # VE did a little DRAM traffic then STOPPED
IOMMU: enable=1 bypass=0x72 (translates) int_sta=0 fault_addr=0   # zero faults
```

`cedar_dev` IRQ count stays **1** across every encode attempt (it does NOT increment) — the
engine never raises its completion interrupt because it never reaches FINISH.

## Conclusion: the VE encoder does not complete on this unit — hardware, not software

The exact `0x80000260` stall is reached by **two fully independent code paths**:
1. the open from-scratch reimpl (`../venc-scratch/`), and
2. **Allwinner's own vendor library** (correct ABI, correct programming, FINISH-IRQ enabled).

…and it is invariant across **all VE clock rates** (200/300/402/480/576 MHz, set via
`VideoEncoderSetFreq`), with no IOMMU fault and the interrupt correctly wired+enabled. The
engine goes busy, does a little DMA, and freezes in the input-conversion→MB-encode stage.

Because the vendor's own library cannot drive this VE to completion, the blocker is **not**
software/ABI/clock/IOMMU/interrupt — it is the **encode engine itself on this T113-S3 unit**
(defective or fused-off encode path; the register interface, clocks, DMA and IOMMU all
respond, but the codec core never finishes). This is consistent with stock FlashForge using
**libx264 software** and never invoking the VE encoder. No reachable software/kernel lever
changes the `0x80000260` stall.

`vetest.c` here is the working harness (correct ABI) for any future attempt that has a
known-good T113 VE-encode reference or a kernel/silicon fix to compare against.

## RESOLVED (2026-06-04): T113-S3 has NO H.264 encoder — only JPEG/MJPEG, and that WORKS

The Allwinner **T113-S3 datasheet/specs confirm the hardware video encoder does JPEG/MJPEG
only** — it *decodes* H.264/H.265/MPEG/VC1, but its independent HW **encoder is JPEG/MJPEG,
not H.264**. So the `0x80000260` H.264 stall is not a defect or a software bug: **there is no
H.264 encode block in this silicon.** The `libvenc_h264.so` blob exists (Allwinner ships it
family-wide), but on the T113-S3 the H.264 encode path has no hardware to drive, so triggering
it waits forever for an interrupt that can never come.

**Proof the VE encoder itself is functional — HW JPEG encode completes:** the same harness
(`vetest.c codec=1`) with `VENC_CODEC_JPEG`:

```
codec=JPEG
VideoEncInit -> 0
AllocInputBuffer -> 0
f0 encode -> 0              # SUCCESS (vs -1 / "wait interrupt overtime" for H.264)
f0 bytes=63516             # valid JPEG: ff d8 ff e0 .. JFIF, decodes as mjpeg 640x480 yuvj420p
cedar_dev IRQ: 2 -> 3      # the VE raised its completion interrupt (NEVER happens for H.264)
```

So: the VE hardware encoder works and fires its completion IRQ for **JPEG/MJPEG**; for H.264
the IRQ never fires and the engine sits at `0x80000260` — because the H.264 encoder block is
absent. (`bbs.aw-ol.com` T113-S3 datasheet; linux-sunxi T113-s3; Bootlin V3/V3s/S3 H.264
encoder — the H.264 encoder is on the V3/V3s/S3, **not** the T113-S3.)

### Bottom line
- **HW H.264 encode is not achievable on the AD5M (T113-S3) — the silicon has no H.264
  encoder.** Stock FF uses libx264 software for this reason.
- The HW encoder this chip *does* have is **JPEG/MJPEG**, and it works (proven above). Since
  the AD5M camera is MJPEG-native, the HW-supported camera path is MJPEG (passthrough today;
  HW re-encode possible but unnecessary for an already-MJPEG sensor).
