/* step1: prove userspace VE register mmap on the T113 cedar driver (jemk pattern).
 * T113 ioctl enum (cedar_ve.h): GET_ENV_INFO=0x101 RESET=0x104 ENABLE=0x105
 * SET_FREQ=0x107 ENGINE_REQ=0x206. cedardev_mmap hardcodes MACC_REGS_BASE. */
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#define IOCTL_GET_ENV_INFO 0x101
#define IOCTL_RESET_VE     0x104
#define IOCTL_ENABLE_VE    0x105
#define IOCTL_SET_VE_FREQ  0x107
#define IOCTL_ENGINE_REQ   0x206
#define VE_CTRL    0x000
#define VE_VERSION 0x0f0
static inline uint32_t rl(volatile void*a){return *(volatile uint32_t*)a;}
static inline void wl(uint32_t v,volatile void*a){*(volatile uint32_t*)a=v;}
int main(void){
  int fd=open("/dev/cedar_dev",O_RDWR);
  if(fd<0){perror("open cedar_dev");return 1;}
  uint32_t info[8]={0};
  if(ioctl(fd,IOCTL_GET_ENV_INFO,info)<0)perror("GET_ENV_INFO");
  printf("env: %08x %08x %08x\n",info[0],info[1],info[2]);
  volatile void*regs=mmap(NULL,0x1000,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
  if(regs==MAP_FAILED){perror("mmap regs");return 1;}
  printf("regs mmap OK %p\n",regs);
  ioctl(fd,IOCTL_ENGINE_REQ,0);
  ioctl(fd,IOCTL_ENABLE_VE,0);
  ioctl(fd,IOCTL_SET_VE_FREQ,320);
  ioctl(fd,IOCTL_RESET_VE,0);
  wl(0x00130007,regs+VE_CTRL);
  uint32_t ver=rl(regs+VE_VERSION);
  printf("VE_CTRL=%08x VE_VERSION=%08x (ver=0x%04x)\n",rl(regs+VE_CTRL),ver,ver>>16);
  printf("nonzero regs 0x000-0x100:");
  for(int o=0;o<0x100;o+=4){uint32_t v=rl(regs+o); if(v)printf(" r%03x=%08x",o,v);}
  printf("\n");
  return 0;
}
