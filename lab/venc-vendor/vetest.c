#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "vencoder.h"
/* padded base config: device VencBaseConfig is larger than the H3 header. Zero-pad so
   unknown trailing fields (incl eInputFormat) read 0 = YUV420SP/NV12. */
int main(int argc,char**argv){
    int W=argc>1?atoi(argv[1]):640, H=argc>2?atoi(argv[2]):480, N=argc>3?atoi(argv[3]):6;
    const char*outp=argc>4?argv[4]:"out.h264";
    unsigned int fmtval=argc>5?atoi(argv[5]):0;        /* 0=YUV420SP */
    int fmtoff=argc>6?atoi(argv[6]):-1;                /* if >=0, also write fmtval at this byte offset */
    FILE*out=fopen(outp,"wb");
    unsigned char cfg[256]; memset(cfg,0,sizeof cfg);
    unsigned int *u=(unsigned int*)cfg;
    u[0]=W; u[1]=H;            /* width,height @0,4 (confirmed via size check) */
    u[2]=W; u[3]=H; u[4]=W;    /* dstW,dstH,stride (repo layout best-guess) */
    u[5]=fmtval;               /* eInputFormat @20 (repo offset) */
    if(fmtoff>=0) *(unsigned int*)(cfg+fmtoff)=fmtval;

    VencH264Param h264; memset(&h264,0,sizeof h264);
    h264.sProfileLevel.nProfile=VENC_H264ProfileBaseline; /* 66 - distinct from fmt */
    h264.sProfileLevel.nLevel=VENC_H264Level31;
    h264.sQPRange.nMinqp=10; h264.sQPRange.nMaxqp=40;
    h264.nFramerate=15; h264.nBitrate=2000000; h264.nMaxKeyInterval=30;

    VideoEncoder*enc=VideoEncCreate(VENC_CODEC_H264);
    printf("enc=%p\n",(void*)enc); if(!enc)return 1;
    VideoEncSetParameter(enc,VENC_IndexParamH264Param,&h264);
    int z=0; VideoEncSetParameter(enc,VENC_IndexParamIfilter,&z);
    VideoEncSetParameter(enc,VENC_IndexParamRotation,&z);
    int r=VideoEncInit(enc,(VencBaseConfig*)cfg);
    printf("VideoEncInit -> %d\n",r);
    if(r){ printf("init failed\n"); return 2; }
    VencHeaderData sps; memset(&sps,0,sizeof sps);
    VideoEncGetParameter(enc,VENC_IndexParamH264SPSPPS,&sps);
    printf("SPS/PPS len=%u\n",sps.nLength);
    if(sps.pBuffer&&sps.nLength) fwrite(sps.pBuffer,1,sps.nLength,out);
    VencAllocateBufferParam bp; memset(&bp,0,sizeof bp);
    bp.nBufferNum=4; bp.nSizeY=W*H; bp.nSizeC=W*H/2;
    printf("AllocInputBuffer -> %d\n",AllocInputBuffer(enc,&bp));
    int ysz=W*H,csz=W*H/2, ok=0;
    unsigned char*y=malloc(ysz),*c=malloc(csz);
    for(int f=0;f<N;f++){
        for(int i=0;i<ysz;i++) y[i]=(unsigned char)((i+f*16)&0xFF);
        memset(c,0x80,csz);
        VencInputBuffer ib; memset(&ib,0,sizeof ib);
        r=GetOneAllocInputBuffer(enc,&ib); if(r){printf("f%d getbuf %d\n",f,r);break;}
        memcpy(ib.pAddrVirY,y,ysz); memcpy(ib.pAddrVirC,c,csz); ib.nPts=f*66666;
        FlushCacheAllocInputBuffer(enc,&ib);
        r=AddOneInputBuffer(enc,&ib); if(r){printf("f%d add %d\n",f,r);break;}
        r=VideoEncodeOneFrame(enc);
        printf("f%d VideoEncodeOneFrame -> %d\n",f,r);
        ReturnOneAllocInputBuffer(enc,&ib);
        if(r)break;
        VencOutputBuffer ob; memset(&ob,0,sizeof ob);
        if(GetOneBitstreamFrame(enc,&ob)==0){
            printf("f%d nSize0=%u nSize1=%u\n",f,ob.nSize0,ob.nSize1);
            if(ob.pData0&&ob.nSize0)fwrite(ob.pData0,1,ob.nSize0,out);
            if(ob.pData1&&ob.nSize1)fwrite(ob.pData1,1,ob.nSize1,out);
            FreeOneBitStreamFrame(enc,&ob); ok++;
        }
    }
    fclose(out); ReleaseAllocInputBuffer(enc); VideoEncUnInit(enc); VideoEncDestroy(enc);
    printf("DONE %d/%d -> %s\n",ok,N,outp); return ok>0?0:3;
}
