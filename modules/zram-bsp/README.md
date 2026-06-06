# zram loadable modules for the stock 5.4.61 BSP kernel

**Goal:** build `zram.ko` + `zsmalloc.ko` (+ `zpool.ko`/`zbud.ko`) as loadable modules
that `insmod` cleanly on the **stock FlashForge AD5M 5.4.61 kernel**, giving
**compressed-RAM swap (zram + zstd)** without replacing the kernel.

**Why it matters:** ReForge's early phases (P1–P3) ride the stock kernel, so these
modules give compressed swap *there* too — not only in P4 (our own kernel). They are
also testable on the current **forge-x** install immediately. The stock kernel ships
`CONFIG_CRYPTO_ZSTD=y` (compressor present) but `CONFIG_ZSMALLOC`/`ZRAM`/`ZPOOL`/`ZBUD`
are all unset — so the drivers must come as out-of-tree modules.

## Measured (live AD5M, dual Cortex-A7, 128 MB)
Before: 64 MB **eMMC swapfile**, uncompressed (1.0×), flash wear, slow.
After: 256 MB **zram zstd** primary + eMMC overflow — ~36 MB cold pages → ~9 MB RAM.

| algo | ratio (real heap) | ratio (code) | compress\* | decompress\* | A7 CPU |
|---|---|---|---|---|---|
| eMMC swapfile | 1.0× | 1.0× | flash-bound | flash-bound | — (wear) |
| **zstd** *(default)* | **4.02–4.18×** | 3.54× | ~6.3 MB/s | ~37.5 MB/s | moderate |
| lzo-rle | — | 2.74× | ~7.4 MB/s | ~30 MB/s | low |
| lzo | — | 2.74× | ~8.6–9.6 MB/s | ~82.8 MB/s | lowest |

\* block-I/O-bound (timed `dd` through the zram block dev) → **relative**, not absolute.
Full method + before/after in `../../docs/research/memory/2026-05-31-memory-and-testing.md` §0b.
lz4 unavailable (stock kernel lacks `CONFIG_CRYPTO_LZ4`). Default **zstd**; `lzo-rle`
is the low-CPU escape hatch (`ZRAM_ALGO=lzo-rle`).

## Hard constraints (from the running stock kernel)
- **Target vermagic (must match exactly):** `5.4.61 SMP preempt mod_unload ARMv7 p2v8`
  (read from the stock `8821cu.ko`).
- `CONFIG_MODULES=y`, **no `MODULE_SIG`**, **no `MODVERSIONS`** → insmod checks only the
  vermagic string + resolves symbols against the running kernel's ksymtab (no per-symbol CRC).
- ABI configs to match: `CONFIG_SMP=y`, `CONFIG_PREEMPT=y`, `CONFIG_ARM_PATCH_PHYS_VIRT=y`
  (the `p2v8`), `CONFIG_AEABI=y`, `CONFIG_MODULE_UNLOAD=y`, `CONFIG_LOCALVERSION=""`,
  **not** `THUMB2_KERNEL` (ARM mode → `ARMv7`, not `ARMv7 thumb2`).
- Compiler is **not** in the vermagic (5.4 dropped it) → any ABI-compatible cross-GCC works;
  using GCC ~9 (kernel.org crosstool) for clean 5.4 builds (local GCC 14 is too new).

## Build inputs
- Kernel source: the **Tina sun8iw20 BSP** submodule `vendor/kernels/tina-bsp-kernel`
  (pinned in `pins.lock`). This is the layout-exact default — upstream mainline `linux-5.4.61`
  was tried first and **Oopsed** (see RESULT below), so the BSP is what `build.sh` uses.
- Config: the **captured stock `.config`** (`../../docs/board-notes/stock-kernel-config-5.4.61.txt.gz`)
  with `CONFIG_ZSMALLOC=m`, `CONFIG_ZRAM=m`, `CONFIG_ZPOOL=m`, `CONFIG_ZBUD=m` added.
- Toolchain: kernel.org crosstool `arm-linux-gnueabi` GCC 9.5 at
  `vendor/toolchains/gcc-9.5.0-nolibc` (fetched + verified by `vendor/fetch.sh`; kernel
  builds soft-float regardless of hf/non-hf prefix).

## Build steps (see build.sh once written)
1. Extract source + toolchain.
2. `zcat stock .config > .config`; enable the 4 module symbols; `make ARCH=arm CROSS_COMPILE=... olddefconfig`.
3. `make ARCH=arm CROSS_COMPILE=... modules_prepare`.
4. Build targeted: `make ARCH=arm CROSS_COMPILE=... mm/zsmalloc.ko drivers/block/zram/zram.ko mm/zpool.ko mm/zbud.ko`.
5. Verify: `arm-linux-gnueabi-objdump`/`modinfo` → vermagic == target.

## Test (forge-x, reversible)
1. scp the `.ko`s to the printer.
2. `insmod zsmalloc.ko && insmod zpool.ko && insmod zbud.ko && insmod zram.ko` (order: deps first).
   - If `Unknown symbol` → the running kernel doesn't export something these need → fall
     back to the **vendor Tina sun8iw20 5.4 source** (struct/layout-exact) and rebuild.
   - If `version magic ... should be ...` → vermagic mismatch → fix VERSION/config and rebuild.
3. Set up zram swap:
   ```
   modprobe-style: zramctl /dev/zram0 --algorithm zstd --size 128M  (or echo to sysfs on busybox)
   mkswap /dev/zram0 ; swapon -p 100 /dev/zram0   # higher prio than the eMMC swapfile
   ```
4. Measure: `free -m`, `cat /sys/block/zram0/{orig_data_size,compr_data_size,mem_used_total}`,
   compare effective swap headroom vs the uncompressed eMMC swapfile.
5. Revert: `swapoff /dev/zram0 ; rmmod zram zbud zpool zsmalloc` (or reboot).

## RESULT (2026-05-31): ✅ WORKS with vendor BSP source — 4.02× compression

**Final outcome:** zram + zstd compressed swap is **working on the stock 5.4.61 kernel.**
Modules built from the **Allwinner T113 vendor BSP** source (`iLotusK9/linux_kernel_aw_t113`,
branch `5.4.61` — sun8iw20p1, same BSP base as FlashForge) load cleanly; on the live
unit, real klippy/moonraker cold pages compress **4.02×** (orig 3.8MB → 0.9MB stored).
Deployables in `dist/` (`zsmalloc.ko`, `zram.ko`); bring-up via `zram-setup.sh`, revert
via `zram-teardown.sh`. Applies to **forge-x AND ReForge P1–P3** (both ride the stock kernel).

Two gotchas solved along the way:
1. **Upstream `linux-5.4.61` source → Oops** (vendor `struct page` layout differs). Use vendor BSP source.
2. **`5.4.61+` vermagic** (trailing `+` from a dirty git tree) → suppress with an empty `.scmversion`; final vermagic is exactly `5.4.61 SMP preempt mod_unload ARMv7 p2v8`.

Deploy steps: `scp dist/*.ko` (or `cat`-over-ssh — device has no sftp-server) to the
printer, run `zram-setup.sh`. Note busybox `insmod`/`mkswap`/`swapon` live at `/sbin/`
and busybox `swapon` has **no `-p`** (priority handled by swapoff/re-add order instead).

### Upstream attempt (kept as the negative result)

Built all 4 modules from **upstream linux-5.4.61** + the stock `.config` with GCC 9.5.
**Vermagic matched exactly** (`5.4.61 SMP preempt mod_unload ARMv7 p2v8`). On the live
forge-x unit: `insmod zsmalloc.ko` succeeded, but the next load (`zbud`) caused a
kernel **Oops (data abort, Oops: 5)** — `Modules linked in: zsmalloc 8821cu`. The
printer stayed up (init-context Oops, not a panic) but left a D-state hung `insmod`
and a tainted kernel; recovered with `/sbin/reboot -f` (back clean, taint=1024 = the
normal out-of-tree `8821cu`).

**Conclusion:** vermagic match is necessary but **not sufficient**. The vendor kernel's
`struct page` / mm layout differs from upstream 5.4.61 (Allwinner BSP patches), and
zsmalloc/zbud store metadata in `struct page` fields → memory corruption on load.
**Must rebuild from the Tina SDK sun8iw20 5.4 BSP source** (layout-exact). The upstream
attempt is kept here only as the documented negative result; do not deploy it.

**Next step:** acquire the Tina sun8iw20 5.4 kernel source (`DongshanPI/100ASK_T113-Pro_TinaSDK`
or Allwinner longan), configure with the stock `.config` + the 4 module symbols, build
with a compatible toolchain, and re-test insmod. Expectation: layout-exact modules load.

## Fallback if upstream source modules won't load (now the PRIMARY path — see RESULT)
Vendor patches *could* alter a struct `zsmalloc` relies on (it stores metadata in
`struct page` fields). If upstream-built modules fail to load or misbehave, rebuild
from the **Tina SDK sun8iw20 5.4 BSP kernel source** (`DongshanPI/100ASK_T113-Pro_TinaSDK`),
which is layout-exact to the stock kernel. See `../../docs/research/memory/2026-05-31-memory-and-testing.md` §4.
</content>
