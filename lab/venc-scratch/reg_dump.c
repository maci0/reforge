/* passive VE register dumper: mmap /dev/cedar_dev regs, print all nonzero
 * 0x000-0xfff. NO ioctls (won't disturb a concurrent encoder's state). */
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/mman.h>
int main(void){
  int fd=open("/dev/cedar_dev",O_RDWR); if(fd<0)return 1;
  volatile uint8_t*r=mmap(0,0x1000,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
  if(r==MAP_FAILED)return 1;
  for(int o=0;o<0x1000;o+=4){uint32_t v=*(volatile uint32_t*)(r+o); if(v)printf("%03x=%08x ",o,v);}
  printf("\n");
  return 0;
}
