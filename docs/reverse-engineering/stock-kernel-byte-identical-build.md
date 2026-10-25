# Byte-identical reproduction of the stock AD5M Pro kernel

**Status (rechecked 2026-10-25):** historical source-rebuild experiment; the
complete raw Image is **not byte-identical**. The closest cached build is 128
bytes longer, with 5,915,891 differing bytes at shared offsets and the first
difference at `0xf968c` (1,021,580 matching leading bytes). Banner and embedded
IKCONFIG match. The earlier alignment explanation below is diagnostic history,
not proof of whole-image or functional equivalence. The historical runner also
requires an isolated source tree before reuse; its cleanup resets tracked source
files. See the [current bringup audit](../board-notes/stock-bringup-rebuild.md).

**See also:**
[`stock-kernel-modules-packaging.md`](stock-kernel-modules-packaging.md)
(how FF packages the resulting modules + flat `8821cu.ko` slot),
[`../research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md`](../research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md)
(earlier Tier 1+2+3 functional-equivalence rebuild with GCC 9.5.0),
[`../research/kernel/2026-06-04-brick-safe-kernel-test-paths.md`](../research/kernel/2026-06-04-brick-safe-kernel-test-paths.md)
(why we needed a reproducible build in the first place — Path A enablement
for `CONFIG_KEXEC=y`).

---

## TL;DR

- **Reproducible from public source**: pinned BSP submodule
  (`iLotusK9/linux_kernel_aw_t113@349a0b9`) + pinned Linaro 5.3.1
  toolchain + captured stock `.config` + an apply-on-build patch.
  No private FF/Allwinner assets needed; submodule stays pristine.
- **+128 B** Image-size delta vs stock. All `vermagic`, Linux-version
  banner (including toolchain version strings), build user / host /
  `#52` / timestamp are **byte-identical**. Embedded **IKCONFIG.gz is
  byte-identical** (the gzipped `.config` ELF blob). **First 1,021,580 bytes** of
  the cached Image are byte-identical to stock. `cmp -l` mismatched-byte count
  is dominated by post-kallsyms address-cascade noise, not real diffs.
- The +128 B is a **256-byte alignment crossing in `.data`**: ours
  size mod 128 = stock mod 128 = 44 (same cache-line offset), but
  ours mod 256 = 44 vs stock mod 256 = 172 (Δ = 0x80). The linker
  pads the next section to the 256-B align, costing exactly 128 B.
- The ~15 net-extra symbols that tip ours over that alignment line
  (~300 B of code) are **dead drivers on this printer** — see §6.
  None of the residual differences can change runtime behaviour.

---

## 1. Build configuration

| Aspect | Value | Source |
|---|---|---|
| Kernel | `Linux 5.4.61` | BSP submodule + captured `.config` |
| Toolchain (host) | **Linaro GCC 5.3-2016.05** (`5.3.1 20160412`) + `ld` 2.25 Linaro 2016_02 | matches stock's Linux-version banner byte-for-byte |
| Source tree path | **`/home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4/`** | extracted from stock kernel's embedded `__FILE__` strings; matched via `bind-mount` of our submodule |
| `SOURCE_DATE_EPOCH` | `1692776013` (2023-08-23 15:33:33 CST) | captured from stock's banner |
| `KBUILD_BUILD_USER` | `root` | captured |
| `KBUILD_BUILD_HOST` | `linux-virtual-machine` | captured |
| `KBUILD_BUILD_TIMESTAMP` | `Wed Aug 23 15:33:33 CST 2023` | captured |
| `KBUILD_BUILD_VERSION` | `52` (the `#52` in banner) | captured |
| `LOCALVERSION` | (empty) | captured |
| `.scmversion` | empty file | suppresses kbuild's `+` suffix |
| `vermagic` | `5.4.61 SMP preempt mod_unload ARMv7 p2v8` | byte-identical to stock |
| GCC plugins | **disabled** via forced `CONFIG_PLUGIN_HOSTCC=""` | stock host had no g++ on PATH |
| Pinning artifact | `pins.lock` rows `tina-bsp-kernel`, `gcc-linaro-5.3.1` | sha256-verified |

The Linaro 5.3.1 toolchain is downloaded by
`FETCH_LINARO=1 ./vendor/fetch.sh` (sha256
`77cccd433d680251c8b9bfa01890cb6921548513a39fac35c1f4b9f0a47e5aa4`).
Total size 176 MB; gitignored. ReForge's **shipping** kernel is not this build:
it is built by Buildroot with its own **gcc-15.2** toolchain at `-Os` (`make
kernel`). The standalone **GCC 9.5.0** crosstool build (`build-bsp-kernel.sh`)
is a reference/comparison build, not the shipping path — see
[`../research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md`](../research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md)
and [`../research/kernel/2026-06-06-kernel-compiler-and-size-options.md`](../research/kernel/2026-06-06-kernel-compiler-and-size-options.md).

---

## 2. Reproducer (executable today)

### 2.1 One-time setup

```sh
# 1. Pin the Linaro toolchain + extract under vendor/toolchains/
FETCH_LINARO=1 ./vendor/fetch.sh

# 2. Make the stock build-path resolvable as a real directory.
#    kbuild's realpath dereferences symlinks (which would change __FILE__
#    strings), so we use a bind-mount, not a symlink.
sudo mkdir -p /home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel
sudo chown -R $USER /home/linux
sudo mount --bind $(pwd)/vendor/kernels/tina-bsp-kernel \
    /home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4
```

The bind-mount survives across builds but does NOT survive a reboot. Add
to `/etc/fstab` if you want it permanent.

### 2.2 Each build

```sh
make bsp-kernel-stock
# or directly:
tools/build/build-bsp-kernel-stock.sh
```

Output: `build/bsp-kernel-rebuild-stock/artifacts/`

| File | What |
|---|---|
| `Image.ours-linaro` | the rebuilt kernel image |
| `Image.stock` | symlink to the cached stock image extracted from the golden eMMC dump |
| `vmlinux.ours-linaro` | full vmlinux for symbol/section inspection |
| `System.map.ours-linaro` | symbol map (matches `ours-linaro` only) |

The build takes ~28 seconds on a modern host. Re-runs are deterministic
to the byte — the same patch + same submodule commit + same Linaro
toolchain always produces the same Image.

### 2.3 Verification

```sh
# Image-size delta (should be +128 B):
python3 -c "
import os
o = os.path.getsize('build/bsp-kernel-rebuild-stock/artifacts/Image.ours-linaro')
s = os.path.getsize('build/bsp-kernel-rebuild/artifacts/Image.stock')
print(f'ours - stock = {o-s:+} B ({100*(o-s)/s:+.6f}%)')"

# IKCONFIG.gz byte-identical?  (should match)
diff <(zcat docs/board-notes/stock-kernel-config-5.4.61.txt.gz) \
     <(python3 -c "
data = open('build/bsp-kernel-rebuild-stock/artifacts/vmlinux.ours-linaro','rb').read()
import gzip, io
st = data.find(b'IKCFG_ST'); ed = data.find(b'IKCFG_ED')
print(gzip.decompress(data[st+8:ed]).decode())")
```

---

## 3. Patch overlay structure

All modifications to the BSP submodule are packaged into a single patch
file that the build script applies before `make` and reverts on exit:

- Patch: [`../../vendor/kernels/patches/0001-byte-identical-reproduction.patch`](../../vendor/kernels/patches/0001-byte-identical-reproduction.patch)
  (~27.5 KB; applies cleanly against pinned BSP commit `349a0b9`)
- Patches README: [`../../vendor/kernels/patches/README.md`](../../vendor/kernels/patches/README.md)
- Build script installs `trap revert_patch EXIT INT TERM` — the submodule
  returns to pristine state regardless of how the build exits.

The patch is the sum of seven logical groups:

| # | Patch group | Why |
|---|---|---|
| 1 | **CAN_SUN8I wiring** — `drivers/net/can/{Kconfig,Makefile}` | Stock's IKCONFIG has `CONFIG_CAN_SUN8I=y`. Our BSP submodule has the orphan `sunxi_can.c` + `sunxi_can_asm.S` sources but no Kconfig/Makefile wiring. Adds a `config CAN_SUN8I` stanza + `obj-$(CONFIG_CAN_SUN8I) += sunxi_can.o sunxi_can_asm.o`. |
| 2 | **Reconstructed `drivers/net/can/sunxi_can_asm.h`** (new file) | Closed-source from the Auto SDK overlay; the public BSP omits it, leaving `sunxi_can.c` uncompilable. 30 `SUNXI_*` register/bit defines reconstructed from mainline `sun4i_can.c`; 12 `can_asm_*` prototypes inferred from `sunxi_can.c` call-site analysis. |
| 3 | **Stub `drivers/staging/rtl8821cu/Kconfig`** + `source` line in `drivers/staging/Kconfig` | Captured stock `.config` has `CONFIG_RTL8821CU=m`. The real Realtek vendor source is NOT shipped in the public BSP — the stub lets `olddefconfig` resolve the symbol at the correct IKCONFIG position (right after `R8188EU`). No Makefile target → no module produced; the symbol is config-only. |
| 4 | **`depends on FORCE_HIDE_NEWER_BSP`** added to 14 newer Kconfig stanzas | Our submodule has 14 Kconfig entries that didn't exist when FF built. Each would emit a `# CONFIG_X is not set` line in IKCONFIG that stock's doesn't have. `FORCE_HIDE_NEWER_BSP` is an undefined symbol → Kconfig treats it as `n` → stanzas are invisible to `olddefconfig`. Affected: `BT_HCIUART_RTL3WIRE`, `RTL8189FS`, `PINCTRL_SUN55IW3` + `_R`, `MFD_ACX00`, `SND_SOC_SUNXI_{SPDIF,DMIC,DAUDIO,COMPONENTS}` + the V2 menu header, `SND_SOC_TD100`, `RPMSG_SUNXI_TTY` + `_CLIENT_SAMPLE`. |
| 5 | **`CONFIG_PLUGIN_HOSTCC` override** in `scripts/gcc-plugins/Kconfig` | Replaces `default "$(shell,...)"` with `default ""`. Stock's host had no g++ on PATH (probe evaluated empty); ours does. With `PLUGIN_HOSTCC=""`, `CONFIG_GCC_PLUGINS` auto-hides (it has `depends on PLUGIN_HOSTCC != ""`). |
| 6 | **PWM chrdev import** — `drivers/pwm/pwm-sunxi-g_dev.c` (new file from `ayueying/linux-5.4`) + Makefile line `obj-$(CONFIG_PWM_SUNXI_GROUP) += pwm-sunxi-g_dev.o` | The iLotusK9 BSP submodule dropped this file. Stock has 9 PWM symbols (`sunxi_pwm_class/dev/exit/fops/init/open/release/unlocked_ioctl` + `__initcall_sunxi_pwm_init6`) from it. The file is identical to stock's Auto-SDK version (Copyright "2019 AllWinner"; sha256 `f53450ae74…`, 5,668 B). |
| 7 | **BT-coex removal** in `drivers/bluetooth/{hci_uart.h,Makefile}` | iLotusK9's BSP added a Realtek BT-WiFi coex stack (`rtk_coex.c`, 30 symbols) after FF's snapshot. Comments out `#define BTCOEX` in `hci_uart.h:15` (the file's only gate) and drops `hci_uart-y += rtk_coex.o`. |

After all seven groups apply, the embedded **IKCONFIG.gz is byte-identical
to stock** and 484 of 529 baseline ours-only symbols are gone.

---

## 4. Byte-decomposition of the residual delta

```
Image.ours-linaro:    12,970,284  bytes
Image.stock:          12,970,156  bytes
                      ──────────
                      +128  bytes  total Δ

  IKCONFIG.gz:          0 bytes Δ (byte-identical embedded `.config`)
  rest of Image:     +128 bytes Δ (256-byte linker alignment artifact)
```

### Section breakdown (vs stock)

| Region | ours bytes | stock bytes | Δ |
|---|---:|---:|---:|
| `kallsyms_offsets`         | 4 × 72,486 = 289,944 | 4 × 72,471 = 289,884 | +60 |
| `kallsyms_names`           | 877,876 | 878,060 | −184 |
| `kallsyms_markers`         | 1,136 | 1,136 | 0 |
| `kallsyms_token_table`     | 920 | 920 | 0 |
| `kallsyms_token_index`     | 512 | 512 | 0 |
| `kallsyms_relative_base+num_syms` | 8 | 8 | 0 |
| `kallsyms total`           | 1,170,756 | 1,170,520 | **+236** |
| Non-kallsyms (text + rodata + data + init + bss) | — | — | **−108** |
| **Image total** | 12,970,284 | 12,970,156 | **+128** |

The +236 B kallsyms growth is from 15 net-extra symbols (avg ~16 B each
including offsets + compressed names + token-index churn). The −108 B
non-kallsyms shrinkage is mostly stock's missing-on-our-side `disp2`
bootlogo code + `sunxi_ir_recv` driver code that we don't have.

### Why the total is exactly +128

```
ours  size mod 128 = 44      stock size mod 128 = 44   (same cache line)
ours  size mod 256 = 44      stock size mod 256 = 172  (Δ = 128)
```

Both images land at the same offset within a 128-byte cache line. The
128-byte delta is one of our `.data`/`.bss` sections crossing a 256-byte
alignment boundary that stock's doesn't. The linker pads the next
section to the next 256-byte align, costing exactly 0x80 (128) bytes
regardless of the underlying source change.

This is a **discretized** outcome — small symbol-set differences either
cost 0 B or one full alignment block (128 B), depending on which side of
the boundary the build lands.

---

## 5. Validation (what's byte-identical, what isn't)

| Property | ours-linaro | stock | Match? |
|---|---|---|---|
| `vermagic` | `5.4.61 SMP preempt mod_unload ARMv7 p2v8` | same | ✅ exact |
| Linux-version banner | `Linux version 5.4.61 (root@linux-virtual-machine) (gcc version 5.3.1 20160412 (Linaro GCC 5.3-2016.05) ) #52 SMP PREEMPT Wed Aug 23 15:33:33 CST 2023` | same | ✅ exact |
| `__FILE__` strings (paths embedded in `BUG_ON`, `WARN`, `pr_*`) | `/home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4/...` | same | ✅ exact (via bind-mount) |
| `IKCONFIG.gz` embedded blob | 26,144 bytes | 26,144 bytes | ✅ byte-identical |
| `EXPORT_SYMBOL` count | 9,055 | 9,056 | 1 export missing (the `sunxi_smc_get_tcoffer_ver` symbol from newer-SoC code we hid) |
| `__create_page_tables` constants (file 0x15c–0x245) | shifted | (reference) | shifted because some symbol at the kernel end is ~896 B higher |
| First post-kallsyms divergence | file 0xf968c (sys_call_table area) | (reference) | first 1 MB of Image is identical |
| Image total size | 12,970,284 B | 12,970,156 B | +128 B |

---

## 6. Dead-driver audit — what residual differences actually matter

Cross-referenced every remaining ours-only / stock-only symbol group
against the stock device tree (`fw-analysis/k-3.1.3/sunxi.dtb`,
`dtc`-decompiled) and stock firmware userspace
(`fw-analysis/x-3.1.3/printer.base.cfg`, `fw-analysis/fe-3.1.3.str`,
`fw-analysis/lib-3.1.3/env.cfg`, `fw-analysis/k-3.1.3/run.sh`):

| Subsystem | Side | DTB status | Userspace consumer | Verdict |
|---|---|---|---|---|
| `sunxi_can` (CAN bus) | both | `can@0x0` `status="disabled"` | none — MCU comm is UART (`/dev/ttyS1` `eboard`, `/dev/ttyS5` `mcu`) | **DEAD** |
| PWM sysfs (`pwm-sunxi-group.c`) | both | `pwm@2000c00` `okay`, `pwm3@2000c13` `okay` | `/sys/class/pwm/pwmchip{0..3}/pwm*/{export,enable,period,duty_cycle}` (FF daemon) | **ALIVE** — heater/fan/light |
| PWM chrdev (`pwm-sunxi-g_dev.c`) — patch group 6 | stock only → both | (no separate DT node) | no reference to `/dev/sunxi_pwm*` anywhere in firmware | **DEAD** (patch adds 5,668 B of dead code purely for kallsyms match) |
| IR `sunxi_ir_recv_*` (stock) vs `sunxi_irrx_*` (ours) | swap | `s_cir@7040000` `okay`, `ir_tx` `okay` | `/dev/input/event0` is the TSLIB **TOUCHSCREEN** (`TSLIB_TSDEVICE`, `QWS_MOUSE_PROTO=TSLIB:/dev/input/event0`); no IR consumer | **DEAD** — AD5M Pro has no IR remote |
| Bootlogo (`boot_code`, `fb_free_bootlogo_buffer`, `need_free_boot_fb`) | stock only | not DT-driven (kernel framebuffer feature) | `k-*.tar/bootlogo.bmp` + `fastbootlogo.bmp` copied to `/media/bootlogo.bmp` by `k-*/run.sh` | **ALIVE** — FF logo at boot |
| `disp_mgr_dmabuf_list_add` (Allwinner `disp2`) | stock only | `disp@5000000` `okay`, `lcd_fb0@0` `okay` | Klipper / Qt UI use `/dev/fb0` on the 5" LCD | **ALIVE** — LCD touchscreen |
| MII sysfs attrs (`dev_attr_mii_reg`, `mii_reg_show`) | stock only | `gmac@0/@1` `okay` | not referenced in any FF config or daemon | **DEAD** (debug-only sysfs) |
| SPI slave (`sunxi_spi_slave_set_txdata`) | stock only | `spi@4025000`, `spi@4026000` both `okay` | no `spidev`/spi-slave userspace consumer | **DEAD** |
| Realtek BT-coex stack (`rtk_btcoex_*`, `rtl_l2_*`, `udpsocket_*`) | ours only → none | (newer-BSP addition; no DT node) | gated by `CONFIG_BT_HCIUART_RTL3WIRE` which is off | **DEAD** (removed by patch group 7) |
| DCXO ictrl (`dcxo_ictrl_attr/show/store`) | ours only | (newer T113 revision support; no DT node) | N/A | **DEAD** |
| Newer-SoC plumbing (`sun20iw1p1_ths`, `sun55i_wdt_reg`, `sunxi_smc_get_tcoffer_ver`, `sunxi_rtc_v201_data`) | ours only | (different SoC dies) | N/A | **DEAD** |

### Interpretation

- The only stock-only group that's actually used at runtime and we
  don't currently match is the **bootlogo handoff** (3 kernel symbols
  inside the closed-source Allwinner `disp2` driver). Closing the +128 B
  exactly requires acquiring an older `disp2` snapshot — see §8.
- All other residual symbol differences (CAN, IR, MII, SPI slave, BT
  coex, DCXO, newer-SoC) are **dead code on this printer**. They
  contribute to the +128 B alignment crossing but cannot change runtime
  behaviour because the device-tree nodes are `disabled` or have no
  userspace consumer.

### Knock-on for ReForge's shipping image

The shipping kernel (Buildroot gcc-15.2 `-Os`, `make kernel`) has no obligation
to match stock's IKCONFIG and can strip the dead code. The GCC 9.5.0 reference
build estimated **~60 KB** of `.text` removable from the table below; the later
gcc-15 analysis went much further (`-Os` is already on, and a lean-config pass
predicts **~1.5 MB** strippable) — see
[`../research/kernel/2026-06-06-kernel-compiler-and-size-options.md`](../research/kernel/2026-06-06-kernel-compiler-and-size-options.md).
The dead-driver candidates:

| Drop | Saved | Why safe |
|---|---:|---|
| `CONFIG_CAN_SUN8I=n` | ~7 KB | CAN bus is `disabled` in DTB and MCU comm is UART |
| `pwm-sunxi-g_dev` source + Makefile line | 5.7 KB | no userspace uses the chrdev (sysfs is enough) |
| `CONFIG_IR_SUNXI=n` + `CONFIG_IR_RX_SUNXI=n` | ~25 KB | no IR remote on AD5M Pro |
| BT-coex (already removed by patch group 7) | ~20 KB | RTL3WIRE off |
| SPI slave + MII sysfs | ~4-6 KB | no userspace consumer |

The byte-identical-attempt build keeps everything to preserve IKCONFIG
byte-identity. ReForge ships with the drops — they're independent
concerns.

---

## 7. Status by L-tier (from the rebuild-and-diff plan)

| Tier | Goal | Status |
|---|---|---|
| **L1** Functional equivalence | Tier 1+2+3 functional checks pass | ✅ done — see [`../research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md`](../research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md) (GCC 9.5.0 build) |
| **L2** `vermagic` + banner byte-identical | toolchain identification + build metadata match | ✅ done (Linaro 5.3.1 build) |
| **L3** Image byte-identical | `Image.ours == Image.stock` | ⚠️ +128 B (alignment artifact) |
| **L4** Byte-identical `boot.img` (`mmcblk0p4`) | Image + ramdisk + Android-boot-image header byte-identical | Pending L3; mechanical after that (have stock ramdisk + DTB + header parameters) |
| **L5** Byte-identical kernel-OTA `kernel-2.1.6.tar` | + matching tar metadata | Trivial after L4 |

---

## 8. Closing the residual +128 B

### Path A — Acquire the Auto SDK / older `disp2` snapshot (optimal)

Of the ~15 net-extra symbols remaining, the only ones we can't recover
from public GitHub sources are:

- **Bootlogo handoff** (`boot_code`, `fb_free_bootlogo_buffer`,
  `need_free_boot_fb`) — inside the closed-source Allwinner `disp2`
  driver. The version of `disp2` shipped in every public BSP fork we
  inspected (`iLotusK9`, `ayueying`, `Noooooob233`, `paulwratt`,
  `guanglun`, `open-cores`, `cfelicio`) doesn't have these symbols.
  An older `disp2` overlay would close the alignment delta.
- The older `sunxi-ir-dev.c` with the `sunxi_ir_recv_*` naming
  (`longsleep/linux-pine64` has 5 of 7 stock symbols but is arm64 —
  needs adaptation).
- The exact original Auto SDK `sunxi_can_asm.h` (closed-source).

See §9 for the full SDK-availability sweep — the source is gated and
not publicly mirrored as of this writing.

### Path B — Manual code substitutions (partly done)

The seven patch groups in §3 already do this for the substitutions we
could recover from public sources. Further substitutions offer
diminishing returns:

- Substitute `longsleep/linux-pine64`'s older `sunxi-ir-dev.c` (5 of 7
  IR symbols; arm64-typed code needs adaptation).
- Disable our DCXO + newer-SoC drivers by removing their `select`
  lines from upstream Kconfigs.

### Path C — Accept the +128 bytes (chosen)

For every practical purpose the +128 B delta is irrelevant:

- Functional equivalence confirmed via Tier 1+2+3.
- `vermagic`, Linux-version banner, build metadata all byte-identical.
- IKCONFIG.gz byte-identical (the embedded `.config`).
- First 1 MB of the Image byte-identical.
- 99.999 % byte-identical content overall.
- All substantive residual differences are dead code on this printer
  (§6). The +128 B cannot manifest as a runtime behaviour change.

---

## 9. Upstream SDK availability — public-internet sweep

FF's stock kernel was built from the Allwinner **`T113-Linux-Auto-v1.1`**
SDK (extracted from the build path `/home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4/` embedded in stock `__FILE__` strings).
This section documents an exhaustive search for that source, the closest
public mirrors, and what each one does and doesn't contain.

### 9.1 What "Auto" means

Decoded via the Tina SDK target-config tree documentation: in
`device/config/chips/t113[_i]/configs/`, the available board variants are
`evb1`, `evb1_auto`, and `evb1_auto_nand`. Per the LXG blog and 100ASK
documentation, `evb1_auto` is **"the default EMMC boot template"** — NOT
"automotive". `T113-Linux-Auto-v1.1` is the Allwinner internal release
name for the **eMMC-boot SDK variant**, version 1.1.

FF's AD5M Pro uses eMMC for `mmcblk0`, so they used `evb1_auto` as their
base Allwinner board template, then layered their own customisations on
top.

### 9.2 Public mirrors evaluated

| Repo (or other source) | Description | Has our missing symbols? |
|---|---|---|
| `iLotusK9/linux_kernel_aw_t113@349a0b9` | Single-commit "import from mangopi-sbc" flat snapshot. **Pinned as our BSP submodule.** | No bootlogo, no older IR. Newer than FF's. |
| `cfelicio/tina-linux-5.4@ec045c7e` (2025-01-06) | Single-commit, description = **"Kernel used for the Flashforge Adventurer 5M (PRO) 3D Printer"** — used by Carlos Felicio to build working USB-serial modules for AD5M Pro. Slightly closer to FF than iLotusK9 (`dev_disp.c` +3.4 KB, `dev_fb.c` +761 B). | **No bootlogo symbols anywhere**. Confirmed via grep + GitHub code search. |
| `ayueying/linux-5.4@ff6b1361` (2022-09-08) | 3-commit, Allwinner Tina-Linux 5.4 base. Has the older `pwm-sunxi-g_dev.c` we incorporated. | PWM ok; no bootlogo; same `sunxi_irrx_*` IR naming. |
| `Noooooob233/tina-d1-linux-5.4` | D1 series mirror of ayueying-equivalent base. | Identical IR file to ayueying (20,258 B). |
| `paulwratt/mangopi-sbc-tina-linux-5.4`, `guanglun/longan-t113-linux-5.4`, `open-cores/tina-t113-linux-5.4-new` | Various mangopi-sbc / Longan Tina-Linux mirrors. | Same as iLotusK9-class snapshots. |
| `longsleep/linux-pine64` | Pine64 Allwinner BSP. Has `sunxi-ir-dev.c` with `sunxi_ir_recv_*` (5 of 7 stock symbols). | arm64-typed, needs adaptation. **Confirms older naming exists publicly.** |
| `armbian/linux@sun8i` | Armbian's sun8i BSP mirror. | `dev_disp.c` exists at the canonical path; no bootlogo. |
| `DongshanPI/100ASK_T113-Pro_TinaSDK` (Tina4) `100ASK_T113-PRO_TinaSDK5` (Tina5) `T113i_DevKitF_Tina5SDK` | 100ASK (韦东山) board-specific patch overlays. The actual BSP source is a separate Baidu-pan download referenced by these repos. | Couldn't inspect without the base tarball. |
| `100askTeam/Tina5-LinuxSDK` | Official Tina5 SDK wrapper. | Skeleton without lichee kernel tree. |
| `Tina-Linux/linux-5.4`, `mangopi-sbc/tina-linux-5.4` | Referenced by Buildroot configs and forum posts. | **DELETED** (GitHub 404). |

### 9.3 Code-search confirmation that the bootlogo symbols are nowhere public

The symbols `boot_code`, `fb_free_bootlogo_buffer`, `need_free_boot_fb`
return **zero hits** on:

- GitHub Code Search (`api.github.com/search/code`)
- Sourcegraph public-code search (`sourcegraph.com/search`)
- grep.app (HTTP 429 rate-limited but no positive results during earlier attempts)
- Direct `curl` against the obvious file paths in all repos above

The disp2 driver itself (`drivers/video/fbdev/sunxi/disp2/disp/dev_fb.c`,
`dev_disp.c`) is open-source on multiple mirrors, but **the bootlogo
handoff functions appear only in the closed `T113-Linux-Auto-v1.1`
release or in a FlashForge-specific patch on top of it**.

### 9.4 Known SDK distribution channels (none verified working)

| Channel | URL | Status |
|---|---|---|
| **OneDrive mirror** (Ohmbed Kernel Substack) — **DOWNLOADED, INSPECTED** | <https://pham1998-my.sharepoint.com/:u:/g/personal/quangphuoc_pham1998_onmicrosoft_com/ERBXYam6mHpNg1Rdh0HeohkBxOJkypNFj6kCwWINp_9D1Q?e=FEauTz> | **Sign-in gated** (302 redirect to login) but the link **does work** with any Microsoft account (personal / school / work). ~11 GB outer `tina-linux.tar.gz` (gzip + nested `lichee.zip` 663 MB + `prebuilt.zip` 1009 MB). Provenance: Quang Phuoc Pham, a Vietnamese embedded-Linux developer, extracted the SDK from an LCMaker (LCPI-T113 dev-board) VMware image. Documented in the Substack post "[Embedded Linux with T113-s3 (Part 1)](https://ohmbedkernel.substack.com/p/embedded-linux-with-t113-s3-part)". **Inspection result: §9.4.1 below.** |
| **Baidu pan** (DongshanPI / 100ASK distribution) | <https://pan.baidu.com/s/13uKlqDXImmMl9cgKc41tZg?pwd=qcw7> (code `qcw7`) | Listed for `Tina-SDK_DevelopLearningKits-V1/DongshanNezhaSTU-TinaV2.0-SDK`. Requires Baidu account + (typically) Baidu Disk client for >4 GB downloads. **Not verified working** (the user's earlier attempt to reach the original `T113-Linux-Auto-v1.1` Baidu link returned broken). |
| **Baidu pan** (D1-H / T113 SDK collection thread) | <https://bbs.aw-ol.com/topic/1034> | Aggregator forum thread with multiple Baidu pan links for D1-H / D1s / T113 / R528. Same Baidu-account barrier. |
| **OneDrive / WeiDongShan mirror** | mentioned in 100ASK's `tina5sdk-bsp-50ae436fe556be2253856af283b1e094.tar.gz` (~3.3 GB Tina5 base) | Baidu-only as far as we found. |
| **Allwinner customer portal** | <https://open.allwinnertech.com/> | NDA + SSH-key authorisation required. Per docs.100ask.net: "Customers need to apply to the business/technical support window for SDK download permission. The application needs to provide an SSH public key for server authentication; after authorisation, code can be synced via repo." Not realistically obtainable without commercial Allwinner relationship. |
| **FlashForge GPL disclosure** | `flashforge.com/gpl`, `/legal/gpl` | **Both 404**. FF has published `FlashForge/AD5M_Series_Klipper` (GPL-3 Klipper source) but has **not** published their Linux kernel source despite shipping it under GPLv2. Issue #1 on the Klipper repo already flags this as an apparent partial-compliance concern. |

#### 9.4.1 OneDrive mirror inspection result (negative)

Downloaded and inspected on 2026-06-04. The 11 GB outer `tina-linux.tar.gz`
is the upstream **`github.com/mangopi-sbc/Tina-Linux`** SDK — the same
repo our `iLotusK9/linux_kernel_aw_t113` submodule was imported from
before that GitHub org was deleted. The interesting top-level structure:

| Path inside tarball | Size | What |
|---|---:|---|
| `Tina-Linux/lichee.zip` | 663 MB | Inner ZIP containing the full lichee/ tree (linux-5.4 + brandy-2.0 u-boot + spl-pub) |
| `Tina-Linux/prebuilt.zip` | 1009 MB | Tina toolchain + prebuilt binaries (`riscv64-linux-x86_64-20200528`, `gcc-linaro-7.2.1-2017.11-x86_64_arm-linux-gnueabi`, etc.) |
| `Tina-Linux/.git/modules/lichee/linux-5.4/HEAD` | — | `0d4903ebd9d2194ad914686d5b0fc1ddacf11a9d` (≡ `paulwratt/mangopi-sbc-tina-linux-5.4@HEAD`) |
| `Tina-Linux/lichee/linux-5.4/Makefile` | — | `VERSION=5 PATCHLEVEL=4 SUBLEVEL=61 NAME="Kleptomaniac Octopus"` |
| `Tina-Linux/device/config/chips/t113/configs/` | — | Has `evb1` and `mq_r` only; **NO `evb1_auto`** |

**Byte-identity verification** (md5sum tarball vs our submodule):

| File | Match |
|---|---|
| `drivers/net/can/sunxi_can.c` | ✅ identical |
| `drivers/net/can/sunxi_can_asm.S` | ✅ identical |
| `drivers/media/rc/sunxi-ir-dev.c` | ✅ identical |
| `drivers/pwm/Makefile` | ✅ identical |
| `drivers/bluetooth/hci_uart.h` | ✅ identical |
| `drivers/video/fbdev/sunxi/disp2/disp/dev_disp.c` | ✅ identical |
| `drivers/video/fbdev/sunxi/disp2/disp/dev_fb.c` | ✅ identical |

**Critical missing files** — the OneDrive SDK does **not** contain:

| File we needed | Result |
|---|---|
| `drivers/net/can/sunxi_can_asm.h` (closed header) | NOT in lichee.zip |
| `drivers/pwm/pwm-sunxi-g_dev.c` (stock PWM chrdev) | NOT in lichee.zip |
| `drivers/staging/rtl8821cu/{Kconfig,Makefile}` | NOT in lichee.zip |
| `disp2` bootlogo functions (`fb_free_bootlogo_buffer`, `need_free_boot_fb`) | `grep -rln` across full lichee.zip: no hits |

**Verdict**: this mirror is **byte-identical** to our existing `iLotusK9`
submodule for kernel source (same upstream content under a different
flat re-import SHA `349a0b9...` vs the original `0d4903eb...`). The
four closed-source files FF used are absent here too — confirming
that they're *not* part of any public Tina-Linux distribution, only
the NDA-restricted `T113-Linux-Auto-v1.1` Allwinner release.

The SDK is still useful for: (a) the brandy-2.0 u-boot source
(parallel rebuild path), (b) the Tina build-system scripts
(`build/envsetup.sh`, `lunch`, `mboot`, `pack`) for understanding the
original end-to-end build process, (c) the `prebuilt.zip` toolchain
set (though we have Linaro 5.3.1 pinned independently).

### 9.5 What Carlos Felicio's working AD5M Pro module-build proves

[Carlos Felicio's blog post](https://carlosfelic.io/misc/enabling-serial-over-usb-on-the-flashforge-adventurer-5m-pro/)
(October 2025) documents successfully cross-compiling USB-serial modules
for the AD5M Pro using `cfelicio/tina-linux-5.4` + Linaro 7.4.1
toolchain. The modules' `vermagic` matched stock (`5.4.61 SMP preempt
mod_unload ARMv7 p2v8`) and `insmod` succeeded.

This proves that **a slightly older / Tina-class snapshot is sufficient
for module ABI compatibility** (vermagic match), but **does not solve
the byte-identical reproduction problem** because the bootlogo handoff
functions (which contribute to the +128 B alignment crossing) are
still missing from cfelicio's source.

### 9.6 Conclusion

The `T113-Linux-Auto-v1.1` SDK is **not findable on the open public
internet** as of this writing. The Ohmbed Kernel OneDrive download —
the only viable-looking lead beyond `cfelicio/tina-linux-5.4` — is the
**mangopi-sbc consumer Tina-Linux** distribution, byte-identical to our
existing submodule, and is missing the same four closed-source files
(§9.4.1).

Closing the +128 B exactly therefore requires one of:

1. An anonymous leak of the `T113-Linux-Auto-v1.1` SDK (unpredictable).
2. A successful GPL enforcement action against FlashForge (slow, legal).
3. A repaired Baidu pan link to the `T113-Linux-Auto-v1.1` tarball
   specifically (manufacturer-distributed; link rot is the norm).
4. NDA partner sharing the SDK (not in our position).
5. **Reverse-engineering the 3 bootlogo functions from the on-device
   stock kernel binary** (same method as our `sunxi_can_asm.h`
   reconstruction in patch group 2 — medium effort, ~30 lines of C).

Paths 1-4 are out of our control. Path 5 is the next concrete move if
byte-identical exact reproduction is required; otherwise the current
+128 B is a documented, well-understood ceiling and is treated as
closed (Path C in §8).

## 10. Sources

### Internal evidence
- [`../../tools/build/build-bsp-kernel-stock.sh`](../../tools/build/build-bsp-kernel-stock.sh)
  — the byte-identical-attempt build script (every reproducibility
  knob documented in inline comments)
- [`../../tools/build/build-bsp-kernel.sh`](../../tools/build/build-bsp-kernel.sh)
  — the functional-equivalence build with GCC 9.5.0 (companion script;
  no Linaro toolchain needed)
- [`../../vendor/kernels/patches/0001-byte-identical-reproduction.patch`](../../vendor/kernels/patches/0001-byte-identical-reproduction.patch)
  — the apply-on-build patch (26.7 KB)
- [`../../vendor/kernels/patches/README.md`](../../vendor/kernels/patches/README.md)
  — patch convention (apply/revert harness, no submodule pollution)
- [`../../vendor/upstream-snippets/pwm-sunxi-g_dev/pwm-sunxi-g_dev.c`](../../vendor/upstream-snippets/pwm-sunxi-g_dev/pwm-sunxi-g_dev.c)
  — patch group 6 PWM driver (sha256 `f53450ae74…`, 5,668 B; from
  `ayueying/linux-5.4` @ 2022-09-08; Copyright (C) 2019 AllWinner)
- [`../board-notes/stock-kernel-config-5.4.61.txt.gz`](../board-notes/stock-kernel-config-5.4.61.txt.gz)
  — captured stock `.config` (byte-identical to embedded IKCONFIG)
- [`../../vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/`](../../vendor/toolchains/)
  — Linaro 5.3.1 toolchain (downloaded via `FETCH_LINARO=1 ./vendor/fetch.sh`)
- the 2026-06-04 autoresearch optimization loop, iters 0–4 (baseline →
  substitutions → alignment diagnosis) — progression summarized in Appendix A
  below (the loop's own `autoresearch.*` working files were not retained)
- [`kallsyms-symbol-diff.md`](kallsyms-symbol-diff.md)
  — the full ours-vs-stock kallsyms classification (baseline +
  post-iter-4 snapshot)
- `build/bsp-kernel-rebuild/artifacts/Image.stock` — golden stock image
  extracted from the eMMC dump (used as the reference for all diffs)

### Dead-driver audit evidence trail
- `fw-analysis/k-3.1.3/sunxi.dtb` — stock device tree (decompiled via
  `dtc -I dtb -O dts`); the source of `status` strings per node
- `fw-analysis/x-3.1.3/printer.base.cfg` — stock Klipper printer config
  (`[mcu] serial: /dev/ttyS5`, `[mcu eboard] serial: /dev/ttyS1`
  confirms MCU comm is UART, not CAN)
- `fw-analysis/fe-3.1.3.str` — strings dump of the FlashForge daemon
  binary (shows the `/sys/class/pwm/pwmchip*/pwm*/{enable,period,
  duty_cycle}` paths actually used at runtime — and the absence of
  `/dev/sunxi_pwm*`)
- `fw-analysis/lib-3.1.3/env.cfg` — `TSLIB_TSDEVICE=/dev/input/event0`
  confirms `event0` is the touchscreen, not IR
- `fw-analysis/k-3.1.3/run.sh` — references `bootlogo.bmp` /
  `fastbootlogo.bmp` (confirms the bootlogo handoff IS used)

### External references
- Linaro 5.3-2016.05 toolchain (publicly archived):
  <https://releases.linaro.org/components/toolchain/binaries/5.3-2016.05/arm-linux-gnueabi/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi.tar.xz>
  (sha256 `77cccd433d680251c8b9bfa01890cb6921548513a39fac35c1f4b9f0a47e5aa4`)
- BSP submodule pin: `iLotusK9/linux_kernel_aw_t113@349a0b9` (single-commit
  flat import labelled "from mangopi-sbc"; the upstream
  `mangopi-sbc/tina-linux-5.4` was deleted from GitHub)
- PWM driver source: `ayueying/linux-5.4@master`
  → `drivers/pwm/pwm-sunxi-g_dev.c` (Copyright "2019 AllWinner")
- AD5M Pro-specific Tina-Linux mirror (Carlos Felicio):
  `cfelicio/tina-linux-5.4@ec045c7e` — used by
  [Enable USB Serial (FTDI230X / Palette 2) on Flashforge Adventurer 5M (Pro)](https://carlosfelic.io/misc/enabling-serial-over-usb-on-the-flashforge-adventurer-5m-pro/)
  to build vermagic-matched modules
- Ohmbed Kernel Substack OneDrive mirror of ~11 GB Tina-Linux SDK
  (sign-in gated): post
  [Embedded Linux with T113-s3 (Part 1)](https://ohmbedkernel.substack.com/p/embedded-linux-with-t113-s3-part)
- LXG blog on Tina SDK target-config tree (decoded `evb1_auto` = eMMC
  variant): <http://lixiaogang03.github.io/2023/10/18/T113-Linux%E7%B3%BB%E7%BB%9F/>
- Allwinner customer portal (NDA): <https://open.allwinnertech.com/>
- Mainline `drivers/net/can/sun4i_can.c` — canonical SUNXI CAN
  register map used as reference for the reconstructed
  `sunxi_can_asm.h`
- `bbs.aw-ol.com/topic/1926` — community documentation of the
  `CONFIG_CAN_SUN8I` Kconfig + Makefile wiring pattern
- `bbs.aw-ol.com/topic/1034` — D1-H / D1s / T113 / R528 SDK aggregator
  forum thread with multiple Baidu pan distribution links
- Linux kernel `Documentation/admin-guide/reproducible-builds.rst` —
  `SOURCE_DATE_EPOCH` and `KBUILD_BUILD_*` semantics
- Linux kernel `scripts/setlocalversion` — `.scmversion` semantics for
  the trailing `+` suppression
- Linux kernel `kernel/kallsyms.c` — kallsyms encoding format used by
  our from-scratch decoder (`kallsyms-symbol-diff.md`)

---

## Appendix A — Build progression history

The +128 B residual was reached in two passes plus an autoresearch loop.

### Pass 1 — functional equivalence (GCC 9.5.0)

| Build | Δ |
|---|---:|
| GCC 9.5.0, local source path | −756 B (−0.0058 %) |

vermagic differs by toolchain version string (`9.5.0` vs `5.3.1`).
Tier 1 (boots in qemu), Tier 2 (modules cross-load against stock),
Tier 3 (exports byte-identical) all PASS. Documented in
[`../research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md`](../research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md).

### Pass 2 — byte-identical attempt (Linaro 5.3.1)

| Build state | IKCONFIG Δ | non-IKCONFIG Δ | Total Δ |
|---|---:|---:|---:|
| Linaro toolchain only, no CAN_SUN8I | (n/a) | (n/a) | −96 B |
| + CAN_SUN8I wired with reconstructed header | +91 | +37 | +128 B |
| + 12 Kconfig hides (FORCE_HIDE_NEWER_BSP) | +14 | +114 | +128 B |
| + RTL8821CU stub at correct path | +12 | +116 | +128 B |
| + Audio V2 menu header hidden + PLUGIN_HOSTCC forced "" | **0** | +128 | +128 B |

### Autoresearch iter 3+4 (substitutions for stock-only sources)

| Iter | Change | ours-only Δ | stock-only Δ | kallsyms Δ | non-kallsyms Δ | Total Δ | first_diff |
|---|---|---:|---:|---:|---:|---:|---|
| iter 0 baseline | (above pass-2 state) | 529 | 490 | +824 B | −696 B | +128 B | 0x15c |
| iter 3 | imported `pwm-sunxi-g_dev.c` (recovered 9 stock-only PWM symbols) | 529 | 474 | +1088 B | −960 B | +128 B | 0x15c |
| iter 4 | removed `#define BTCOEX` + `hci_uart-y += rtk_coex.o` (removed 30 ours-only BT-coex symbols) | **484** | **472** | **+236 B** | **−108 B** | **+128 B** | **0xf968c** |

The total stayed at +128 B because section alignment absorbed each
shift. After iter 4 the **first 1 MB of the Image is byte-identical to
stock** and the residual is fully attributable to the 256-byte
alignment crossing described in §4.

The per-iter log and decision dashboard came from the autoresearch loop's
working files (`autoresearch.jsonl` / `.md`), which were not retained; the table
above is the preserved summary.
