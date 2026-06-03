# venc-scratch — from-scratch T113 Cedar VE H.264 encoder (open, no closed blob)

A from-scratch userspace H.264 encoder for the AD5M's Allwinner T113 Cedar VE,
**bypassing the closed `libvenc` stack entirely**. Ported from Jens Kuske's
reverse-engineered `cedrus/h264enc` (GPLv2) and adapted to the T113 BSP driver.
This is the open-pipeline approach (vs `../venc/`, which drives the closed blob).

## What works (the breakthrough)
- **Userspace VE register access** — `mmap(/dev/cedar_dev, 0)` maps the VE
  registers (`cedardev_mmap` hardcodes `MACC_REGS_BASE`). No kernel module needed.
  `step1_version.c` proves it: **VE_VERSION = 0x1667** (same VE 1.x family jemk RE'd
  on the A20, ver ~0x1625 — so the register layout is largely compatible).
- **Buffers + IOMMU** — `step2_ion.c`: ION alloc (`/dev/ion`) → `IOCTL_GET_IOMMU_ADDR`
  (0x502) → VE IOVA. The low IOVAs (`0x300000`…) are exactly the "below-DRAM relative"
  addresses seen in the closed lib — **they were valid IOMMU IOVAs all along**, not the
  bad addresses earlier diagnosed.
- **The VE bitstream/header engine WORKS** — `t113_h264enc.c` drives `put_bits` and the
  VE emits real H.264 SPS/PPS/slice-header bits; `VE_AVC_VLE_LENGTH` increments
  correctly (e.g. 248 bits for an IDR header). This is a genuine partial HW encode.

## The wall (MB encode never completes — proven from every angle)
`VE_AVC_TRIGGER` starts the macroblock encode (`VE_AVC_STATUS` busy bit 31 sets) but
the engine **never completes**: status stalls at **`0x80000260`**, no output MB data,
`cedar_dev` IRQ stays 0 (the VE has never raised a completion IRQ on this unit, boot-to-now).
Identical stall across **all three**:
1. jemk's exact A20-proven sequence,
2. the **vendor's own** captured register config (dumped live at its `WAIT_VE_EN` ioctl), and
3. a faithful replication of the vendor config in this clean harness.

**Instrumented to the floor (this is not a guess):**
- **Memory path is PROVEN correct.** With the extended `../ve-kmod/ve_diag.ko` reading the
  IOMMU (`0x02010000`) live during the stall: `ENABLE=1`, `BYPASS=0x72` (**bit 0 clear → the
  VE, master 0 on sun8iw20, translates — not bypass**), `INT_STA=0`, fault-address `=0`. The
  VE accesses its IOVAs through the IOMMU with **zero faults** — the input/output mappings are
  valid and the hard part of the open port (memory) is solved.
- The engine therefore hangs **internally**, not on memory. `IOCTL_WAIT_VE_EN` is passive
  (just `wait_event_timeout` on the IRQ), so polling `STATUS` is equivalent.
- **Even a single 16×16 macroblock hangs** (same `0x80000260`, no MB output) — structural, not
  a scaling/edge issue. Trigger scan confirms `0x8` is the only value that starts the engine.

Findings that pin it:
- **T113 ISP encoding differs from jemk's A20** (recovered from the vendor lib's regs):
  `a00=(W/8)<<16|(H/8)`, `a14=mb_width`, `a2c=(H/8)<<16|(W/8)` — applied via `VENDOR=1`.
- **The reconstruction (rec/ref) buffer registers are unknown on the T113**: jemk's
  offsets (`0xba0`/`0xbb0`/`0xbc0`) **reject writes** (read back 0), and the vendor's
  standalone demo **never sets them either** (which is likely why it stalls too). A
  brute-force sweep writing a valid rec IOVA to every offset in the low/ISP/AVC banks
  (`0x080–0x0fc`, `0xa00–0xbfc`) changed the stall at **no** offset.
- Completion is not a config tweak reachable standalone: the only code that has ever
  driven this VE to completion is the stock `firmwareExe`/`RecordCamera` pipeline — which
  **never runs**, because the AD5M camera is **USB-MJPEG** and stock just forwards MJPEG
  (verified: `firmwareExe` holds `/dev/video0` as `MJPG`, loads no venc/cedar libs, never
  opens `/dev/cedar_dev`).

## UPDATE — the VE is NOT inert: the ISP engine (0xa) responds to its trigger
A later finding revises the "completes nothing" conclusion below. The linux-sunxi
VE_Register_guide shows the VE has a **separate ISP engine (0xa)** with its own trigger
(`MACC_ISP_TRIG` 0xa0c, 1=launch), feeding the **AVC engine (0xb)** — a two-stage pipeline
neither jemk's A20 code nor the standalone path runs. Implemented it (`ISP2=1`):
- Selecting engine 0xa and writing `a0c=1` makes the ISP status `a10` go **0→1, reproducibly,
  and ONLY when the trigger is written** (control test with the trigger skipped leaves it 0).
  So the engine is **not inert** — it deterministically acknowledges the ISP trigger.
- BUT no visible converted output yet (the T113 ISP **source/output address registers differ
  from the guide's gen** — guide's `a00` is width/16, the T113 lib uses width/8 — and a scan of
  candidate source offsets produced nothing at `a70/a74`), and the AVC engine (0xb) still stalls.

So the encode is most likely a **solvable register-programming problem** (correct T113 ISP
source/output mapping + ISP→AVC coupling), not dead silicon. Remaining RE: map the T113 ISP
source/output registers (the guide is a different VE gen) and the ISP→AVC hand-off.

**Honest correction (follow-up):** the `a10 0→1` is a *shallow trigger-acknowledge, NOT real
processing.* A cache-invalidated scan of **all** allocated buffers after the ISP trigger shows
the input buffer holds its data (DRAM r/w confirmed) but the ISP wrote **nothing anywhere** — no
converted output in any buffer. So the engine responds to the trigger register but does no actual
frame work under any config I can reach; my source-register guesses are wrong and the correct
T113 ISP source/output regs remain unknown (the guide is a different VE gen, and the vendor's own
standalone code never runs a separate ISP stage). Net: a register-level response, but still **no
reachable configuration produces actual VE output** (encode, ISP-convert, or decode).

## (earlier) The AVC engine / single-stage flow never completes ANY op
Converging evidence that this is the **VE revision / unit**, not the code:
- **jemk's register sequence is PROVEN on the A20 (VE 0x1625); it hangs identically here
  (VE 0x1667).** Same register layout, different revision — the T113 encode-completion path
  needs something the A20 doesn't, and it's undocumented.
- **`cedar_dev` IRQ = 0 since boot**, across *every* attempt: my encoder, all three vendor
  encode demos, **and decode**. Decode confirmed with a *proper MP4 container*
  (`demoVdecoder -i big.mp4`): awplayer parses it fine (H.264 320×240, `VeInitialize` runs,
  ION opens), but over 200 frames / 14 s it produces **zero decoded frames and zero IRQs**.
  Decode is an entirely separate, well-understood code path from encode — its identical
  failure proves the codec *engine* completes nothing, independent of any encode-config theory.
  The engine goes *busy* but **never signals completion for encode OR decode** — and we poll
  the status register directly (not just the IRQ), so it's the engine, not IRQ routing.
- Per-frame `RESET_VE` (the vendor's exact per-frame procedure) does not change it.
- `firmwareExe` **doesn't even load `libvenc`** — RecordCamera's encode path is dead code in
  this firmware; the VE codec is genuinely unused on this unit (clocks on, engine powered —
  it goes busy — but no codec op ever completes).

So the missing piece is in the T113-specific encode-engine programming that only the stock
`RecordCamera` pipeline performs — which never runs (USB-MJPEG camera) and is stripped. No
reachable open or closed code on this device completes a VE codec op to copy from.

## Practical conclusion
HW H.264 encode does **not** complete in any standalone configuration reachable on this
unit — the vendor's own tools fail identically, and the missing piece (T113 rec/ref setup
+ completion handshake) is undocumented silicon with no working on-device reference to copy.
Moreover it's **moot for this camera**: the USB sensor is MJPEG-native (already compressed),
so streaming uses MJPEG forwarding (`mjpg_streamer`, already in place); HW H.264 would only
add an MJPEG-decode→H.264-encode round-trip. This directory stands as a complete, open RE
**platform** (register mmap + ION/IOMMU + working bitstream engine + live capture tooling)
for any future attempt that obtains the T113 VE encode register map or a running stock pipeline.

## Files
- `step1_version.c` — prove userspace VE register mmap + read VE version.
- `step2_ion.c` — ION alloc + IOMMU mapping (buffer → VE IOVA).
- `t113_h264enc.c` — the encoder. Env knobs: `VENDOR=1` (T113 ISP encoding),
  `VECTRL=<hex>`, `POLLMS`, `DUMP=1` (register dump), `SCANOFF=<hex>` (rec-reg scan).
- `reg_dump.c` — passive full-register dumper (no ioctls; safe during a live encode).
- `probe.c` — map which AVC-bank registers accept arbitrary writes.
- Build: `arm-linux-gnueabi-gcc -O2 -march=armv7-a -mfloat-abi=soft` (soft-float; `-lrt`).

## Reproduce
```sh
# on device (NV12 test clip via stock python3.7):
python3.7 -c 'W,H,N=640,480,4; uv=b"\x80"*(W*H//2); f=open("in.nv12","wb"); [f.write(bytes(((x+n*20)&0xFF) for x in range(W))*H) or f.write(uv) for n in range(N)]'
VENDOR=1 DUMP=1 ./t113_h264enc in.nv12 out.h264 640 480 1 10 1   # stalls at status 0x80000260
```
