/* H.264 HW encode via the device's vendor cedarx blobs. Correct T113 VencBaseConfig
   (recovered from a live VideoEncInit dump): leading bEncH264Nalu flag + memops pointer. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "vencoder.h"
extern void* MemAdapterGetOpsS(void);
extern int VideoEncoderSetFreq(void*, int);

/* real T113 layout (32 bytes) */
typedef struct {
    int           bEncH264Nalu;  /* 0x00 */
    unsigned int  nInputWidth;   /* 0x04 */
    unsigned int  nInputHeight;  /* 0x08 */
    unsigned int  nDstWidth;     /* 0x0c */
    unsigned int  nDstHeight;    /* 0x10 */
    unsigned int  nStride;       /* 0x14 */
    unsigned int  eInputFormat;  /* 0x18  0=YUV420SP */
    void*         memops;        /* 0x1c */
    unsigned int  pad[8];        /* slack for any trailing internal fields */
} T113BaseConfig;

int main(int argc,char**argv){
    int W=argc>1?atoi(argv[1]):640,H=argc>2?atoi(argv[2]):480,N=argc>3?atoi(argv[3]):6;
    const char*outp=argc>4?argv[4]:"out.h264";
    unsigned int fmt=argc>5?atoi(argv[5]):0;
    setvbuf(stdout,0,_IONBF,0);
    FILE*out=fopen(outp,"wb");

    T113BaseConfig cfg; memset(&cfg,0,sizeof cfg);
    cfg.bEncH264Nalu=0; cfg.nInputWidth=W; cfg.nInputHeight=H;
    cfg.nDstWidth=W; cfg.nDstHeight=H; cfg.nStride=W; cfg.eInputFormat=fmt;
    cfg.memops=MemAdapterGetOpsS();
    printf("memops=%p fmt=%u %dx%d\n",cfg.memops,fmt,W,H);

    VencH264Param h264; memset(&h264,0,sizeof h264);
    h264.sProfileLevel.nProfile=VENC_H264ProfileMain;
    h264.sProfileLevel.nLevel=VENC_H264Level31;
    h264.sQPRange.nMinqp=10; h264.sQPRange.nMaxqp=40;
    h264.nFramerate=15; h264.nBitrate=2000000; h264.nMaxKeyInterval=30;

    VideoEncoder*enc=VideoEncCreate(VENC_CODEC_H264);
    printf("enc=%p\n",(void*)enc); if(!enc)return 1;
    VideoEncSetParameter(enc,VENC_IndexParamH264Param,&h264);
    int z=0; VideoEncSetParameter(enc,VENC_IndexParamIfilter,&z);
    VideoEncSetParameter(enc,VENC_IndexParamRotation,&z);
    int vefreq=argc>6?atoi(argv[6]):0;
    if(vefreq){ int fr=VideoEncoderSetFreq(enc,vefreq); printf("SetFreq(%d)->%d\n",vefreq,fr); }
    int r=VideoEncInit(enc,(VencBaseConfig*)&cfg);
    printf("VideoEncInit -> %d\n",r); if(r){printf("init failed\n");return 2;}
    VencHeaderData sps; memset(&sps,0,sizeof sps);
    VideoEncGetParameter(enc,VENC_IndexParamH264SPSPPS,&sps);
    printf("SPS/PPS len=%u\n",sps.nLength);
    if(sps.pBuffer&&sps.nLength) fwrite(sps.pBuffer,1,sps.nLength,out);
    VencAllocateBufferParam bp; memset(&bp,0,sizeof bp);
    bp.nBufferNum=4; bp.nSizeY=W*H; bp.nSizeC=W*H/2;
    printf("AllocInputBuffer -> %d\n",AllocInputBuffer(enc,&bp));
    int ysz=W*H,csz=W*H/2,ok=0; unsigned char*y=malloc(ysz),*c=malloc(csz);
    for(int f=0;f<N;f++){
        for(int i=0;i<ysz;i++) y[i]=(unsigned char)((i+f*16)&0xFF);
        memset(c,0x80,csz);
        VencInputBuffer ib; memset(&ib,0,sizeof ib);
        r=GetOneAllocInputBuffer(enc,&ib); if(r){printf("f%d getbuf %d\n",f,r);break;}
        memcpy(ib.pAddrVirY,y,ysz); memcpy(ib.pAddrVirC,c,csz); ib.nPts=(long long)f*66666;
        FlushCacheAllocInputBuffer(enc,&ib);
        r=AddOneInputBuffer(enc,&ib); if(r){printf("f%d add %d\n",f,r);break;}
        r=VideoEncodeOneFrame(enc);
        printf("f%d encode -> %d\n",f,r);
        ReturnOneAllocInputBuffer(enc,&ib); if(r)break;
        VencOutputBuffer ob; memset(&ob,0,sizeof ob);
        if(GetOneBitstreamFrame(enc,&ob)==0){
            printf("f%d bytes=%u+%u\n",f,ob.nSize0,ob.nSize1);
            if(ob.pData0&&ob.nSize0)fwrite(ob.pData0,1,ob.nSize0,out);
            if(ob.pData1&&ob.nSize1)fwrite(ob.pData1,1,ob.nSize1,out);
            FreeOneBitStreamFrame(enc,&ob); ok++;
        }
    }
    fclose(out); ReleaseAllocInputBuffer(enc); VideoEncUnInit(enc); VideoEncDestroy(enc);
    printf("DONE %d/%d -> %s\n",ok,N,outp); return ok>0?0:3;
}
