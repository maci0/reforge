/* map which VE registers 0xa00-0xc00 are writable (hold a written test value) */
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#define VE_CTRL 0
int main(int c,char**v){
  int fd=open("/dev/cedar_dev",O_RDWR);
  ioctl(fd,0x206,0); ioctl(fd,0x105,0); ioctl(fd,0x107,402); ioctl(fd,0x104,0);
  volatile uint8_t*r=mmap(0,0x1000,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
  uint32_t ctrl=c>1?strtoul(v[1],0,16):0xc00200c7;
  *(volatile uint32_t*)(r+VE_CTRL)=ctrl;
  printf("CTRL=%08x writable regs (write 5a5a5a5a):",ctrl);
  for(int o=0xa00;o<0xc00;o+=4){
    volatile uint32_t*p=(volatile uint32_t*)(r+o);
    uint32_t orig=*p; *p=0x5a5a5a5a; uint32_t rb=*p; *p=orig;
    if(rb==0x5a5a5a5a)printf(" %03x",o);
  }
  printf("\n");
  return 0;
}
