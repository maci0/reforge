# ReForge — lab notebook

## 2026-06-04 — autoresearch: BR stack memory under qemu virt (-m 128, NOSWAP)

Started a memory-optimization loop after the BR LTS / toolchain / klipper-v0.11
ground-clearing. Goal: minimize `sum(Pss)` of klippy + moonraker + httpd at
`-m 128 -smp 2 cortex-a7` with **no swap** (zram + eMMC overflow disabled by
`NOSWAP=1`), so the metric is pure RAM pressure with no swap-relief noise.

### Setup
- Archived the previous (closed) loop to `autoresearch-archive/2026-06-04-kernel-reproduction/`.
- `autoresearch.sh` wraps `tests/qemu-harness/mem-probe.sh` with `NOSWAP=1` and
  emits a structured JSON row per iter (`autoresearch.jsonl`).
- Fixed two real bugs in `mem-probe.sh` along the way:
  - TWEAKS sed targeted `/etc/init.d/` but the real init scripts live at
    `/mod/init.d/` — so all prior `TWEAKS=oo`/`arena1`/`jemalloc` runs were
    silently no-opping. Added `assert_sed` so a future miss fails loudly.
  - `moonraker.conf` lives at `/mod/etc/reforge/`, not `/etc/reforge/`.
- Noise floor measured from 3 warm baseline reruns: σ(sum_Pss) = **33.5 kB**,
  3σ threshold = **100 kB**. `MemAvailable` is ~4× noisier and is treated as
  secondary.

### Phase 1 — runtime tweaks (no rebuild) — COMPLETE

Warm-baseline mean (3 samples): `sum_Pss = 59587 kB`.

| iter | variant | sum_Pss | Δ | σ | verdict |
|---:|---|---:|---:|---:|---|
| 0v* | baseline (warm) | 59587 | 0 | 0 | reference |
| 1 | `oo` | 59747 | +160 | +5 | REGR (Python recompiles to `.opt-2.pyc`, churns page cache) |
| 2 | `no-jemalloc` | 60909 | +1322 | +40 | regression check — jemalloc is worth ~1.3 MB on this stack |
| 3 | `tcache-off` | 58683 | −904 | −27 | **WIN** −1.5% |
| 4 | `moonraker-min` | 58186 | −1401 | −42 | **WIN** −2.3% |
| 5 | **`tcache-off + moonraker-min`** | **57515** | **−2072** | **−62** | **BEST WIN −3.5%** |
| 6 | `tcache-off + metadata_thp:never` | 58862 | −725 | −22 | win, but worse than `tcache-off` alone (~+180 kB) |

**Phase 1 conclusion:** the two real, stackable runtime wins are `tcache:false`
in MALLOC_CONF (~900 kB) and stripping optional moonraker sections
(`[history]`/`[announcements]`/`[update_manager]`/`[octoprint_compat]`/
`[job_state]`/`[analysis]`, ~1400 kB). Combined: −2072 kB / −3.5% over the
already-tuned baseline. `python -OO` and `metadata_thp:never` are net negatives.

### Phase 2 — compile-time variants — COMPLETE

| iter | variant | sum_Pss | Δ | % | verdict |
|---:|---|---:|---:|---:|---|
| 7 | `gcc15-base` (gcc 14.3 → 15.2, defconfig flip) | 49428 | −10 159 | −17.0% | **HUGE WIN** |
| 7s60 | `gcc15-base` @ SETTLE=60 (verify steady state) | 49095 | −10 492 | −17.6% | confirmed steady |
| 8 | `gcc15-funcsec` (gcc15 + `-ffunction-sections -fdata-sections`) | 49503 | −10 084 | −16.9% | wash (~2σ vs iter 7) — LTO already does it |
| 9 | `gcc15-best` (gcc15 binary + Phase-1 stack) | **47488** | **−12 099** | **−20.3%** | **WIN** |
| 10 | PRODUCTION (= iter 9 @ SETTLE=60) | 47508 | −12 079 | −20.3% | reproduces iter 9 within noise |

Why gcc 15.2 alone gave −17%: virtually every shared library shrinks 25–50%:
libpython3.14.so −30%, numpy `_multiarray_umath.so` −34%, libcrypto.so.3 −27%,
libc.so.6 −37%, libsqlite3 −48%, klippy chelper `c_helper.so` −27%. Since
libpython + numpy are mapped into both klippy and moonraker, Pss accounting
picks up most of the per-binary win twice. Rootfs.tar itself shrinks 157 MB →
144 MB (−8.3%).

False start fixed along the way: my hand-written
`0001-chelper-disable-runtime-build-check.patch` had wrong hunk line counts
(`@@ -266,12 +266,14 @@`); GNU patch tolerated it with fuzz=1, Buildroot's
`-F0` did not. Regenerated from a clean `diff -u`, verified `-F0`-clean.

### Cumulative win

| stage | sum_Pss | Δ vs original baseline | cumulative Δ % |
|---|---:|---:|---:|
| original baseline (gcc 14.3, jemalloc-tight, full moonraker.conf) | 59587 kB | — | — |
| + Phase 1 (`tcache:false` + moonraker-min) | 57515 | −2 072 | −3.5% |
| + gcc 15.2 alone | 49428 | −10 159 | −17.0% |
| + **all combined (PRODUCTION)** | **47508** | **−12 079** | **−20.3%** |

### Recommended defconfig changes

```diff
+BR2_GCC_VERSION_15_X=y                                                  # −17% Pss across stack
```
plus the per-package runtime tweaks:
 - `/mod/init.d/S60klipper` and `S65moonraker` already preload jemalloc with `narenas:1,dirty/muzzy_decay_ms:0`. **Add `tcache:false`** to MALLOC_CONF (−0.9 MB).
 - `/mod/etc/reforge/moonraker.conf`: drop `[history]`, `[announcements]`, `[update_manager]`, `[octoprint_compat]`, `[job_state]`, `[analysis]` if those features are not used (−1.4 MB).

### Known blockers

- clang as system toolchain not supported in BR 2026.02.2 LTS —
  `BR2_PACKAGE_CLANG` is a target-binary package only, no
  `BR2_TOOLCHAIN_USES_CLANG` exists. Documented + parked.

---

## 2026-06-04 — live USB: 2-partition (vfat + f2fs) replaces loop-on-FAT

Replaced the single-FAT + loop-mounted `reforge-live.f2fs` image-file layout with
a 2-partition MBR disk image (p1 vfat 64 MiB, p2 f2fs label=`reforge-live`).

**Why**: the old layout needed `loop.ko` (with a custom
`MODULE_IMPORT_NS(VFS_internal_…)` patch on `loop.c` because loop was never a
module in this BSP), F2FS DISCARD/TRIM over loop-on-FAT failed with `-EIO` spam
(launcher needed `nodiscard`), and the rootfs was capped by FAT's 4 GiB file size
limit. Putting the rootfs on a real F2FS partition removes all three.

Changes:
- `packaging/live/flashforge_init.sh` — dropped `loop.ko` insmod, dropped the
  loop-mount path. New `find_f2fs_dev()` discovers the rootfs partition in this
  order: (1) `F2FS_DEV` / legacy `LIVE_IMG` env override (test rigs); (2)
  `blkid -L reforge-live`; (3) derive sibling from the FAT partition we were
  launched off of (`/proc/mounts` lookup, `/dev/sda1` → `/dev/sda2`); (4)
  brute-force F2FS-magic scan of `/dev/sd?[2-4]`. Then `mount -t f2fs -o rw` it
  directly, with a fallback to type-autodetect for the ext4 qemu gates.
- `modules/f2fs-bsp/build.sh` — dropped `loop.ko` build (and the `loop.c`
  MODULE_IMPORT_NS patch); only `crc32_generic.ko` + `f2fs.ko` are produced now.
  Deleted `modules/f2fs-bsp/dist/loop.ko` from the committed prebuilts.
- `tools/release/build-live-usb.sh` — rewritten. Output is now
  `reforge-live-<ver>.img.gz` (a partitioned disk image), not a `.tar.gz`. Builds
  rootlessly via `sfdisk` (MBR onto a regular file), `mtools` (`mformat` +
  `mcopy` for the FAT partition), `mkfs.f2fs` + `sload.f2fs` (for the F2FS
  partition), then `dd` splices each partition image into the disk image at its
  LBA offset. End-to-end smoke-tested with a fake rootfs: sfdisk MBR is well-formed,
  blkid reports `p1=vfat label=REFORGE_LIV` and `p2=f2fs label=reforge-live`,
  fsck.f2fs on p2 passes, F2FS magic `10 20 f5 f2` at offset 0x400 of p2 confirmed.
- `tests/qemu-harness/live-{mode,ota}-test.sh` — pass `F2FS_DEV=/dev/vdb`
  (was `LIVE_IMG=/dev/vdb`). Backwards compat shim in the launcher keeps the old
  name working too.
- Docs updated: `docs/live-mode.md` (new flash procedure + USB layout + rationale),
  `docs/REPO-LAYOUT.md` (module list), `docs/reverse-engineering/stock-kernel-modules-packaging.md`
  (insmod inventory), `docs/BACKLOG.md` (item marked DONE).

**Cost**: the stick is now flashed (`dd` or balenaEtcher) instead of "extract a
tarball onto any FAT USB". Acceptable per the BACKLOG entry's framing.

**Verified**: shellcheck clean (70 scripts, 0 findings); `bash -n` / `sh -n` on
all edited scripts; netup unit tests still pass; end-to-end build of a fake
rootfs produces a structurally-correct 450 MiB disk image. **Not yet verified**:
real hardware (loop-on-FAT was last verified on hardware 2026-06-02; the
2-partition layout needs the next trial).

---

## 2026-06-04 — autoresearch loop: close the +128 B kernel-reproduction gap

Started experiment loop. Goal: drive `|bytes(Image.ours-linaro) - bytes(Image.stock)|`
to 0 (currently +128 B, from byte-identical reproduction work earlier this session).

Baseline: +128 B size delta, IKCONFIG.gz already byte-identical, first divergence
at file offset 0x15c (kernel Image header — likely embedded size constants that
shift with any code change downstream). 6.07 MB of cmp-diff dominated by
kallsyms address cascade — that's a noise floor, not a real metric.

Lever: `vendor/kernels/patches/0001-byte-identical-reproduction.patch`.
Build script applies/reverts; BSP submodule stays pristine at 349a0b9.

Dashboard: `autoresearch.md`. Per-iter log: `autoresearch.jsonl`.

### 2026-06-04 — autoresearch loop ended at iter 2 (diagnosis complete)

Loop stopped at iter 2 with the gap fully diagnosed but not closed.

**Root cause found**: kallsyms decoder revealed our build has 41 net extra
symbols (529 ours-only vs 490 stock-only). +824 B in kallsyms, −696 B in
non-kallsyms code → net +128 B. The cause is BSP submodule snapshot drift:
- IR driver renamed (`sunxi_ir_recv_*` → `sunxi_irrx_*`)
- Old `sunxi_pwm.c` chrdev driver removed (9 PWM functions gone)
- Bootlogo handoff helpers removed (3 functions)
- Realtek BT coex stack added (30 functions we now have, stock didn't)
- Newer-SoC plumbing added (sun20iw1, sun55i, DCXO, RTC v201)

All five changes left Kconfig identical → our IKCONFIG matched stock's
byte-for-byte, but the resulting `obj-$(CONFIG_*)` selections differ.
Not closable without the older BSP source snapshot (Auto SDK blocked on
Baidu link).

Confirmed my reconstructed `sunxi_can_asm.h` was a non-factor: zero
`sunxican_*` / `can_asm_*` symbols appear on the diff list. The earlier
hypothesis that the CAN reconstruction was responsible was wrong.

Artifacts:
- `autoresearch.md` — dashboard with full iter table + diagnosis
- `autoresearch.jsonl` — raw iter log
- `autoresearch.sh` — benchmark wrapper (`bash autoresearch.sh`)
- `outputs/kallsyms-symbol-diff.md` — full symbol-set diff with classification

Decision: documented current +128 B as the iLotusK9-vs-FF snapshot drift
ceiling and stopping. Will revisit if Auto SDK arrives.

### 2026-06-04 — autoresearch iters 3+4: substitution wins (size still +128 B)

After diagnosing the iter-2 symbol-set drift, ran two more iterations that
substitute the deltas we could close from public GitHub sources:

**Iter 3** — PWM substitution from ayueying/linux-5.4 @ 2022-09-08:
- Added `vendor/upstream-snippets/pwm-sunxi-g_dev/pwm-sunxi-g_dev.c`
  (5668 B, sha256 f53450ae74…, Copyright (C) 2019 AllWinner)
- Patch appends new file + Makefile line `obj-$(CONFIG_PWM_SUNXI_GROUP) += pwm-sunxi-g_dev.o`
- Result: all 9 stock-only PWM symbols (sunxi_pwm_class/dev/exit/fops/init/
  open/release/unlocked_ioctl + __initcall_sunxi_pwm_init6) now present in
  ours. Image total unchanged at +128 B. cmp_l_count −28 KB.

**Iter 4** — Realtek BT-coex stack removal:
- Comment out `#define BTCOEX` in drivers/bluetooth/hci_uart.h
- Drop `hci_uart-y += rtk_coex.o` from drivers/bluetooth/Makefile
- Result: all 30 BT-coex ours-only symbols (rtk_btcoex_*, rtk_handle_*,
  rtl_l2_*, udpsocket_*, etc.) gone. Net symbol Δ +41 → +15.
  cmp_l_count 6.07M → 5.92M (−2.5 %). first_diff_off 0x15c → 0xf968c
  (first MB now byte-identical to stock).

**Size delta diagnosis**: 128 B is a **256-byte linker alignment artifact**:
  ours mod 128 = stock mod 128 = 44 (same cache line)
  ours mod 256 = 44, stock mod 256 = 172 (Δ = 128)

The ~15 remaining net-extra symbols (sunxi_irrx_* IR rename, DCXO,
sun20iw1/sun55i newer-SoC, closed-source bootlogo helpers) tip ours past
a 256-byte alignment boundary, costing exactly +128 B of `.data` padding.

Closing this further requires either the Auto SDK source (3-5 specific
files, still blocked on broken Baidu link) OR finding a code change that
shifts us by exactly 128 B more (fragile, could land +256 or −128).

Patch now: `vendor/kernels/patches/0001-byte-identical-reproduction.patch`
26,719 B (was 19,293 B). Build script applies/reverts as before.
