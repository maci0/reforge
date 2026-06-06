# research/

Dated findings — investigations that backed a decision. **Snapshots:** they record what was
found at the time and are not rewritten on later refactors (a `## Update <date>` section is
added if a finding is re-verified). The conclusions that survived are folded into the reference
docs ([`../optimizations.md`](../optimizations.md), [`../boot.md`](../boot.md),
[`../architecture.md`](../architecture.md)). Filenames are `YYYY-MM-DD-topic.md`.

## Kernel & SoC
- [2026-06-01-t113-mainline-kernel-support.md](2026-06-01-t113-mainline-kernel-support.md) — **the canonical mainline-kernel doc.** T113-S3 (sun8iw20) per-peripheral mainline status; every AD5M peripheral incl. **RTL8821CU WiFi** is upstream (v6.4+) → a 6.x/7.x kernel needs only a board DTS + RGB panel (Plan 5). Re-verified vs `linux-6.19` and `7.0.11`.
- [2026-05-31-buildroot-vs-alpine.md](2026-05-31-buildroot-vs-alpine.md) — why Buildroot over Alpine userspace + our own kernel/U-Boot.
- [2026-06-04-bsp-kernel-rebuild-findings.md](2026-06-04-bsp-kernel-rebuild-findings.md) — ✅ host-only rebuild of the stock BSP kernel (vendor source + captured `.config` + GCC 9.5.0) vs the on-device `Image`: functionally equivalent, vermagic byte-identical.
- [2026-06-04-byte-identical-kernel-reproduction.md](2026-06-04-byte-identical-kernel-reproduction.md) — pushing the rebuild to **byte-identical** (Linaro GCC 5.3.1 + exact stock build path/strings); DTB is a boot-resource artifact, not in the kernel.
- [2026-06-06-kernel-compiler-and-size-options.md](2026-06-06-kernel-compiler-and-size-options.md) — kernel RAM levers: gcc-9.5 vs gcc-15 (gcc-15 ~1 MB heavier `.text` at `-O2`), `-Os` = +3 MB free (already on device, now on the virt test kernel too), kernel LTO unavailable on arm32/GCC, a `size`-predicted **~1.5 MB** from stripping unused built-in subsystems (BT/SND/CAN/IPV6/KALLSYMS_ALL), **and (§5) a mainline 7.0.11 size sweep** — config scope (`multi_v7`→`sunxi`) is −16.5 MB vs any opt flag; tuned 7.0 `sunxi` kernel (10.0 MB) reaches size parity with our 5.4 stock; gc-sections new on 7.0 arm32, Clang LTO still arm32-unsupported.
- [2026-06-04-brick-safe-kernel-test-paths.md](2026-06-04-brick-safe-kernel-test-paths.md) — testing a custom kernel **without** persistent eMMC writes (`kexec` on stock; FEL via `xfel`; one-time `boot.img` reflash). Reference, **not rehearsed**.
- [2026-06-05-replacing-pid1.md](2026-06-05-replacing-pid1.md) — replacing PID 1 (reforge-init + `pivot_root`) for an early, brick-safe switch_root (boot.md §2 Option A).
- [2026-06-05-overlayfs-on-bsp-spike.md](2026-06-05-overlayfs-on-bsp-spike.md) — ✅ OverlayFS builds as a loadable `.ko` against the stock 5.4.61 BSP (which ships `# CONFIG_OVERLAY_FS is not set`) → green light for atomic/immutable ReForge (versioned lower dir + `current`-symlink pointer-swap; drives [`../plans/2026-06-05-immutable-reforge.md`](../plans/2026-06-05-immutable-reforge.md)).
- [2026-06-01-stock-recovery-images.md](2026-06-01-stock-recovery-images.md) — stock firmware / recovery-image landscape.
- [2026-05-31-g992-research-findings.md](2026-05-31-g992-research-findings.md) — findings mined from the g992 AD5M repo (incl. the eboard MCU boot handshake).

## Memory (128 MB budget)
*Lineage (oldest → current): strategy (memory-and-testing) → early A/B (memory-savings-experiments) → allocator decision (jemalloc-test-plan — **klippy adoption later reverted**, see caveat below) → forge-x audit (forge-x-memory-review) → **current measured baseline: reforge-vs-forgex-memory**. Kernel-side RAM levers are in [2026-06-06-kernel-compiler-and-size-options.md](2026-06-06-kernel-compiler-and-size-options.md) under Kernel & SoC. Canonical consolidated numbers: [`../optimizations.md`](../optimizations.md).*

- [2026-05-31-memory-and-testing.md](2026-05-31-memory-and-testing.md) — memory-optimization + testing strategy.
- [2026-06-01-memory-savings-experiments.md](2026-06-01-memory-savings-experiments.md) — measured memory-savings experiments.
- [2026-06-01-jemalloc-test-plan.md](2026-06-01-jemalloc-test-plan.md) — jemalloc evaluation test plan. *(Caveat: jemalloc `LD_PRELOAD` corrupts klippy's heap on real hardware — kept for moonraker only; see [`../boot.md`](../boot.md).)*
- [2026-06-02-stock-kernel-runtime-tuning.md](2026-06-02-stock-kernel-runtime-tuning.md) — stock-kernel runtime tuning audit.
- [2026-06-03-forge-x-memory-review.md](2026-06-03-forge-x-memory-review.md) — live forge-x memory audit (what's left to cut).
- [2026-06-05-reforge-vs-forgex-memory.md](2026-06-05-reforge-vs-forgex-memory.md) — measured memory: ReForge (production) vs forge-x.

## UI / camera / video
- [stock-ui-spike.md](stock-ui-spike.md) — P3 Task 8 stock-UI feasibility spike.
- [2026-06-02-qemu-ui-rendering.md](2026-06-02-qemu-ui-rendering.md) — rendering the printer UIs under qemu (the LVGL-vs-virtio-gpu fb-flush quirk).
- [2026-06-03-camera-streaming-options.md](2026-06-03-camera-streaming-options.md) — camera streaming beyond MJPEG.
- [2026-06-04-cedar-ve-encode-and-camera-fw.md](2026-06-04-cedar-ve-encode-and-camera-fw.md) — Cedar VE H.264 HW-encode re-attempt (no encoder in silicon — JPEG/MJPEG only) + camera native format/firmware.

## Printer stack (Klipper / Moonraker)
- [2026-06-04-klipper-v0.11-fork-deltas.md](2026-06-04-klipper-v0.11-fork-deltas.md) — FlashForge AD5M Klipper fork vs upstream v0.11.0 deltas.

**Consolidated tuning results live in [`../optimizations.md`](../optimizations.md)** — these
files are the backing experiments, not the canonical numbers.

Saved config/artifact files referenced by these docs (e.g. the 7.0.11 stocklike kernel config)
live in [`configs/`](configs/).
