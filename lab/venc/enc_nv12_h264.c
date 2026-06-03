/* enc_nv12_h264.c — minimal Allwinner Cedar (cedarc) hardware H.264 encoder.
 *
 * Reads raw NV12 (YUV420SP) frames from a file, HW-encodes baseline H.264 via the
 * vendor libvencoder, writes the Annex-B elementary stream to a file.
 *
 *   enc_nv12_h264 <in.nv12> <out.h264> <width> <height> <nframes> [fps] [kbps]
 *
 * Struct field offsets/sizes were extracted from the on-device libs' DWARF
 * (gdb ptype / sizeof / offsetof) so this matches the installed ABI exactly,
 * without rebuilding the nested cedarc structs by hand. See
 * docs/research/2026-06-03-camera-streaming-options.md (Stage 2).
 *
 * STATUS (2026-06-03): the ENTIRE software init layer is SOLVED (a from-scratch result not
 * documented anywhere) — but the VE encode HARDWARE does not complete on this BSP, the same
 * wall that breaks every vendor encode demo. Detail:
 *
 *  SOLVED (this file gets all the way to a valid HW encode submission):
 *   - ABI: device libs are SOFT-float (0x5000202) -> built with Linaro arm-linux-gnueabi.
 *   - pBSManager==NULL wall: VideoEncCreate(codec) dlopen's the codec plugin BY TYPE.
 *     0 (VENC_CODEC_H264) -> libvenc_codec.so == BROKEN on this BSP. 2 (VENC_CODEC_H264_VER2)
 *     -> libvenc_h264.so == the working encoder. ALSO must NOT link -lvenc_codec (else its
 *     broken H264Init interposes). [codec is set to 2 below]
 *   - VencBaseConfig.memops = __GetIonMemOpsS() (the ION ops), veOpsS = GetVeOpsS(0)
 *     (0 = getVeAwOpsS; the type arg is REQUIRED — garbage -> wrong ops).
 *   - RC config: VencH264Param.sRcParam framerates (uInputFrmRate@176/uOutputFrmRate@180)
 *     + post-init VENC_IndexParamFramerate/Bitrate, else divide-by-zero in init/rc_init_frame.
 *   - Struct layouts/offsets all recovered from the libs' DWARF (sizeof/offsetof).
 *   Result: VideoEncInit succeeds, the input ION buffer has valid phys addrs (phyY=0x2c00000),
 *   the VE clock is enabled, and h264EncFrame is reached and submits the encode to the VE.
 *
 *  BLOCKED (kernel/BSP level, NOT a config tweak):
 *   - h264EncFrame: "h264 encoder wait interrupt overtime" — the VE encode hardware never
 *     raises its completion IRQ (no kernel fault in dmesg). VideoEncodeOneFrame returns -1,
 *     0 bytes out. This is IDENTICAL across ALL vendor demos (vencoderDemo crashes earlier on
 *     the same pBSManager bug; demoVencVdec and encoderTest both reach encode and produce 0
 *     bytes). The cedar driver DOES support encode IRQs (en_irq_flag), so the VE simply isn't
 *     completing — the standalone libvenc path doesn't set up whatever the integrated camera
 *     HAL (libsdk_camera.so, Android) does (ISP + VE pipeline). The remaining rc_init_frame
 *     float (ctx+4) divide is bypassed here only by a gdb poke; even bypassed, the VE still
 *     times out, so it is not the blocker.
 *
 *  CONCLUSION: standalone HW H264/H265 encode is blocked on this firmware at the VE-completion
 *  level. Getting it working requires the libsdk_camera HAL path (full ISP+VE camera pipeline),
 *  not this standalone app. MJPEG (mjpg_streamer) remains the working camera path. See
 *  docs/research/2026-06-03-camera-streaming-options.md (Stage 2).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ---- cedarc VENC API (opaque handles; structs passed as raw buffers) ---- */
extern void *VideoEncCreate(int codecType);          /* VENC_CODEC_H264 = 0 */
extern int   VideoEncInit(void *enc, void *baseConfig);
extern int   VideoEncSetParameter(void *enc, int indexType, void *param);
extern int   AllocInputBuffer(void *enc, void *allocParam);
extern int   GetOneAllocInputBuffer(void *enc, void *inputBuffer);
extern int   FlushCacheAllocInputBuffer(void *enc, void *inputBuffer);
extern int   AddOneInputBuffer(void *enc, void *inputBuffer);
extern int   VideoEncodeOneFrame(void *enc);
extern int   AlreadyUsedInputBuffer(void *enc, void *inputBuffer);
extern int   ReturnOneAllocInputBuffer(void *enc, void *inputBuffer);
extern int   GetOneBitstreamFrame(void *enc, void *outputBuffer);
extern int   FreeOneBitStreamFrame(void *enc, void *outputBuffer);
extern void  VideoEncDestroy(void *enc);
extern void  VideoEncoderSetFreq(void *enc, int freqMHz);
extern void *MemAdapterGetOpsS(void);
extern void *__GetIonMemOpsS(void);   /* returns &_ionMemOpsS — the ops the encoder needs
                                         (MemAdapterGetOpsS returns a different table whose
                                         alloc can't back the H264 bitstream buffer) */
extern void *GetVeOpsS(int type);     /* type 0 -> getVeAwOpsS (&_veAwOpsS, the AW VE ops for
                                         H264); type 1 -> VP9. MUST pass 0 — calling with
                                         garbage returns NULL/wrong ops -> the VE encode HW
                                         never completes ("wait interrupt overtime"). */

/* ---- enums (from DWARF) ---- */
/* IMPORTANT: VideoEncCreate(codecType) dlopen's the codec plugin BY TYPE:
 *   0 (VENC_CODEC_H264)      -> libvenc_codec.so  — BROKEN on this BSP (BitStreamCreate
 *                              returns NULL -> pBSManager NULL; stock vencoderDemo crashes too)
 *   2 (VENC_CODEC_H264_VER2) -> libvenc_h264.so   — WORKS (what demoVencVdec uses)
 * Use VER2. Also do NOT link -lvenc_codec (build.sh): if it's loaded at startup its broken
 * H264Init interposes over libvenc_h264's even when codec=2. */
#define VENC_CODEC_H264            2      /* = VENC_CODEC_H264_VER2 (the WORKING plugin) */
#define VENC_PIXEL_YUV420SP        0      /* NV12 */
#define VENC_IndexParamBitrate     0
#define VENC_IndexParamFramerate   1
#define VENC_IndexParamH264Param   256
#define VENC_H264ProfileBaseline   66
#define VENC_H264Level31           31
#define VENC_FRAME_CODING          0

/* ---- struct sizes (gdb: print sizeof) ---- */
#define SZ_BASECONFIG  44
#define SZ_H264PARAM   196
#define SZ_INPUTBUF    344
#define SZ_OUTPUTBUF   64

/* ---- field offsets (gdb: print &((T*)0)->field) ---- */
/* VencBaseConfig */
#define O_BC_INW    4
#define O_BC_INH    8
#define O_BC_DSTW   12
#define O_BC_DSTH   16
#define O_BC_STRIDE 20
#define O_BC_FMT    24
#define O_BC_MEMOPS 28
#define O_BC_VEOPS  32
/* VencH264Param */
#define O_H_PROFILE 0
#define O_H_LEVEL   4
#define O_H_CABAC   8
#define O_H_MAXQP   12
#define O_H_MINQP   16
#define O_H_FPS     20
#define O_H_BITRATE 24
#define O_H_KEYINT  28
#define O_H_CODING  32
/* VencInputBuffer */
#define O_IN_ID     0
#define O_IN_PTS    8
#define O_IN_PHYY   20
#define O_IN_PHYC   24
#define O_IN_VIRY   28
#define O_IN_VIRC   32
/* VencOutputBuffer */
#define O_OUT_SIZE0 20
#define O_OUT_SIZE1 24
#define O_OUT_DATA0 28
#define O_OUT_DATA1 32

#define SETI(buf, off, val)  (*(int32_t *)((char *)(buf) + (off)) = (int32_t)(val))
#define SETP(buf, off, ptr)  (*(void **)((char *)(buf) + (off)) = (void *)(ptr))
#define GETI(buf, off)       (*(int32_t *)((char *)(buf) + (off)))
#define GETP(buf, off)       (*(void **)((char *)(buf) + (off)))

int main(int argc, char **argv)
{
    if (argc < 6) {
        fprintf(stderr, "usage: %s <in.nv12> <out.h264> <w> <h> <nframes> [fps] [kbps]\n", argv[0]);
        return 2;
    }
    const char *inpath = argv[1], *outpath = argv[2];
    int w = atoi(argv[3]), h = atoi(argv[4]), nframes = atoi(argv[5]);
    int fps = (argc > 6) ? atoi(argv[6]) : 15;
    int kbps = (argc > 7) ? atoi(argv[7]) : 1500;
    int ysz = w * h, csz = w * h / 2, fsz = ysz + csz;

    FILE *fin = fopen(inpath, "rb"), *fout = fopen(outpath, "wb");
    if (!fin || !fout) { perror("open"); return 1; }
    unsigned char *frame = malloc(fsz);

    void *memops = __GetIonMemOpsS();
    if (!memops) { fprintf(stderr, "__GetIonMemOpsS() == NULL\n"); return 1; }
    /* ScMemOpsS layout: open() is field 0. The ION mem subsystem must be opened before
     * the encoder allocates the bitstream buffer from it (else pBSManager == NULL). */
    { int (*mopen)(void *) = (int (*)(void *))((void **)memops)[0];
      if (mopen) fprintf(stderr, "memops->open() = %d\n", mopen(memops)); }

    void *enc = VideoEncCreate(VENC_CODEC_H264);
    if (!enc) { fprintf(stderr, "VideoEncCreate failed\n"); return 1; }

    /* H.264 params. Mirror the stock demo's working values (profile High, CABAC on);
     * fps + bitrate live in this struct, so we do NOT set them via separate indices
     * (the demo doesn't either). */
    char h264[SZ_H264PARAM]; memset(h264, 0, sizeof(h264));
    SETI(h264, O_H_PROFILE, 100);               /* VENC_H264ProfileHigh (demo value) */
    SETI(h264, O_H_LEVEL,   51);
    SETI(h264, O_H_CABAC,   1);
    SETI(h264, O_H_MAXQP,   50);
    SETI(h264, O_H_MINQP,   10);
    SETI(h264, O_H_FPS,     fps);
    SETI(h264, O_H_BITRATE, kbps * 1000);
    SETI(h264, O_H_KEYINT,  fps);               /* 1 keyframe/sec */
    SETI(h264, O_H_CODING,  VENC_FRAME_CODING);
    /* rate-control frame rates (VencH264Param.sRcParam @68: uInputFrmRate @+108=176,
     * uOutputFrmRate @+112=180). Left 0 they cause a divide-by-zero (bitrate/framerate)
     * inside libvenc_h264. */
    SETI(h264, 176, fps);
    SETI(h264, 180, fps);
    /* eRcMode = AW_CBR (0): rc_init_frame skips the float-framerate divide for modes <=2
     * (FIXQP=4 hits it). uStatTime kept non-zero. */
    SETI(h264, 68, 0);        /* eRcMode = AW_CBR */
    SETI(h264, 112, 1000);    /* uStatTime */
    VideoEncSetParameter(enc, VENC_IndexParamH264Param, h264);
    /* VBV (bitstream) buffer size — without it H264InitMemory's pBSManager is NULL.
     * Match the demo's 12 MB. */
    unsigned int vbv[2] = { 12u * 1024 * 1024, 0 };   /* VENC_IndexParamSetVbvSize = 15 */
    VideoEncSetParameter(enc, 15, vbv);
    /* NOTE: the stock demo also calls VENC_IndexParamProcSet (1027) twice before init; its
     * FIRST call carries internal context pointers (a lib address) that cannot be
     * reconstructed from outside. This is the current blocker — see the STATUS header. */

    /* base config — the crucial part the stock demo left NULL: memops */
    char bc[SZ_BASECONFIG]; memset(bc, 0, sizeof(bc));
    SETI(bc, O_BC_INW, w);  SETI(bc, O_BC_INH, h);
    SETI(bc, O_BC_DSTW, w); SETI(bc, O_BC_DSTH, h);
    SETI(bc, O_BC_STRIDE, w);
    SETI(bc, O_BC_FMT, VENC_PIXEL_YUV420SP);
    SETP(bc, O_BC_MEMOPS, memops);
    SETP(bc, O_BC_VEOPS, GetVeOpsS(0));     /* 0 = AW VE ops (_veAwOpsS) for H264 */
    if (VideoEncInit(enc, bc) != 0) { fprintf(stderr, "VideoEncInit failed\n"); return 1; }

    /* RC framerate/bitrate set AFTER init (cedarc convention) — the encoder's framerate
     * float is otherwise 0 -> /0 in rc_init_frame. */
    int fr = fps, br = kbps * 1000;
    VideoEncSetParameter(enc, VENC_IndexParamFramerate, &fr);
    VideoEncSetParameter(enc, VENC_IndexParamBitrate,   &br);
    VideoEncoderSetFreq(enc, 402);   /* VE engine clock — unset => HW stalls, never IRQs */

    /* internal ION input pool: {nBufferNum, nSizeY, nSizeC} */
    struct { uint32_t n, y, c; } alloc = { 4, (uint32_t)ysz, (uint32_t)csz };
    AllocInputBuffer(enc, &alloc);

    long long pts = 0, dt = 1000000LL / (fps > 0 ? fps : 15);
    long total = 0;
    fprintf(stderr, "init+alloc OK; fin=%p frame=%p fsz=%d nframes=%d\n", (void*)fin, (void*)frame, fsz, nframes);
    for (int i = 0; i < nframes; i++) {
        size_t got = fread(frame, 1, fsz, fin);
        fprintf(stderr, "iter %d: fread=%zu/%d\n", i, got, fsz);
        if (got != (size_t)fsz) break;

        char in[SZ_INPUTBUF]; memset(in, 0, sizeof(in));
        if (GetOneAllocInputBuffer(enc, in) != 0) { fprintf(stderr, "GetOneAllocInputBuffer @%d\n", i); break; }
        unsigned char *vy = GETP(in, O_IN_VIRY), *vc = GETP(in, O_IN_VIRC);
        if (!vy || !vc) { fprintf(stderr, "null vir buffer @%d (vy=%p vc=%p)\n", i, (void*)vy, (void*)vc); break; }
        memcpy(vy, frame, ysz);
        memcpy(vc, frame + ysz, csz);
        SETI(in, O_IN_ID, i);
        *(long long *)(in + O_IN_PTS) = pts; pts += dt;
        FlushCacheAllocInputBuffer(enc, in);
        AddOneInputBuffer(enc, in);

        int er = VideoEncodeOneFrame(enc);
        if (er != 0) fprintf(stderr, "VideoEncodeOneFrame rc=%d @%d (continuing)\n", er, i);
        AlreadyUsedInputBuffer(enc, in);
        ReturnOneAllocInputBuffer(enc, in);

        char out[SZ_OUTPUTBUF]; memset(out, 0, sizeof(out));
        if (GetOneBitstreamFrame(enc, out) == 0) {
            int s0 = GETI(out, O_OUT_SIZE0), s1 = GETI(out, O_OUT_SIZE1);
            unsigned char *d0 = GETP(out, O_OUT_DATA0), *d1 = GETP(out, O_OUT_DATA1);
            if (s0 > 0 && d0) { fwrite(d0, 1, s0, fout); total += s0; }
            if (s1 > 0 && d1) { fwrite(d1, 1, s1, fout); total += s1; }
            FreeOneBitStreamFrame(enc, out);
        }
        if ((i % 10) == 0) fprintf(stderr, "frame %d ok, %ld bytes\n", i, total);
    }

    VideoEncDestroy(enc);
    fclose(fin); fclose(fout); free(frame);
    fprintf(stderr, "done: %ld bytes of H.264 written to %s\n", total, outpath);
    return total > 0 ? 0 : 3;
}
