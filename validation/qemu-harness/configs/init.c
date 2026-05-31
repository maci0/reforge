/*
 * ReForge qemu-virt fb probe init
 * Minimal static init using Linux syscalls directly via nolibc.
 * Compiled with: arm-linux-gnueabi-gcc -static -nostdlib -Os
 *                -include nolibc.h (from kernel tools/include/nolibc)
 *
 * Mounts proc/sysfs/devtmpfs, reads /sys/class/graphics/fb0 geometry,
 * prints it, then halts.
 */

/* Pull in just the nolibc syscall wrappers (single-include, no linux/ hdrs) */
#define _NOLIBC_STDINT_H    /* suppress */

/* Inline syscalls for ARM EABI */
static long sys_mount(const char *src, const char *tgt, const char *type,
                      unsigned long flags, const void *data)
{
    register long r0 __asm__("r0") = (long)src;
    register long r1 __asm__("r1") = (long)tgt;
    register long r2 __asm__("r2") = (long)type;
    register long r3 __asm__("r3") = (long)flags;
    register long r4 __asm__("r4") = (long)data;
    register long r7 __asm__("r7") = 21; /* __NR_mount */
    __asm__ __volatile__("swi 0" : "+r"(r0) : "r"(r1),"r"(r2),"r"(r3),"r"(r4),"r"(r7) : "memory");
    return r0;
}

static long sys_write(int fd, const void *buf, long len)
{
    register long r0 __asm__("r0") = fd;
    register long r1 __asm__("r1") = (long)buf;
    register long r2 __asm__("r2") = len;
    register long r7 __asm__("r7") = 4; /* __NR_write */
    __asm__ __volatile__("swi 0" : "+r"(r0) : "r"(r1),"r"(r2),"r"(r7) : "memory");
    return r0;
}

static long sys_open(const char *path, int flags)
{
    register long r0 __asm__("r0") = (long)path;
    register long r1 __asm__("r1") = flags;
    register long r2 __asm__("r2") = 0;
    register long r7 __asm__("r7") = 5; /* __NR_open */
    __asm__ __volatile__("swi 0" : "+r"(r0) : "r"(r1),"r"(r2),"r"(r7) : "memory");
    return r0;
}

static long sys_read(int fd, void *buf, long len)
{
    register long r0 __asm__("r0") = fd;
    register long r1 __asm__("r1") = (long)buf;
    register long r2 __asm__("r2") = len;
    register long r7 __asm__("r7") = 3; /* __NR_read */
    __asm__ __volatile__("swi 0" : "+r"(r0) : "r"(r1),"r"(r2),"r"(r7) : "memory");
    return r0;
}

static long sys_close(int fd)
{
    register long r0 __asm__("r0") = fd;
    register long r7 __asm__("r7") = 6; /* __NR_close */
    __asm__ __volatile__("swi 0" : "+r"(r0) : "r"(r7) : "memory");
    return r0;
}

static long sys_nanosleep(long sec)
{
    struct { long tv_sec; long tv_nsec; } ts = { sec, 0 };
    register long r0 __asm__("r0") = (long)&ts;
    register long r1 __asm__("r1") = 0;
    register long r7 __asm__("r7") = 162; /* __NR_nanosleep */
    __asm__ __volatile__("swi 0" : "+r"(r0) : "r"(r1),"r"(r7) : "memory");
    return r0;
}

static long sys_reboot(int magic1, int magic2, int cmd, void *arg)
{
    register long r0 __asm__("r0") = magic1;
    register long r1 __asm__("r1") = magic2;
    register long r2 __asm__("r2") = cmd;
    register long r3 __asm__("r3") = (long)arg;
    register long r7 __asm__("r7") = 88; /* __NR_reboot */
    __asm__ __volatile__("swi 0" : "+r"(r0) : "r"(r1),"r"(r2),"r"(r3),"r"(r7) : "memory");
    return r0;
}

static int my_strlen(const char *s)
{
    int n = 0;
    while (s[n]) n++;
    return n;
}

static void print(const char *s)
{
    sys_write(1, s, my_strlen(s));
}

static void read_sysfs(const char *path, char *buf, int maxlen)
{
    long fd = sys_open(path, 0 /* O_RDONLY */);
    if (fd < 0) { buf[0]='N'; buf[1]='/'; buf[2]='A'; buf[3]='\0'; return; }
    long n = sys_read(fd, buf, maxlen - 1);
    sys_close(fd);
    if (n < 0) n = 0;
    buf[n] = '\0';
    /* strip newline */
    for (int i = 0; i < n; i++) if (buf[i] == '\n') { buf[i] = '\0'; break; }
}

void _start(void)
{
    sys_mount("proc",     "/proc", "proc",     0, 0);
    sys_mount("sysfs",    "/sys",  "sysfs",    0, 0);
    sys_mount("devtmpfs", "/dev",  "devtmpfs", 0, 0);

    print("\n=== ReForge qemu-virt fb probe ===\n\n");

    sys_nanosleep(1);

    print("--- /sys/class/graphics/fb0 ---\n");

    char vsize[64], bpp[32], name[64];
    read_sysfs("/sys/class/graphics/fb0/virtual_size",   vsize, sizeof(vsize));
    read_sysfs("/sys/class/graphics/fb0/bits_per_pixel", bpp,   sizeof(bpp));
    read_sysfs("/sys/class/graphics/fb0/name",           name,  sizeof(name));

    print("virtual_size:   "); print(vsize); print("\n");
    print("bits_per_pixel: "); print(bpp);   print("\n");
    print("name:           "); print(name);  print("\n");

    print("\n=== PROBE DONE - halting ===\n");

    /* RB_HALT_SYSTEM = 0xcdef0123, magic1 = 0xfee1dead, magic2 = 672274793 */
    sys_reboot(0xfee1dead, 672274793, 0xcdef0123, 0);

    /* should not reach here */
    while (1) { }
}
