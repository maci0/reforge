/* dump the VE encoder internal SRAM via the port (enc base 0xb00 + 0xe0=offset,0xe4=data).
 * arg = number of words to read. Reads current SRAM state (no ioctls that disturb). */
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mman.h>
int main(int argc,char**argv){
  int n=argc>1?atoi(argv[1]):64;
  int fd=open("/dev/cedar_dev",O_RDWR); if(fd<0)return 1;
  volatile uint8_t*r=mmap(0,0x1000,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
  if(r==MAP_FAILED)return 1;
  volatile uint32_t*off=(volatile uint32_t*)(r+0xbe0);
  volatile uint32_t*dat=(volatile uint32_t*)(r+0xbe4);
  int nz=0;
  for(int i=0;i<n;i++){ *off=i; uint32_t v=*dat; if(v){nz++; if(i<32||v) printf("sram[%d]=%08x ",i,v);} }
  printf("\n(%d/%d nonzero)\n",nz,n);
  return 0;
}
