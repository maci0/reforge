# forge-x memory review — what's left to optimize (live audit)

Date: 2026-06-03. Live unit `root@192.168.0.158` (forge-x / `DrA1ex/ff5m`, stock
T113-S3, Linux 5.4.61, `MemTotal 110404 kB`). Goal: enumerate memory optimizations
**still available to forge-x** beyond what ReForge has already shipped or tested, grounded
in live measurement (not guesses). All probes read-only except the zram fix in §1.

## Live snapshot (idle, no print)

Userspace processes by **Pss** (kernel threads excluded):

| Pss (kB) | process |
|---|---|
| **17,199** | klippy (`/opt/Python-3.7.11` py3.7) |
| **16,247** | moonraker (`/root/moonraker-env` py3.11) |
| 1,588 | wpa_supplicant |
| ~356 | dropbear (×2), ntpd |
| 255 | wpa_cli |
| **155** | `httpd -p 80` (**busybox** — nginx already replaced) |
| <120 | klogd, syslogd, init, dbus, getty |

`MemAvailable ~53 MB`, `CmaTotal 16384 / CmaFree 6648` (≈10 MB CMA **in use** —
display/camera), `Shmem 1.3 MB`. The two Python daemons are ~33 MB of ~57 MB used —
**they are the whole game**; everything else is rounding error.

Diagnostics that shape the recommendations:
- **klippy has no allocator tuning** — env is only `LD_PRELOAD=/opt/tslib.../libts.so`; **no
  jemalloc, no `MALLOC_ARENA_MAX`**. numpy is **not resident** (Pss 0 → no input_shaper/ADXL
  loaded at idle), `libpython3.7` Pss only 1.1 MB → klippy's 17 MB is **heap/glibc-arena**
  dominated (7 threads).
- **moonraker has no allocator tuning at all** (no `MALLOC_*`, no `LD_PRELOAD`), 8 threads →
  glibc spawns per-thread arenas.
- moonraker.conf components on: `authorization, file_manager, history, klippy_apis, machine,
  octoprint_compat, server, update_manager (fluidd/forge-x/guppyscreen/mainsail), webcam`.

## 1. FIXED this session — zram was silently off

forge-x ships the zram framework (PR #66): `init_swap.sh` (run at boot via `S00init`),
`activate_zram_swap()`, `reforge-vmtune.sh`, and `zram.ko`/`zsmalloc.ko`. **But it is gated
on a config flag:**

```
swap=$(zconf.sh variables.cfg --get use_swap "MMC")   # init_swap.sh
case $swap in ZRAM) activate_zram_swap ... ;; MMC) activate_mmc_swap ... ;;
```

`variables.cfg` had **`use_swap = 'MMC'`** → every boot took the plain **eMMC-swapfile**
branch, and `reforge_vmtune` (called *only* inside `activate_zram_swap`) never ran. So the
box swapped to slow flash with stock sysctls — the zram + vmtune work was installed but
**inert**. (An earlier live demo activated zram in RAM only; the persistent flag stayed MMC.)

**Fix (applied):** `zconf.sh variables.cfg --set use_swap=ZRAM`, then ran `init_swap.sh`
live. Now: `/dev/zram0` 256 MB zstd prio 100 + eMMC 64 MB overflow prio −2; vmtune applied
(`page-cluster=0, swappiness=100, watermark_scale_factor=40, dirty_ratio=10,
dirty_background_ratio=5, vfs_cache_pressure=50`). Persists across reboots via the flag.

> **Lesson for forge-x tuning:** these are gated on `variables.cfg`. Setting them live does
> **not** persist — flip the flag (`use_swap=ZRAM`) so the boot path enables them.

## 2. Remaining levers (ranked, forge-x-applicable)

### #1 — tuned jemalloc for klippy + moonraker (biggest untapped)
Neither daemon has *any* allocator tuning today, so both pay glibc per-thread arena bloat
(klippy's 17 MB is mostly heap; moonraker has 8 threads). `LD_PRELOAD` jemalloc with
`MALLOC_CONF=narenas:1,dirty_decay_ms:0,muzzy_decay_ms:0` (single arena + immediate page
return) is what ReForge ships — **measured −6.5 MB Σ Pss (−11 %)**. This is the single
highest-value RAM change left for forge-x.
- Apply in the klippy + moonraker launchers (`start.sh` / the moonraker init), same pattern
  as ReForge's `S60klipper`/`S65moonraker`.
- Cheaper interim if jemalloc packaging is a problem: `MALLOC_ARENA_MAX=2` (forge-x's stated
  approach) — weaker, and jemalloc *ignores* it, so don't set both.
- *(Deferred this session per request; documented as the top next step.)*

### #2 — trim moonraker components (small, free)
- `octoprint_compat` — on, but Mainsail/Fluidd don't use the OctoPrint API. Drop unless an
  OctoPrint client is actually used.
- `history` — holds print records in moonraker's DB/working set; drop or cap if unused.
- `update_manager` — **keep** (forge-x self-updates through it; that's also why it carries a
  `git` dependency forge-x can't shed).

### #3 — zram comp_algorithm / overflow policy (already tuned, review only)
zstd at 256 MB is optimal for 128 MB (≈3.7–4.2× vs lzo-rle 2.74×). The eMMC overflow
swapfile (prio −2) adds flash wear for the cold tail — a policy choice, not a RAM lever;
consider dropping it if zram alone holds the working set.

## 3. Ruled OUT by measurement (don't spend effort)

| candidate | why not |
|---|---|
| **CMA shrink** (`cma=16M`) | `CmaFree 6648/16384` → ~10 MB **in use** (camera/display). Not safely shrinkable; risks alloc failure. |
| **DSP / reserved DRAM** | dramsize 128 → MemTotal 110; CMA accounts for ~16 of the ~18 MB gap → only ~2 MB DSP/kernel left. Negligible, and bootargs edits risk brick (no FEL/UART recovery). |
| **numpy trim** | not resident at idle (Pss 0); nothing to reclaim unless input_shaper is active. |
| **nginx → httpd** | already busybox `httpd` on this unit. Done. |
| **shared py3.7/py3.11 interpreter** | live-tested → **+16 MB** (py3.11 is the heavier interpreter). Negative; the Forge-X contribution has been removed from this repository. |
| **Qt UI → guppyscreen** | the heavy Qt `firmwareExe` isn't running at idle here; only a win *while* an on-screen UI is active, not an idle lever. |
| **THP / KSM / compaction** | not built into stock 5.4.61 (`CONFIG_*` unset) — kernel-rebuild items, not runtime (see `2026-06-02-stock-kernel-runtime-tuning.md`). |

## Bottom line

forge-x already does the cheap structural wins (busybox httpd, the zram + vmtune framework).
The gap was **configuration, not code**: zram was gated off (`use_swap=MMC`) — now fixed. The
one real lever still on the table is **tuned jemalloc on both Python daemons** (≈−6.5 MB);
after that only small moonraker-component trims remain. Everything exotic (CMA, DSP, UI,
numpy) is ruled out by the numbers.
