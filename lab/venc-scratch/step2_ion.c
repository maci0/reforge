/* step2: T113 contiguous buffer for the VE = ION alloc -> dma-buf fd ->
 * cedar IOCTL_GET_IOMMU_ADDR -> VE IOVA. Mirrors what the closed lib does. */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <linux/types.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

/* modern ION uABI (kernel 5.4) */
struct ion_allocation_data { __u64 len; __u32 heap_id_mask; __u32 flags; __u32 fd; __u32 unused; };
struct ion_heap_data { char name[32]; __u32 type; __u32 heap_id; __u32 r0,r1,r2; };
struct ion_heap_query { __u32 cnt; __u32 r0; __u64 heaps; __u32 r1,r2; };
#define ION_IOC_ALLOC      _IOWR('I',0,struct ion_allocation_data)
#define ION_IOC_HEAP_QUERY _IOWR('I',8,struct ion_heap_query)

/* cedar */
#define IOCTL_GET_IOMMU_ADDR 0x502
struct user_iommu_param { int fd; unsigned int iommu_addr; };

int main(void){
  int ion=open("/dev/ion",O_RDWR);
  if(ion<0){perror("open ion");return 1;}
  struct ion_heap_data heaps[16]; memset(heaps,0,sizeof(heaps));
  struct ion_heap_query q; memset(&q,0,sizeof(q));
  q.cnt=16; q.heaps=(uint64_t)(uintptr_t)heaps;
  if(ioctl(ion,ION_IOC_HEAP_QUERY,&q)<0){perror("HEAP_QUERY");}
  printf("ion heaps: %u\n",q.cnt);
  for(unsigned i=0;i<q.cnt;i++) printf("  [%u] name=%-20s type=%u id=%u\n",i,heaps[i].name,heaps[i].type,heaps[i].heap_id);

  /* alloc from each heap, try iommu map */
  int cedar=open("/dev/cedar_dev",O_RDWR);
  for(unsigned i=0;i<q.cnt;i++){
    struct ion_allocation_data a; memset(&a,0,sizeof(a));
    a.len=640*480*3/2; a.heap_id_mask=1u<<heaps[i].heap_id; a.flags=0;
    if(ioctl(ion,ION_IOC_ALLOC,&a)<0){ printf("  heap %u (%s): ALLOC fail\n",heaps[i].heap_id,heaps[i].name); continue; }
    void*v=mmap(NULL,a.len,PROT_READ|PROT_WRITE,MAP_SHARED,a.fd,0);
    struct user_iommu_param p; memset(&p,0,sizeof(p)); p.fd=a.fd;
    int r=ioctl(cedar,IOCTL_GET_IOMMU_ADDR,&p);
    printf("  heap %u (%s): ALLOC ok fd=%d cpu=%p  GET_IOMMU_ADDR=%d iova=0x%08x\n",
           heaps[i].heap_id,heaps[i].name,a.fd,v,r,p.iommu_addr);
    if(v!=MAP_FAILED) munmap(v,a.len);
    close(a.fd);
  }
  return 0;
}
