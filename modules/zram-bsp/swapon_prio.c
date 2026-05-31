/* swapon a device at an explicit priority (busybox swapon lacks -p). */
#include <sys/swap.h>
#include <stdlib.h>
#include <stdio.h>
int main(int argc, char **argv){
    if(argc<2){ fprintf(stderr,"usage: swapon_prio <dev> [prio]\n"); return 2; }
    int prio = argc>2 ? atoi(argv[2]) : 100;
    if(swapon(argv[1], SWAP_FLAG_PREFER | (prio & SWAP_FLAG_PRIO_MASK))){ perror("swapon"); return 1; }
    printf("swapon %s prio %d OK\n", argv[1], prio);
    return 0;
}
