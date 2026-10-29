#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include "standby-state.h"
extern void sunxi_arisc_handler(uint32_t *);
#ifdef TEST_ARISC_ROOT
extern void __tee_entry_fast(uint32_t *);
uint32_t default_nsec_shm_paddr, default_nsec_shm_size;
int core_mmu_nsec_ddr_is_defined(void) { _exit(91); }
unsigned core_mmu_type_to_attr(unsigned type) { (void)type; _exit(91); }
int generic_boot_core_release(unsigned core, uint32_t entry) { (void)core; (void)entry; _exit(91); }
int thread_disable_prealloc_rpc_cache(uint64_t *cookie) { (void)cookie; _exit(91); }
int thread_enable_prealloc_rpc_cache(void) { _exit(91); }
#define dispatch __tee_entry_fast
#else
#define dispatch sunxi_arisc_handler
#endif
extern unsigned standby_host_get_type(void);
static unsigned root_logs, audio_logs, want_root, expected_irq;
static void require(int condition) { if (!condition) _exit(90); }
void trace_printf(const char *name,int line,int level,int prefix,const char *format,...) {
    va_list args;
    require(level==3 && prefix==1);
    if (!strcmp(name,"sunxi_arisc_handler")) {
        require(want_root && line==99 && !strcmp(format,"root_irq:%d\n"));
        va_start(args,format);require(va_arg(args,unsigned)==expected_irq);va_end(args);++root_logs;
    } else {
        require(!strcmp(name,"standby_type") && line==72 && !strcmp(format,"AUDIO_STANDBY\n"));++audio_logs;
    }
}
static void invoke(uint32_t id,uint32_t a,uint32_t b,uint32_t c) {
    uint32_t regs[8]={id,a,b,c,0x12345678,0x23456789,0x34567890,0x45678901}, before[8];
    memcpy(before,regs,sizeof(regs));root_logs=audio_logs=0;want_root=id==0x83000026;expected_irq=a&1023;
    dispatch(regs);
    require(regs[0]==((id==0x83000025 || id==0x83000026 || id==0x83000064)?0u:0xffffffff));
    require(!memcmp(regs+1,before+1,7*4) && root_logs==want_root && audio_logs==0);
}
static void type(unsigned expected) { audio_logs=0;require(standby_host_get_type()==expected && audio_logs==(expected==2)); }
int main(void) {
    const uint32_t enabled[]={0,1,2,0x100,0xffffffff};
    const uint32_t times[]={0,1,0x3fffffff};
    const uint32_t ignored[]={1024,1025,0x3fffffff,0x40000000,0x80000000,0xbfffffff};
    const uint32_t unknown[]={0x83000024,0x83000027,0x83000063,0x83000065,0x84000026,0xffffffff};
    uint32_t bitmap[32];unsigned char settings[16];unsigned irq,i,j;
    for (irq=0;irq<1024;++irq) {
        memset(standby_host_request,0,sizeof(standby_host_request));
        invoke(0x83000026,irq,0,0);
        for (i=0;i<32;++i) require(standby_host_request[i]==(i==irq/32 ? 1u<<(irq%32):0));
        type(irq==35?2:1);
        invoke(0x83000025,irq,0,0);
        for (i=0;i<32;++i) require(standby_host_request[i]==0);
        type(1);
    }
    for (i=0;i<5;++i) {
        memset(&standby_host_settings,0xa5,16);memcpy(settings,&standby_host_settings,16);
        settings[0]=enabled[i]!=0;
        { uint32_t a=0x12345600+i,b=0xabcdef00+i;memcpy(settings+4,&a,4);memcpy(settings+8,&b,4); }
        invoke(0x83000064,enabled[i],0x12345600+i,0xabcdef00+i);
        require(!memcmp(settings,&standby_host_settings,16));
    }
    for (i=0;i<32;++i) standby_host_request[i]=bitmap[i]=0x12340000+i;
    for (i=0;i<3;++i) {
        invoke(0x83000026,0xc0000000|times[i],0,0);require(standby_host_settings.wakeup_ms==times[i]);
        require(!memcmp(bitmap,standby_host_request,sizeof(bitmap)));
        invoke(0x83000025,0xc0000000|times[i],0,0);require(standby_host_settings.wakeup_ms==0);
    }
    for (i=0;i<6;++i) for (j=0;j<2;++j) {
        memcpy(settings,&standby_host_settings,16);invoke(0x83000025+j,ignored[i],0,0);
        require(!memcmp(settings,&standby_host_settings,16) && !memcmp(bitmap,standby_host_request,sizeof(bitmap)));
    }
    for (i=0;i<6;++i) {
        memcpy(settings,&standby_host_settings,16);invoke(unknown[i],17,18,19);
        require(!memcmp(settings,&standby_host_settings,16) && !memcmp(bitmap,standby_host_request,sizeof(bitmap)));
    }
#ifdef TEST_ARISC_ROOT
    { uint32_t regs[8]={0xb200000f,0x12345678,2,3,4,5,6,7};
      __tee_entry_fast(regs);require(regs[0]==0 && regs[1]==4);
      for(i=2;i<8;++i) require(regs[i]==i);
    }
#endif
    return 0;
}
