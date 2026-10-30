#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdbool.h>
#include "memory-bounds-attributes.h"
extern bool core_pbuf_is(uint32_t,uint32_t,uint32_t);
extern uint32_t default_nsec_shm_paddr,default_nsec_shm_size;
uint32_t tee_mm_sec_ddr[7];
/* Actual buffer helper is linked from the same production build. */
void *scattered_array_relax_ptr(void *p) { (void)p; _exit(91); }
static void check(int v) { if(!v)_exit(90); }
int main(void) {
 for(unsigned k=0;k<8;k++) {
  tee_mm_sec_ddr[1]=0x42000000+k*0x10000;tee_mm_sec_ddr[2]=tee_mm_sec_ddr[1]+0x3000;
  default_nsec_shm_paddr=0x43000000+k*0x10000;default_nsec_shm_size=0x2000;
  for(unsigned j=0;j<0x5000;j+=17) {
   uint32_t p=tee_mm_sec_ddr[1]-0x1000+j;
   check(core_pbuf_is(CORE_MEM_TA_RAM,p,32)==(p>=tee_mm_sec_ddr[1] && p<=tee_mm_sec_ddr[2]-32));
   p=default_nsec_shm_paddr-0x1000+j;
   check(core_pbuf_is(CORE_MEM_NSEC_SHM,p,32)==(p>=default_nsec_shm_paddr && p<=default_nsec_shm_paddr+default_nsec_shm_size-32));
  }
 }
 check(core_pbuf_is(CORE_MEM_TEE_RAM,0x41b7ffff,1));check(!core_pbuf_is(CORE_MEM_TEE_RAM,0x41b80000,1));
 check(core_pbuf_is(99,0,0));check(!core_pbuf_is(99,0,1));return 0;
}
