/* t113_h264enc.c — from-scratch Allwinner T113 (VE ver 0x1667) H.264 encoder.
 *
 * Ported from Jens Kuske's reverse-engineered cedrus/h264enc (GPLv2), adapted to
 * the T113 cedar BSP driver: VE registers via mmap(/dev/cedar_dev), buffers via
 * ION + IOCTL_GET_IOMMU_ADDR (IOMMU IOVA written to the VE regs). Bypasses the
 * closed libvenc entirely. Completion detected by POLLING VE_AVC_STATUS (the VE
 * never raises its completion IRQ on this unit, so we don't wait on it).
 *
 * Env knobs for on-device iteration:
 *   VECTRL=<hex>   override the VE_CTRL value ve_get() writes (engine select)
 *   VEFREQ=<dec>   VE clock MHz (default 402)
 *   POLLMS=<dec>   status poll timeout ms (default 2000)
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <linux/types.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>

/* ---- T113 cedar ioctls (cedar_ve.h enum) ---- */
#define IOCTL_GET_ENV_INFO    0x101
#define IOCTL_WAIT_VE_EN      0x103
#define IOCTL_RESET_VE        0x104
#define IOCTL_ENABLE_VE       0x105
#define IOCTL_DISABLE_VE      0x106
#define IOCTL_SET_VE_FREQ     0x107
#define IOCTL_ENGINE_REQ      0x206
#define IOCTL_ENGINE_REL      0x207
#define IOCTL_GET_IOMMU_ADDR  0x502
#define IOCTL_FREE_IOMMU_ADDR 0x503

/* ---- ION + dma-buf ---- */
struct ion_allocation_data { __u64 len; __u32 heap_id_mask; __u32 flags; __u32 fd; __u32 unused; };
#define ION_IOC_ALLOC _IOWR('I',0,struct ion_allocation_data)
struct user_iommu_param { int fd; unsigned int iommu_addr; };
struct dma_buf_sync { __u64 flags; };
#define DMA_BUF_IOCTL_SYNC _IOW('b',0,struct dma_buf_sync)
#define DMA_BUF_SYNC_RW 3
#define DMA_BUF_SYNC_END (1<<2)

/* ---- VE registers (jemk offsets; confirmed matching T113 hardware dump) ---- */
#define VE_CTRL             0x000
#define VE_VERSION          0x0f0
#define VE_ENGINE_AVC       0xb
#define VE_ISP_INPUT_SIZE   0xa00
#define VE_ISP_INPUT_STRIDE 0xa04
#define VE_ISP_CTRL         0xa08
#define VE_ISP_INPUT_LUMA   0xa78
#define VE_ISP_INPUT_CHROMA 0xa7c
#define VE_AVC_PARAM        0xb04
#define VE_AVC_QP           0xb08
#define VE_AVC_MOTION_EST   0xb10
#define VE_AVC_CTRL         0xb14
#define VE_AVC_TRIGGER      0xb18
#define VE_AVC_STATUS       0xb1c
#define VE_AVC_BASIC_BITS   0xb20
#define VE_AVC_UNK_BUF      0xb60
#define VE_AVC_VLE_ADDR     0xb80
#define VE_AVC_VLE_END      0xb84
#define VE_AVC_VLE_OFFSET   0xb88
#define VE_AVC_VLE_MAX      0xb8c
#define VE_AVC_VLE_LENGTH   0xb90
#define VE_AVC_REF_LUMA     0xba0
#define VE_AVC_REF_CHROMA   0xba4
#define VE_AVC_REC_LUMA     0xbb0
#define VE_AVC_REC_CHROMA   0xbb4
#define VE_AVC_REF_SLUMA    0xbb8
#define VE_AVC_REC_SLUMA    0xbbc
#define VE_AVC_MB_INFO      0xbc0

#define ALIGN(x,a) (((x)+((typeof(x))(a)-1))&~((typeof(x))(a)-1))
#define IS_ALIGNED(x,a) (((x)&((typeof(x))(a)-1))==0)
#define DIV_ROUND_UP(n,d) (((n)+(d)-1)/(d))

static int cedar_fd=-1, ion_fd=-1;
static volatile void *ve_regs;
static int ve_version;

static inline void writel(uint32_t v, volatile void*a){ *(volatile uint32_t*)a = v; }
static inline uint32_t readl(volatile void*a){ return *(volatile uint32_t*)a; }

/* ---- buffer pool (ION + IOMMU) ---- */
struct buf { void*cpu; uint32_t iova; size_t size; int fd; };
static struct buf bufs[64]; static int nbufs=0;

static void *ve_malloc(int size){
	size=(size+4095)&~4095;
	struct ion_allocation_data a; memset(&a,0,sizeof(a));
	a.len=size; a.heap_id_mask=1u<<0; a.flags=0; /* system heap, uncached */
	if(ioctl(ion_fd,ION_IOC_ALLOC,&a)<0){ perror("ION_IOC_ALLOC"); return NULL; }
	void*cpu=mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_SHARED,a.fd,0);
	if(cpu==MAP_FAILED){ perror("mmap buf"); return NULL; }
	struct user_iommu_param p; memset(&p,0,sizeof(p)); p.fd=a.fd;
	if(ioctl(cedar_fd,IOCTL_GET_IOMMU_ADDR,&p)<0){ perror("GET_IOMMU_ADDR"); return NULL; }
	bufs[nbufs]=(struct buf){cpu,p.iommu_addr,size,a.fd}; nbufs++;
	memset(cpu,0,size);
	return cpu;
}
static uint32_t ve_virt2phys(void*ptr){
	for(int i=0;i<nbufs;i++)
		if(ptr>=bufs[i].cpu && (uint8_t*)ptr<(uint8_t*)bufs[i].cpu+bufs[i].size)
			return bufs[i].iova + ((uint8_t*)ptr-(uint8_t*)bufs[i].cpu);
	return 0;
}
static void ve_flush_cache(void*ptr,int len){
	(void)len;
	for(int i=0;i<nbufs;i++) if(ptr>=bufs[i].cpu && (uint8_t*)ptr<(uint8_t*)bufs[i].cpu+bufs[i].size){
		struct dma_buf_sync s={ DMA_BUF_SYNC_END|DMA_BUF_SYNC_RW };
		ioctl(bufs[i].fd,DMA_BUF_IOCTL_SYNC,&s);
		return;
	}
}

static void *ve_get(int engine,uint32_t flags){
	uint32_t ctrl;
	char*e=getenv("VECTRL");
	if(e) ctrl=strtoul(e,0,16);
	else  ctrl=0x00130000 | (engine&0xf) | (flags&~0xf);
	writel(ctrl, ve_regs+VE_CTRL);
	return (void*)ve_regs;
}
static void ve_put(void){ writel(0x00130007, ve_regs+VE_CTRL); }

static int ve_open(void){
	cedar_fd=open("/dev/cedar_dev",O_RDWR);
	if(cedar_fd<0){ perror("open /dev/cedar_dev"); return 0; }
	ion_fd=open("/dev/ion",O_RDWR);
	if(ion_fd<0){ perror("open /dev/ion"); return 0; }
	uint32_t info[8]={0};
	ioctl(cedar_fd,IOCTL_GET_ENV_INFO,info);
	ve_regs=mmap(NULL,0x1000,PROT_READ|PROT_WRITE,MAP_SHARED,cedar_fd,0);
	if(ve_regs==MAP_FAILED){ perror("mmap regs"); return 0; }
	int freq=getenv("VEFREQ")?atoi(getenv("VEFREQ")):402;
	ioctl(cedar_fd,IOCTL_ENGINE_REQ,0);
	ioctl(cedar_fd,IOCTL_ENABLE_VE,0);
	ioctl(cedar_fd,IOCTL_SET_VE_FREQ,freq);
	ioctl(cedar_fd,IOCTL_RESET_VE,0);
	writel(0x00130007, ve_regs+VE_CTRL);
	ve_version=readl(ve_regs+VE_VERSION)>>16;
	printf("[t113enc] VE ver 0x%04x, freq %dMHz, regs %p\n",ve_version,freq,ve_regs);
	return 1;
}
static void ve_close(void){
	ioctl(cedar_fd,IOCTL_DISABLE_VE,0);
	ioctl(cedar_fd,IOCTL_ENGINE_REL,0);
	munmap((void*)ve_regs,0x1000);
	close(cedar_fd); close(ion_fd);
}

/* =================== encoder (ported verbatim from jemk) =================== */
typedef struct h264enc_internal {
	unsigned mb_width,mb_height,mb_stride,crop_right,crop_bottom;
	uint8_t *luma_buffer,*chroma_buffer; unsigned input_buffer_size; int input_color_format;
	uint8_t *bytestream_buffer; unsigned bytestream_buffer_size,bytestream_length;
	struct { void*luma_buffer,*chroma_buffer,*extra_buffer; } ref_picture[2];
	void *extra_buffer_line,*extra_buffer_frame,*regs;
	unsigned write_sps_pps,profile_idc,level_idc,constraints,entropy_coding_mode_flag,pic_init_qp,keyframe_interval,current_frame_num;
	int current_slice_type;
} h264enc;
#define SLICE_P 0
#define SLICE_I 2
enum { H264_FMT_NV12=0, H264_FMT_NV16=1 };

static void put_bits(void*regs,uint32_t x,int num){
	writel(x,regs+VE_AVC_BASIC_BITS);
	writel(0x1|((num&0x1f)<<8),regs+VE_AVC_TRIGGER);
}
static void put_ue(void*regs,uint32_t x){ x++; put_bits(regs,x,(32-__builtin_clz(x))*2-1); }
static void put_se(void*regs,int x){ x=2*x-1; x^=(x>>31); put_ue(regs,x); }
static void put_start_code(void*regs,unsigned nal_ref_idc,unsigned nal_unit_type){
	uint32_t tmp=readl(regs+VE_AVC_PARAM);
	writel(tmp|(0x1<<31),regs+VE_AVC_PARAM);
	put_bits(regs,0,24);
	put_bits(regs,0x100|(nal_ref_idc<<5)|(nal_unit_type<<0),16);
	writel(tmp,regs+VE_AVC_PARAM);
}
static void put_rbsp_trailing_bits(void*regs){
	unsigned cur=readl(regs+VE_AVC_VLE_LENGTH);
	int n=8-((cur+1)&0x7);
	put_bits(regs,1<<n,n+1);
}
static void put_seq_parameter_set(h264enc*c){
	put_start_code(c->regs,3,7);
	put_bits(c->regs,c->profile_idc,8);
	put_bits(c->regs,c->constraints,8);
	put_bits(c->regs,c->level_idc,8);
	put_ue(c->regs,0);
	put_ue(c->regs,0); put_ue(c->regs,2);
	put_ue(c->regs,1); put_bits(c->regs,0,1);
	put_ue(c->regs,c->mb_width-1); put_ue(c->regs,c->mb_height-1);
	put_bits(c->regs,1,1); put_bits(c->regs,0,1);
	unsigned fc=c->crop_right||c->crop_bottom;
	put_bits(c->regs,fc,1);
	if(fc){ put_ue(c->regs,0); put_ue(c->regs,c->crop_right); put_ue(c->regs,0); put_ue(c->regs,c->crop_bottom); }
	put_bits(c->regs,0,1);
	put_rbsp_trailing_bits(c->regs);
}
static void put_pic_parameter_set(h264enc*c){
	put_start_code(c->regs,3,8);
	put_ue(c->regs,0); put_ue(c->regs,0);
	put_bits(c->regs,c->entropy_coding_mode_flag,1);
	put_bits(c->regs,0,1); put_ue(c->regs,0);
	put_ue(c->regs,0); put_ue(c->regs,0);
	put_bits(c->regs,0,1); put_bits(c->regs,0,2);
	put_se(c->regs,(int)c->pic_init_qp-26);
	put_se(c->regs,(int)c->pic_init_qp-26);
	put_se(c->regs,4);
	put_bits(c->regs,1,1); put_bits(c->regs,0,1); put_bits(c->regs,0,1);
	put_rbsp_trailing_bits(c->regs);
}
static void put_slice_header(h264enc*c){
	if(c->current_slice_type==SLICE_I) put_start_code(c->regs,3,5);
	else put_start_code(c->regs,2,1);
	put_ue(c->regs,0); put_ue(c->regs,c->current_slice_type); put_ue(c->regs,0);
	put_bits(c->regs,c->current_frame_num&0xf,4);
	if(c->current_slice_type==SLICE_I) put_ue(c->regs,0);
	if(c->current_slice_type==SLICE_P){
		put_bits(c->regs,0,1); put_bits(c->regs,0,1); put_bits(c->regs,0,1);
		if(c->entropy_coding_mode_flag) put_ue(c->regs,0);
	}
	if(c->current_slice_type==SLICE_I){ put_bits(c->regs,0,1); put_bits(c->regs,0,1); }
	put_se(c->regs,0);
	put_ue(c->regs,0); put_se(c->regs,0); put_se(c->regs,0);
}

static h264enc *h264enc_new(unsigned w,unsigned h,unsigned qp,int cabac){
	h264enc*c=calloc(1,sizeof(*c));
	c->mb_width=DIV_ROUND_UP(w,16); c->mb_height=DIV_ROUND_UP(h,16); c->mb_stride=w/16;
	c->crop_right=(c->mb_width*16-w)/2; c->crop_bottom=(c->mb_height*16-h)/2;
	c->profile_idc=cabac?77:66; c->level_idc=41; c->constraints=cabac?0:0;
	c->entropy_coding_mode_flag=cabac?1:0; c->pic_init_qp=qp; c->keyframe_interval=30;
	c->write_sps_pps=1; c->current_frame_num=0; c->input_color_format=H264_FMT_NV12;
	c->input_buffer_size=w*(h+h/2);
	c->luma_buffer=ve_malloc(c->input_buffer_size); if(!c->luma_buffer) return NULL;
	c->chroma_buffer=c->luma_buffer+w*h;
	c->bytestream_buffer_size=1*1024*1024;
	c->bytestream_buffer=ve_malloc(c->bytestream_buffer_size); if(!c->bytestream_buffer) return NULL;
	unsigned luma_size=ALIGN(c->mb_width*16,32)*ALIGN(c->mb_height*16,32);
	unsigned chroma_size=ALIGN(c->mb_width*16,32)*ALIGN(c->mb_height*8,32);
	for(int i=0;i<2;i++){
		c->ref_picture[i].luma_buffer=ve_malloc(luma_size+chroma_size);
		c->ref_picture[i].chroma_buffer=(uint8_t*)c->ref_picture[i].luma_buffer+luma_size;
		c->ref_picture[i].extra_buffer=ve_malloc(luma_size/4);
		if(!c->ref_picture[i].luma_buffer||!c->ref_picture[i].extra_buffer) return NULL;
	}
	c->extra_buffer_frame=ve_malloc(ALIGN(c->mb_width,4)*c->mb_height*8);
	c->extra_buffer_line=ve_malloc(c->mb_width*32);
	if(!c->extra_buffer_frame||!c->extra_buffer_line) return NULL;
	return c;
}

static int h264enc_encode_picture(h264enc*c){
	c->current_slice_type = c->current_frame_num ? SLICE_P : SLICE_I;
	if(getenv("RST")){ ioctl(cedar_fd,IOCTL_RESET_VE,0); writel(0x00130007,ve_regs+VE_CTRL); }
	c->regs=ve_get(VE_ENGINE_AVC,0);

	ve_flush_cache(c->bytestream_buffer,c->bytestream_buffer_size);
	ve_flush_cache(c->luma_buffer,c->input_buffer_size);

	writel(0x0,c->regs+VE_AVC_VLE_OFFSET);
	writel(ve_virt2phys(c->bytestream_buffer),c->regs+VE_AVC_VLE_ADDR);
	writel(ve_virt2phys(c->bytestream_buffer)+c->bytestream_buffer_size-1,c->regs+VE_AVC_VLE_END);
	writel(c->bytestream_buffer_size*8,c->regs+VE_AVC_VLE_MAX);

	if(c->write_sps_pps){ put_seq_parameter_set(c); put_pic_parameter_set(c); c->write_sps_pps=0; }
	put_slice_header(c);

	/* T113 (VE 0x1667) ISP encoding — recovered from the vendor lib's registers:
	 * a00=(W/8)<<16|(H/8), a14=mb_width, a2c=(H/8)<<16|(W/8) (jemk's A20 layout differs) */
	unsigned PW=c->mb_width*16, PH=c->mb_height*16;
	if(getenv("VENDOR")){
		writel((PW/8)<<16|(PH/8), c->regs+VE_ISP_INPUT_SIZE);   /* a00 */
		writel(c->mb_width<<16,   c->regs+VE_ISP_INPUT_STRIDE); /* a04 */
		writel(c->mb_width,       c->regs+0xa14);
		writel((PH/8)<<16|(PW/8), c->regs+0xa2c);
		writel(c->input_color_format<<29, c->regs+VE_ISP_CTRL);
		writel(ve_virt2phys(c->luma_buffer),   c->regs+VE_ISP_INPUT_LUMA);
		writel(ve_virt2phys(c->chroma_buffer), c->regs+VE_ISP_INPUT_CHROMA);
		writel(ve_virt2phys(c->chroma_buffer), c->regs+0xa80);
		writel((PW/8)<<16|(PH/8), c->regs+0xb00);
	}else{
		writel(c->mb_stride<<16,c->regs+VE_ISP_INPUT_STRIDE);
		writel((c->mb_width<<16)|(c->mb_height<<0),c->regs+VE_ISP_INPUT_SIZE);
		writel(c->input_color_format<<29,c->regs+VE_ISP_CTRL);
		writel(ve_virt2phys(c->luma_buffer),c->regs+VE_ISP_INPUT_LUMA);
		writel(ve_virt2phys(c->chroma_buffer),c->regs+VE_ISP_INPUT_CHROMA);
	}

	unsigned ri=c->current_frame_num%2;
	writel(ve_virt2phys(c->ref_picture[ri].luma_buffer),c->regs+VE_AVC_REC_LUMA);
	writel(ve_virt2phys(c->ref_picture[ri].chroma_buffer),c->regs+VE_AVC_REC_CHROMA);
	writel(ve_virt2phys(c->ref_picture[ri].extra_buffer),c->regs+VE_AVC_REC_SLUMA);
	if(c->current_slice_type!=SLICE_I){
		ri=(c->current_frame_num+1)%2;
		writel(ve_virt2phys(c->ref_picture[ri].luma_buffer),c->regs+VE_AVC_REF_LUMA);
		writel(ve_virt2phys(c->ref_picture[ri].chroma_buffer),c->regs+VE_AVC_REF_CHROMA);
		writel(ve_virt2phys(c->ref_picture[ri].extra_buffer),c->regs+VE_AVC_REF_SLUMA);
	}
	writel(ve_virt2phys(c->extra_buffer_line),c->regs+VE_AVC_MB_INFO);
	writel(ve_virt2phys(c->extra_buffer_frame),c->regs+VE_AVC_UNK_BUF);

	writel(readl(c->regs+VE_AVC_CTRL)|0xf,c->regs+VE_AVC_CTRL);
	writel(readl(c->regs+VE_AVC_STATUS)|0x7,c->regs+VE_AVC_STATUS);

	uint32_t params=0x0;
	if(c->entropy_coding_mode_flag) params|=0x100;
	if(c->current_slice_type==SLICE_P) params|=0x10;
	writel(params,c->regs+VE_AVC_PARAM);
	writel((4<<16)|(c->pic_init_qp<<8)|c->pic_init_qp,c->regs+VE_AVC_QP);
	writel(0x00000104,c->regs+VE_AVC_MOTION_EST);

	/* experimental: write a valid rec-buffer IOVA to a scanned offset (find rec reg) */
	char*so=getenv("SCANOFF");
	if(so){ unsigned off=strtoul(so,0,16); writel(ve_virt2phys(c->ref_picture[0].luma_buffer),c->regs+off); }

	/* trigger + POLL status (no IRQ on this unit) */
	uint32_t trig=getenv("TRIG")?strtoul(getenv("TRIG"),0,16):0x8;
	unsigned trigreg=getenv("TRIGREG")?strtoul(getenv("TRIGREG"),0,16):VE_AVC_TRIGGER;
	writel(trig,c->regs+trigreg);
	int pollms=getenv("POLLMS")?atoi(getenv("POLLMS")):2000;
	uint32_t status=0; int done=0;
	struct timespec t0,t1; clock_gettime(CLOCK_MONOTONIC,&t0);
	for(;;){
		status=readl(c->regs+VE_AVC_STATUS);
		if(status&0x3){ done=1; break; }
		clock_gettime(CLOCK_MONOTONIC,&t1);
		long ms=(t1.tv_sec-t0.tv_sec)*1000+(t1.tv_nsec-t0.tv_nsec)/1000000;
		if(ms>pollms) break;
	}
	uint32_t vle_len=readl(c->regs+VE_AVC_VLE_LENGTH);
	if(getenv("DUMP")){
		fprintf(stderr,"  VE_CTRL=%08x\n",readl(ve_regs+VE_CTRL));
		fprintf(stderr,"  ISP size=%08x stride=%08x ctrl=%08x luma=%08x chroma=%08x\n",
			readl(c->regs+VE_ISP_INPUT_SIZE),readl(c->regs+VE_ISP_INPUT_STRIDE),readl(c->regs+VE_ISP_CTRL),
			readl(c->regs+VE_ISP_INPUT_LUMA),readl(c->regs+VE_ISP_INPUT_CHROMA));
		fprintf(stderr,"  AVC param=%08x qp=%08x mest=%08x ctrl=%08x trig=%08x sts=%08x\n",
			readl(c->regs+VE_AVC_PARAM),readl(c->regs+VE_AVC_QP),readl(c->regs+VE_AVC_MOTION_EST),
			readl(c->regs+VE_AVC_CTRL),readl(c->regs+VE_AVC_TRIGGER),readl(c->regs+VE_AVC_STATUS));
		fprintf(stderr,"  AVC rec_l=%08x ref_l=%08x mbinfo=%08x unkbuf=%08x vle_addr=%08x vle_len=%08x\n",
			readl(c->regs+VE_AVC_REC_LUMA),readl(c->regs+VE_AVC_REF_LUMA),readl(c->regs+VE_AVC_MB_INFO),
			readl(c->regs+VE_AVC_UNK_BUF),readl(c->regs+VE_AVC_VLE_ADDR),readl(c->regs+VE_AVC_VLE_LENGTH));
		fprintf(stderr,"  nonzero 0xa00-0xc00:");
		for(int o=0xa00;o<0xc00;o+=4){uint32_t v=readl(ve_regs+o); if(v)fprintf(stderr," %03x=%08x",o,v);}
		fprintf(stderr,"\n");
	}
	writel(status,c->regs+VE_AVC_STATUS);
	c->bytestream_length=vle_len/8;
	fprintf(stderr,"[frame %u type=%d] status=0x%08x done=%d vle_len_bits=%u bytes=%u\n",
		c->current_frame_num,c->current_slice_type,status,done,vle_len,c->bytestream_length);

	c->current_frame_num++;
	if(c->current_frame_num>=c->keyframe_interval) c->current_frame_num=0;
	ve_put();
	return (status&0x3)==0x1;
}

int main(int argc,char**argv){
	if(argc<6){ fprintf(stderr,"usage: %s in.nv12 out.h264 W H Nframes [qp] [cabac]\n",argv[0]); return 2; }
	const char*inf=argv[1],*outf=argv[2];
	unsigned W=atoi(argv[3]),H=atoi(argv[4]),N=atoi(argv[5]);
	unsigned qp=argc>6?atoi(argv[6]):26; int cabac=argc>7?atoi(argv[7]):0;
	if(!ve_open()){ fprintf(stderr,"ve_open failed\n"); return 1; }
	h264enc*c=h264enc_new(W,H,qp,cabac);
	if(!c){ fprintf(stderr,"h264enc_new failed\n"); return 1; }
	if(getenv("DUMP")){ for(int i=0;i<nbufs;i++) fprintf(stderr,"  buf[%d] cpu=%p iova=0x%08x size=%zu\n",i,bufs[i].cpu,bufs[i].iova,bufs[i].size); }
	FILE*fi=fopen(inf,"rb"),*fo=fopen(outf,"wb");
	if(!fi||!fo){ perror("fopen"); return 1; }
	unsigned fsz=W*H*3/2, ok=0;
	for(unsigned f=0;f<N;f++){
		if(fread(c->luma_buffer,1,fsz,fi)!=fsz){ fprintf(stderr,"input exhausted at %u\n",f); break; }
		int r=h264enc_encode_picture(c);
		if(r && c->bytestream_length>0){ fwrite(c->bytestream_buffer,1,c->bytestream_length,fo); ok++; }
	}
	fclose(fi); fclose(fo);
	printf("[t113enc] %u/%u frames encoded OK -> %s\n",ok,N,outf);
	ve_close();
	return ok>0?0:1;
}
