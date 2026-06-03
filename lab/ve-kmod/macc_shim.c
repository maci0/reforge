/* macc_shim.c — LD_PRELOAD fix for the Cedar VE on the AD5M.
 *
 * The cedar driver's IOCTL_GET_ENV_INFO hardcodes address_macc = 0 (cedar_ve.c:1412), but
 * the VE memory allocator returns DRAM-RELATIVE addresses (e.g. 0x02c00000) while DRAM is at
 * CPU-physical 0x40000000. The lib programs the VE's DRAM-base from address_macc; with 0 the
 * VE accesses 0x02c00000 (below DRAM) and HANGS (busy bit set, done never set, no IRQ -> the
 * "wait interrupt overtime"). Patching address_macc -> 0x40000000 makes the VE reach
 * 0x40000000 + 0x02c00000 = 0x42c00000 (the real buffer). Hardware-confirmed via lab/ve-kmod.
 *
 *   IOCTL_GET_ENV_INFO = 0x101 (enum base 0x100, cedar_ve.h).
 *   struct cedarv_env_infomation_compat { u32 phymem_start; int total; u32 address_macc; }
 *   -> address_macc at byte offset 8.
 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

#define IOCTL_GET_ENV_INFO 0x101
#define DRAM_BASE          0x40000000u

static int (*real_ioctl)(int, unsigned long, ...);

int ioctl(int fd, unsigned long request, ...)
{
	va_list ap;
	void *arg;
	int ret;
	va_start(ap, request);
	arg = va_arg(ap, void *);
	va_end(ap);

	if (!real_ioctl)
		real_ioctl = dlsym(RTLD_NEXT, "ioctl");

	ret = real_ioctl(fd, request, arg);

	if (request == IOCTL_GET_ENV_INFO && arg) {
		uint32_t *macc = (uint32_t *)((char *)arg + 8);
		fprintf(stderr, "[macc_shim] GET_ENV_INFO address_macc 0x%x -> 0x%x\n", *macc, DRAM_BASE);
		*macc = DRAM_BASE;
	}
	return ret;
}
