# research/

Dated findings — investigations that backed a decision. Snapshots: they record what was
found at the time and are not rewritten on later refactors. The conclusions that survived
are folded into the reference docs (`../optimizations.md`, `../boot.md`, `../architecture.md`).

## Platform / kernel
- [2026-06-01-t113-mainline-kernel-support.md](2026-06-01-t113-mainline-kernel-support.md) — T113-S3 (sun8iw20) mainline/LTS kernel support (Plan 5).
- [2026-05-31-buildroot-vs-alpine.md](2026-05-31-buildroot-vs-alpine.md) — why Buildroot over Alpine userspace + our own kernel/U-Boot.
- [2026-06-01-stock-recovery-images.md](2026-06-01-stock-recovery-images.md) — stock firmware / recovery-image landscape.
- [2026-05-31-g992-research-findings.md](2026-05-31-g992-research-findings.md) — findings mined from the g992 AD5M repo.
- [2026-06-04-brick-safe-kernel-test-paths.md](2026-06-04-brick-safe-kernel-test-paths.md) — paths for testing a custom kernel **without** persistent eMMC writes (`kexec` status on stock; FEL via `xfel` over USB0; one-time `boot.img` reflash hybrid). Reference, **not rehearsed**.
- [2026-06-04-bsp-kernel-rebuild-findings.md](2026-06-04-bsp-kernel-rebuild-findings.md) — ✅ host-only rebuild of the stock BSP kernel (vendor source + captured `.config` + GCC 9.5.0) compared against the on-device `Image` from the golden eMMC dump: functionally equivalent, vermagic byte-identical, 99.99% export coincidence. Unblocks `CONFIG_KEXEC=y` overlay (Path A).

## Memory (128 MB budget)
- [2026-05-31-memory-and-testing.md](2026-05-31-memory-and-testing.md) — memory-optimization + testing strategies.
- [2026-06-01-memory-savings-experiments.md](2026-06-01-memory-savings-experiments.md) — measured memory-savings experiments.
- [2026-06-01-jemalloc-test-plan.md](2026-06-01-jemalloc-test-plan.md) — jemalloc evaluation test plan.
- [2026-06-02-stock-kernel-runtime-tuning.md](2026-06-02-stock-kernel-runtime-tuning.md) — stock-kernel runtime tuning audit.
- [2026-06-03-forge-x-memory-review.md](2026-06-03-forge-x-memory-review.md) — live forge-x memory audit (what's left to cut).

## UI / camera
- [stock-ui-spike.md](stock-ui-spike.md) — P3 Task 8 stock-UI feasibility spike.
- [2026-06-02-qemu-ui-rendering.md](2026-06-02-qemu-ui-rendering.md) — rendering the printer UIs under qemu.
- [2026-06-03-camera-streaming-options.md](2026-06-03-camera-streaming-options.md) — camera streaming beyond MJPEG.

**Consolidated tuning results live in [`../optimizations.md`](../optimizations.md)** — these
files are the backing experiments, not the canonical numbers.
