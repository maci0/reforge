# ve-kmod — Cedar VE diagnostic kernel module + LD_PRELOAD address shim

Read-only diagnostic for the AD5M's Allwinner Cedar VE, built to find why HW H.264 encode
never completes (see `../venc/README.md`).

- `ve_diag.c` — loadable module (`/proc/ve_diag`) that ioremaps the VE regs (0x01C0E000) + GIC
  (0x03021000) and dumps the VE interrupt status/ctrl, MMU regs, encode register bank, and the
  GIC enable/pending/active for the VE IRQ (98). Used live during an encode to prove the VE
  busy bit sets but "done" never does, and that the buffer addresses are below DRAM base.
- `macc_shim.c` — LD_PRELOAD that patches IOCTL_GET_ENV_INFO's address_macc -> 0x40000000
  (did not fix it; the lib doesn't use it for buffer addresses — kept as a documented attempt).
- `prep-kernel.sh` — preps the vendored BSP kernel (stock .config) for out-of-tree module builds.
- `Makefile` — builds against `vendor/kernels/tina-bsp-kernel` with the kernel.org GCC-9.5 cross.

Build: `./prep-kernel.sh` once, then `make`. The vermagic MUST be `5.4.61 SMP preempt
mod_unload ARMv7 p2v8` (empty .scmversion + forced utsrelease "5.4.61", no `+`).
Load: `insmod ve_diag.ko; cat /proc/ve_diag`. Read-only; safe.
