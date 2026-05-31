# Memory optimization & testing — findings and strategies

Date: 2026-05-31. Consolidates the memory-saving investigation (ReForge primary,
forge-x retrofit secondary) and the qemu testing approach. Measurements are from
the live unit (`root@192.168.0.158`, forge-x, idle).

## 0. The one-sentence truth
Transparent memory **compression lives in the kernel** (zram/zswap); userspace
allocators only reduce **fragmentation**. The stock 5.4.61 kernel has **no zram**,
so forge-x is structurally capped — the real wins require ReForge's own kernel.

---

## 1. Baseline (measured, live forge-x, idle)
- MemTotal **108 MB** (128 MB SoC minus CMA/DSP/reserved). MemFree ~17–27 MB, MemAvailable ~43 MB.
- **Swap = a 64 MB eMMC swapfile** (`/data/.mod/.forge-x/root/swap`), ~30 MB in use — *uncompressed, flash-backed* (the stock kernel can't do zram).
- klippy RSS ~21 MB (**Python 3.7.2**, `/opt/Python-3.7.11`), Moonraker ~17 MB (**Python 3.11**, separate venv), stock Qt `firmwareExe` ~10.5 MB.
- **Two different Python interpreters** (3.7 vs 3.11, even different float ABI) → zero shared `libpython` pages between the two daemons.

---

## 2. ReForge memory plan (primary work)

### Available in P1–P3 (riding the stock 5.4.61 kernel)
| Lever | Effect | Notes |
|---|---|---|
| **Single shared `python3`** for klippy+Moonraker | one `libpython`, COW-shared read-only pages; shared C-exts; one interpreter on flash | The biggest available win. Stock can't (3.7 vs 3.11 baked in). Plan 2. |
| **`MALLOC_ARENA_MAX=2`** on both daemons | ~1–2 MB each (measured, see §5) | glibc spawns up to `8×CPU` per-thread arenas. Free. Plan 2 init scripts. |
| **Lazy numpy** | keeps numpy out of steady-state RSS | already Klipper's behavior (shaper-only). |
| **Strip + precompile Python** | smaller load, less text | drop unused stdlib. |
| **Drop stock Qt UI** (10.5 MB) | freed entirely | ReForge doesn't run `firmwareExe`. |
| **GuppyScreen** (C++/LVGL, no Python) | avoids a Python screen | vs KlipperScreen. |
| **Trim Moonraker components** | fewer loaded modules | disable update_manager/spoolman/announcements/notifier. |

### Unlocked only by ReForge's own kernel (P4+)
| Lever | Effect | Kernel config |
|---|---|---|
| **zram + zstd** (replace eMMC swapfile) | ~2–3× on anon pages, **no flash wear**, faster than eMMC swap | `CONFIG_ZRAM`, `CONFIG_ZSMALLOC`, `CONFIG_CRYPTO_ZSTD`; high `vm.swappiness` |
| **squashfs + zstd** read-only rootfs | clean/reclaimable file pages + smaller flash | `CONFIG_SQUASHFS` (+zstd) |
| **MGLRU** (Multi-Gen LRU, 6.1+) | far better cold-page detection than 5.4 LRU | mainline-LTS default |
| **f2fs** for writable `/data` | flash wear/perf; optional transparent file compression (flash, not RAM) | `CONFIG_F2FS_FS` (+`F2FS_FS_COMPRESSION`) |
| **Thumb-2** codegen | ~20–30% smaller text → less text RAM + flash | `BR2_ARM_INSTRUCTIONS_THUMB2` |
| `-Os` bulk + `--gc-sections` (+ optional LTO) | smaller binaries | keep `-O2 -mcpu=cortex-a7 -mfpu=neon-vfpv4` for klippy `chelper` only |
| KSM | marginal here (COW already shares Python) + A7 CPU cost | **likely skip** |
| jemalloc `LD_PRELOAD` (Moonraker) | fragmentation relief (NOT compression) | optional, measure first |

We are **already 32-bit** (Cortex-A7, no AArch64 on T113) — 4-byte pointers already.

---

## 3. Answers to specific questions

**jemalloc autocompression / a compressing jemalloc fork?** No — none exists in
production, and it's not feasible at the allocator layer (transparent compression
needs page-fault interception = kernel zram/zswap). jemalloc/tcmalloc only cut
fragmentation + return freed pages (`MADV_DONTNEED`/`FREE`). Closest userspace
thing is **`mesh`** (compaction, not compression; ARM32 support doubtful).
**On forge-x specifically: impossible** — stock kernel has no zram/zswap, and no
allocator can add compression.

**f2fs?** Good for the **writable `/data`** (wear + write perf + optional transparent
file compression = flash savings). Not a RAM lever. The RAM-relevant FS is
**squashfs+zstd** for the read-only rootfs. Both need our P4 kernel.

**A tool to evict cold pages to swap (vmtouch-inverse)?** The kernel already does
it automatically under pressure (kswapd/LRU, tuned by `vm.swappiness`). Proactive
options: cgroup-v2 `memory.reclaim`, `madvise(MADV_PAGEOUT)`, Meta's **`senpai`**.
Our P4 kernel's **MGLRU** makes cold-page detection much better. No dedicated CLI
needed for normal operation.

**Compile 32-bit / flags / qemu?** Already 32-bit (forced). Real flag wins:
**Thumb-2**, `-Os` bulk (keep NEON `-O2` for chelper), `--gc-sections`, optional LTO.
Test memory with **qemu-system-arm**, not qemu-user (qemu-user RSS is unrepresentative) — see §6.

**Stock Python for Moonraker on forge-x?** No — stock is **3.7.2**; modern Moonraker
needs **3.8+**. Won't start. Interpreter consolidation is a ReForge (clean-build)
property, not retrofittable to forge-x.

---

## 4. zram as a LOADABLE MODULE on the stock BSP (forge-x win — feasibility)

**Question:** can we compile `zram.ko`/`zsmalloc.ko` for the stock kernel and `insmod`?

**Verdict: plausible, low-risk to attempt, medium confidence.** Concrete facts:
- Stock kernel: `CONFIG_MODULES=y`, **no `MODULE_SIG`**, no `MODVERSIONS` (so only the **vermagic string** must match, not per-symbol CRCs), loads out-of-tree modules already (`8821cu.ko`).
- **`CONFIG_CRYPTO_ZSTD=y` is already builtin** — the compressor is present; we only need the `zram`+`zsmalloc` drivers (`CONFIG_ZSMALLOC`/`ZRAM`/`ZPOOL`/`ZBUD` are all `not set`).
- **Exact vermagic to match:** `5.4.61 SMP preempt mod_unload ARMv7 p2v8` (read from the stock `8821cu.ko`).
- `zswap` is **not** an option (frontend, builtin-only, can't be a module).

**Recipe (forge-x experiment, separate from ReForge):**
1. Obtain the **sun8iw20 BSP 5.4 source via the Allwinner Tina SDK** — the best source (it ships the exact vendor kernel + matching toolchain). Public mirrors: `DongshanPI/100ASK_T113-Pro_TinaSDK`, `...TinaSDK5`. (Building from the same source family the stock kernel came from maximizes the chance the module references symbols the running kernel exports — the one residual risk.)
2. Set `VERSION/PATCHLEVEL/SUBLEVEL = 5.4.61`, apply the **captured stock `.config`** (`docs/board-notes/stock-kernel-config-5.4.61.txt.gz`), then set `CONFIG_ZSMALLOC=m`, `CONFIG_ZRAM=m`, `CONFIG_ZPOOL=m`.
3. Build modules with the **Tina vendor toolchain** → vermagic `5.4.61 SMP preempt mod_unload ARMv7 p2v8` matches → no MODVERSIONS so only vermagic is checked.
4. `insmod zsmalloc.ko && insmod zram.ko`; set up zram0 with `zstd`, mkswap, swapon (priority above the eMMC swapfile).

**Tina SDK is also ReForge REFERENCE (not shipped) for the hard P5 parts:** its sun8iw20 **DE2.0/TCON-LCD/RGB-panel driver source + board DTS/`sys_config.fex` panel timings** are the implementation we translate to mainline DRM (the data g992/xblax lacked), and its **boot0/SPL DRAM params** seed mainline U-Boot. Consistent with the spec's "vendor BSP = parameter-extraction reference only" rule.

**Risks:** (a) `zsmalloc`/`zram` reference mm symbols — if the running kernel didn't `EXPORT_SYMBOL` one they need, insmod fails "Unknown symbol"; (b) **ABI/struct-layout mismatch** — the real killer (see TESTED below); (c) toolchain/vermagic match.

### TESTED 2026-05-31 → ✅ WORKS (vendor BSP source) — 4.02× on real pages
**zram + zstd compressed swap is working on the stock 5.4.61 kernel.** Modules built from
the **Allwinner T113 vendor BSP** (`iLotusK9/linux_kernel_aw_t113` branch `5.4.61`,
sun8iw20p1) load cleanly (no Oops); real klippy/moonraker cold pages compress **4.02×**
(3.8MB→0.9MB). zram becomes the primary swap above the eMMC file. **This applies to
forge-x AND ReForge P1–P3** (both ride the stock kernel) — so compressed swap is NOT
P4-only after all; it's available now via loadable modules. Deployable artifacts +
scripts: `modules/zram-bsp/dist/` + `zram-setup.sh`/`zram-teardown.sh`. Build: `modules/zram-bsp/build.sh` (KSRC=vendor BSP).

**Key lessons:** (1) vermagic match is necessary but NOT sufficient — upstream-5.4.61
source Oopsed (vendor `struct page` layout differs); must use vendor BSP source.
(2) Suppress the `5.4.61+` dirty-tree vermagic suffix with an empty `.scmversion`.

### Superseded first attempt (upstream source) → FAILED
Built all 4 modules from **upstream linux-5.4.61** + stock `.config` (GCC 9.5, kernel.org crosstool). **Vermagic matched exactly.** On live forge-x: `zsmalloc` loaded, then `zbud` caused a **kernel Oops (data abort)** — not a panic; printer recovered via `/sbin/reboot -f`. **Lesson: vermagic match is necessary but NOT sufficient.** The vendor kernel's `struct page`/mm layout differs from upstream (Allwinner patches); zsmalloc/zbud store metadata in `struct page` → corruption. **Must build from the Tina sun8iw20 5.4 BSP source** (layout-exact). insmod-failure is graceful but an ABI-mismatch Oops requires a reboot (no brick). Build workspace + full writeup: `modules/zram-bsp/`. If the Tina-source build loads, forge-x **and ReForge P1–P3** (which ride the stock kernel) get compressed-RAM swap without a kernel replacement.

---

## 5. MALLOC_ARENA_MAX measurement (live unit)
Synthetic (8 threads allocating, stock python3.7, glibc):
```
MALLOC_ARENA_MAX=unset   maxRSS=28.0 MB
MALLOC_ARENA_MAX=4       maxRSS=26.3 MB
MALLOC_ARENA_MAX=2       maxRSS=26.7 MB
MALLOC_ARENA_MAX=1       maxRSS=26.9 MB
```
→ **~1–2 MB** saving; real but modest. A live A/B on the actual Moonraker was
attempted but the chroot `start-stop-daemon` cycle was inert (process not replaced;
printer left untouched/safe), so the synthetic figure stands. Conclusion: set
`MALLOC_ARENA_MAX=2` in ReForge (free), don't fiddle further on forge-x for ~1–2 MB.

---

## 6. qemu testing strategy (per "use qemu-system-arm")

**Booting the stock BSP kernel in qemu: NOT feasible.** Confirmed by attempt —
`qemu-system-arm -M virt -cpu cortex-a7 -kernel uImage -dtb sunxi.dtb` produces
**zero console output** and hangs. Why: qemu has **no sun8iw20/R528/T113 machine
model** (only `cubieboard`=A10 and `virt`); the vendor kernel is hardwired to T113
peripherals (UART @ `0x05000000`, sunxi CCU clocks, OP-TEE, DRAM pre-init by boot0)
that `virt` doesn't provide. The uImage is Linux-5.4.61 ARM, load/entry `0x40008000`
(DRAM base `0x40000000`); DTB model `sun8iw20p1`, compatible `allwinner,r528`.
Booting the **actual U-Boot** is also blocked: U-Boot is not in the OTA (it lives on
eMMC p1/p2 — extractable from our golden dump) and is equally T113-specific.

**What qemu IS good for (our actual harness):**
- **qemu-user** (`qemu-arm-static` + `QEMU_LD_PREFIX`) — build/ABI correctness, "binary runs", imports. Already used in Plan 1/2. **Not** memory-representative.
- **qemu-system-arm `-M virt` + a generic mainline armv7 kernel + our ReForge rootfs** — boots a *real* ARM Linux to measure `free`/RSS/zram behavior representatively (different SoC, but real kernel mm + real glibc). This is the path for the memory experiments (MALLOC_ARENA, zram+zstd sizing, single-python COW, Thumb-2 footprint). Build a small `virt` kernel (virtio console/blk/net) as a test-only artifact; it never ships.
- **Faithful T113 emulation** would need a qemu machine model for R528/T113 (none upstream) — out of scope; real hardware remains the final word for board-specific behavior.

### Is there a vendor/SDK qemu fork for T113? No (verified)
- **Allwinner Tina SDK** (D1-H/T113/R528) is a **build system** (OpenWrt/Buildroot), not a qemu SoC model — at most qemu-user for build-time ARM binaries.
- **Mainline qemu** models only *old* Allwinner ARM SoCs: A10 (`cubieboard`), H3 (`orangepi-pc`). Nothing for the H616/R528/T113 generation.
- **Xilinx qemu fork** carries only the same A10-era Allwinner model (inherited), not T113.
- The **D1** (sibling) is **RISC-V** (XuanTie C906); T-Head's RISC-V qemu work is a different ISA and still lacks a complete mainline D1 machine — irrelevant to the ARM T113.
- Writing a minimal T113 machine (UART @0x05000000 + timer + GIC + CCU stubs, enough to reach a console) is ~few hundred lines but a real side-project — **not worth it** vs using real hardware. Conclusion unchanged: `virt`+generic-kernel for memory tests, real hardware for board-specific.
- **Would qemu's A10 (`cubieboard`) model be "close enough"? No.** A10 = **sun4i** (Cortex-A8, UART @`0x01c28000`, sun4i CCU/timer) — a different SoC generation from T113 (sun8iw20, A7, UART @`0x05000000`, different CCU/GIC). The BSP kernel finds none of its hardware there → same zero-output hang. And as a generic testbed, `-M virt -cpu cortex-a7 -smp 2` beats A10 (matches our real CPU + core count for glibc arena behavior + virtio I/O). Same-vendor ≠ compatible; a qemu SoC model only helps if it matches the exact SoC the kernel targets.

**Action:** add a `qemu-system-arm -M virt` memory-measurement harness as a ReForge
test target (Plan 2/research), separate from the qemu-user build smoke. The stock
BSP kernel is not bootable in qemu — use real hardware for board-specific validation.

---

## 7. forge-x improvement strategies (secondary — ReForge is primary)
Things we *could* retrofit to the current forge-x install, ranked by value/risk:
1. **zram loadable module** (§4) — biggest potential win (compressed swap on stock kernel); medium confidence, low risk to try. The only way to get compression on forge-x.
2. **`MALLOC_ARENA_MAX=2`** in the klippy + Moonraker launch env — free ~1–2 MB; trivial, reversible.
3. **Drop/disable stock Qt UI** when not on the STOCK screen (switch to FEATHER/GUPPY/HEADLESS via `zdisplay.sh`) — frees ~10.5 MB. forge-x already supports this.
4. **Trim Moonraker components** in `moonraker.conf` — disable update_manager/spoolman/announcements/notifier.
5. **`vm.swappiness` tuning** — marginal (uncompressed flash swapfile); only meaningful once zram exists.
6. jemalloc `LD_PRELOAD` for Moonraker (needs Entware `libjemalloc`) — fragmentation only, measure.

These are opportunistic; the structural wins (zram by default, single python, squashfs,
Thumb-2, MGLRU) belong to ReForge's clean build + own kernel.
</content>
