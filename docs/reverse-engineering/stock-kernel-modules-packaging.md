# Stock kernel-module packaging on the AD5M Pro

**Date:** 2026-06-04
**Status:** reverse-engineering finding (host-only analysis of factory rootfs
+ OTA + golden eMMC dump). Informs how ReForge ships its own modules.
**See also:**
[`../board-notes/README.md`](../board-notes/README.md) (hardware inventory,
loaded module list), [`../boot.md`](../boot.md) §4 (the `auto_run.sh`
USB-update + WiFi-insmod path),
[`../research/2026-06-04-bsp-kernel-rebuild-findings.md`](../research/2026-06-04-bsp-kernel-rebuild-findings.md)
(why the rebuilt kernel reproduces stock's vermagic byte-for-byte).

---

## TL;DR

- Stock builds **every** kernel module in-tree (`make modules`) and installs
  them at the standard kbuild location `/lib/modules/5.4.61/`, complete with
  `depmod` output (`modules.dep`, `modules.alias`, `modules.symbols`, etc.).
- **On top of that, FF keeps a flat copy of `8821cu.ko`** at
  `/lib/modules/8821cu.ko`. This is **deliberate channel separation, not
  redundancy** — see §8. The standard tree is the factory snapshot for
  hotplug-loadable hardware (cameras, touchscreen, alt WiFi chips, etc.,
  loaded by the kernel's own `request_module()` path on probe events). The
  flat copy is the **single fixed path the kernel OTA owns** — it's the only
  driver FF needs to be able to update without rebuilding the rootfs or
  re-running depmod, so they carve out one slot for it.
- Stock loads the WiFi driver via **explicit `insmod` from `auto_run.sh`**
  against the flat path. If it loaded the standard-path copy instead, OTA
  WiFi-driver updates would be invisible — the device would run the
  factory-original 8821cu forever, defeating the entire OTA mechanism.
- The OTA kernel-update tarball ships **only the flat copy** and only
  refreshes the flat copy at install time. The standard-path 8821cu is
  factory inventory — the OTA never touches it.
- The two copies are bit-equivalent in code/data/`.modinfo`/`.symtab` (same
  Realtek source `v5.12.0-16-g5229e7f95`, same `srcversion`, same
  `vermagic`); they **differ only in retained `.debug_*` DWARF sections**
  (~36 KB). The flat copy keeps DWARF; the standard copy was stripped.
- **The driver itself is vanilla Realtek with zero FF patches** — see §11.
  No `flashforge_*`/`ad5m_*`/`ff_*` strings or symbols, standard Realtek
  source layout (`drivers/staging/rtl8821cu/{core,hal,os_dep,...}`), only
  3 Allwinner-Auto-SDK build-integration deltas (Kconfig wiring, Makefile
  wiring, `MODULE_IMPORT_NS` pragma to satisfy the kernel's namespace check
  for `vfs_getattr`). Same upstream lineage as the community fork
  `morrownr/8821cu-20210916`.
- The debug-info retention is **not** for runtime gdb/kgdb (neither is built
  in or shipped in userland) and **not** for off-device panic-backtrace
  decoding either: the retained DWARF covers **only** `8821cu.mod.c` (the
  modpost-generated wrapper, which has zero executable code — `debug_aranges`
  is literally empty), so `addr2line` returns `?` for the line number on
  every real driver function. The 36 KB is **inert ELF section overhead**:
  build-pipeline residue from the kernel's `CONFIG_DEBUG_INFO=y` compiling
  the wrapper with `-g`, while the actual Realtek driver `.c` files arrived
  pre-stripped from Realtek and never had source-line DWARF in the first
  place. The flat-copy install path skipped `strip --strip-debug` and so
  preserved a DWARF that points nowhere useful.

## 1. The two-path layout — what's on the rootfs

**Why two copies at all?** Short answer: deliberate channel separation —
the standard tree is **factory inventory** for hotplug-loadable hardware
(cameras, touchscreen, alt WiFi chips, etc., loaded by the kernel's own
`request_module()` path), and the flat copy is the **OTA-controllable
single point** for the one driver FF needs to update without rebuilding
the rootfs or running depmod. See §8 for the design rationale; this
section just lays out what's on disk.


From the factory rootfs (`tools/recovery/archive/Adventurer5M-factory.tar.xz`),
extracted with `tar -tJf`:

```
lib/modules/                                         ← flat path
├── 8821cu.ko                                       (2,441,368 B, with .debug_*)
└── 5.4.61/                                          ← standard kbuild layout
    ├── 8821cu.ko                                   (2,405,168 B, stripped)
    ├── modules.dep / modules.dep.bin               (depmod output)
    ├── modules.alias / modules.alias.bin           (MODALIAS → name index)
    ├── modules.symbols / modules.symbols.bin
    ├── modules.devname
    ├── modules.order
    ├── modules.builtin / modules.builtin.bin
    ├── modules.softdep
    ├── Module.symvers                              (CRCs for symbol versioning)
    │
    ├── xr829.ko                                    (602 KB, with .debug_*)
    ├── xr829_wep.ko                                (780 KB, stripped)
    ├── xr819s.ko                                   (546 KB, stripped)
    ├── xradio_btlpm.ko                             ( 22 KB, stripped)
    │
    ├── gc030a_mipi.ko / gc0310_mipi.ko / gc2385_mipi.ko / gc5025_mipi.ko
    ├── imx278_mipi.ko / imx278_2lane_mipi.ko / imx386_mipi.ko / imx386_2lane_mipi.ko
    ├── ov2680_mipi.ko / ov5640.ko / ov8858_r2a_4lane.ko
    ├── c2590_mipi.ko / sp5409_mipi.ko / nvp6158.ko    (all stripped)
    │
    ├── gt9xxnew_ts.ko                              (Goodix touchscreen, stripped)
    ├── md5.ko / sha1_generic.ko                    (crypto, stripped)
    ├── sunxi-ce.ko                                 (Allwinner Crypto Engine, stripped)
    └── vf-test.ko                                  (Allwinner test, stripped)
```

The standard `5.4.61/` layout is a complete kbuild `make modules_install`
output. The flat `/lib/modules/8821cu.ko` sits on top.

## 2. The two `8821cu.ko` copies — byte-level diff

| Property | `/lib/modules/8821cu.ko` (flat) | `/lib/modules/5.4.61/8821cu.ko` (standard) |
|---|---|---|
| Size | 2,441,368 B | 2,405,168 B (−36,200 B) |
| MD5 | `609e66d877c7bdb89e9bc826fea42c59` | `9eef6f1a1af4a9f6bea5488320350749` |
| Build-ID | `1b43ea87f9b4edd2fd9b48de9c8050a0013855ba` | `f7c284a28abb198174b3a16157d2c3ce0f10869c` |
| ELF sections | 48 | 41 (= 48 − 7 debug sections) |
| `.text` size | `0x11ec74` (1,174,132 B) | `0x11ec74` — **identical** |
| `.data` size | `0x375f0` | `0x375f0` — **identical** |
| `.rodata` size | `0x191ac` | `0x191ac` — **identical** |
| `.modinfo` size | `0x23fa` | `0x23fa` — **identical** |
| `__param` size | `0x974` | `0x974` — **identical** |
| `.debug_info` | present | **absent** |
| `.debug_abbrev` | present | **absent** |
| `.debug_aranges` | present | **absent** |
| `.debug_line` | present | **absent** |
| `.debug_str` | present | **absent** |
| `.rel.debug_*` (relocations) | present | **absent** |

All shared modinfo fields match exactly: `version`, `srcversion`, `vermagic`,
`license`, `author`, `intree:Y`, `staging:Y`, `import_ns` (×2). They are
**bit-equivalent in code, data, and metadata**; the only delta is debug-info
presence and the build-ID that comes with it.

## 3. The OTA refresh path — only the flat copy is touched

From the stock 3.1.3 OTA tarball (`fw-analysis/pro-3.1.3.tgz`, the
kernel-update component `k-3.1.3/`), the install script `run.sh` shows:

```sh
# upgrade 8821cu (flat-path install — no uname -r in the target)
if [ -f $WORK_DIR/$WIFI_DRIVER ]; then
    echo "update 8821cu.ko"
    cp_file $WORK_DIR/$WIFI_DRIVER /lib/modules/8821cu.ko
    sync
    sleep 1
fi
```

And the OTA-shipped `k-3.1.3/8821cu.ko` MD5 = `609e66d877…` — **byte-identical
to the flat copy on disk**. So OTAs roll forward the flat copy and never
touch `/lib/modules/5.4.61/`. The standard-path copy never changes from its
factory state.

## 4. The runtime loader — `auto_run.sh` against the flat path

Per [`../boot.md`](../boot.md) §4, the stock `/opt/auto_run.sh` runs at
`rcS:50` and includes:

```sh
insmod /lib/modules/8821cu.ko
sleep 2
```

i.e. it `insmod`s the **flat copy** explicitly, by absolute path. It does
**not** use `modprobe` (which would consult `modules.dep` / `modules.alias`
and load from `/lib/modules/5.4.61/...`).

## 5. The DWARF — what's actually in the debug info (spoiler: nothing useful)

DWARF analysis of the flat `8821cu.ko`:

| Field | Value |
|---|---|
| Compilation units | **1** (exactly one `DW_TAG_compile_unit` in the whole `.debug_info` section) |
| Source file | `drivers/staging/rtl8821cu/8821cu.mod.c` (the **modpost wrapper**) |
| Compiler producer | `GNU C89 5.3.1 20160412 -mlittle-endian -mabi=aapcs-linux -mfpu=vfp -marm -march=armv7-a -mfloat-abi=soft -mtune=cortex-a9 -mtls-dialect=gnu -g -Os -std=gnu90 ...` |
| `DW_AT_comp_dir` | `/home/linux/work/hard_t113/T113-Linux-Auto-v1.1/out/kernel/build` |
| **`debug_aranges` content** | **empty** — raw bytes are a 20-byte header + the terminator (`00 00 00 00 00 00 00 00`); **zero address ranges**, i.e. the DWARF declares it covers **no executable code at all** |
| **`debug_line` files** | **only `int-ll64.h`** (a kernel header of type aliases like `typedef __u8 = unsigned char`) — no `.c` source file appears |

The DWARF covers **only `8821cu.mod.c`** — the file that `scripts/Makefile.modpost`
auto-generates AFTER the main driver build, to emit:

- `MODULE_INFO(intree, "Y")`, `MODULE_INFO(staging, "Y")`, `MODULE_INFO(vermagic, "...")`
- `MODULE_LICENSE("GPL")`, `MODULE_AUTHOR(...)`, `MODULE_DESCRIPTION(...)`
- `MODULE_ALIAS(...)` × N (one per USB device ID the driver supports)
- `__module_init` / `__module_exit` linkage
- `__ksymtab_*` / `__kcrctab_*` entries for any `EXPORT_SYMBOL` in the module
- Per-arch `.modinfo` blob

Type information in the DWARF is the kernel's standard primitives only
(`__u8`, `__s32`, `long unsigned int`, etc.) — exactly what `.mod.c` needs to
reference. **No driver function symbols, no source-line tables for
`rtw_cmd.c` / `rtw_io.c` / etc.** appear in the DWARF.

Same story for `xr829.ko`: DWARF has 1 CU, source = `…/auto/kernel/xr829/xr829.mod.c`.

### Empirical proof: `addr2line` cannot resolve a single line

Taking the very first real driver function in the `.symtab` and asking
`addr2line` to resolve it:

```
$ arm-linux-gnueabi-addr2line -e 8821cu.ko -fp 0x00000008
rtw_mp_cmd_hdl at rtw_cmd.c:?
```

The **function name** comes from `.symtab` (which both copies preserve — that's
what keeps `file` reporting both as "not stripped"). The **`.c` filename** comes
from the `FILE` symbol that the linker preserves in `.symtab` from each `.o`.
But the **source line is `?`** — there is no `.debug_line` entry for *any* `.c`
source file in the entire DWARF. Every real driver function decodes to
`?` for the line number.

**Conclusion:** the flat copy isn't "shipping debug info" in any actionable
sense. It's shipping 36 KB of inert ELF sections that describe one wrapper
file which itself has zero executable code (`debug_aranges` is literally
empty). It can't be used for gdb-stepping anything, it can't decode panic
backtraces to source lines, it can't be consumed by `crash` or any kernel
debugger. The 36 KB is dead bytes — vestigial DWARF that survived the
flat-copy install path because nothing in that path runs `strip --strip-debug`.
For anything an off-device engineer might *actually* want from a crash log
(function name + offset → source line), the bare `.symtab` already does as
much as the bare `.ko` allows, because the real driver `.c` files have no
`.debug_*` either way.

## 6. The "T113-Linux-Auto-v1.1" SDK hint

The `comp_dir` path reveals the build environment FF used:

```
/home/linux/work/hard_t113/T113-Linux-Auto-v1.1/out/kernel/build
└─ user: linux
└─ workspace: hard_t113
└─ SDK: T113-Linux-Auto-v1.1     ← Allwinner's "T113 Linux Automotive SDK" v1.1
└─ build dir: out/kernel/build
```

"T113-Linux-Auto" is the Allwinner-internal name for the T113 platform's
"Auto" (automotive) Tina derivative — a Tina SDK variant tuned for in-vehicle
infotainment / automotive Linux use cases. It carries the same kernel base
(`iLotusK9/linux_kernel_aw_t113`-equivalent BSP) plus an "Auto" overlay that
adds the `drivers/staging/rtl8821cu/` source tree and friends (`platform/framework/auto/kernel/xr829/` etc., as seen in the `xr829.ko` `comp_dir`).

This SDK is **not** the public DongshanPI/100ASK Tina4/Tina5 SDKs — those are
"general embedded Linux" variants. T113-Linux-Auto-v1.1 is a separate
Allwinner-distributed package, typically available only to commercial T113
licensees. FF presumably licensed it (or obtained it through their OEM
chain).

## 7. Why is the flat copy NOT stripped? (And why it doesn't matter)

Stock kernel `.config` shows (from `docs/board-notes/stock-kernel-config-5.4.61.txt.gz`):

```
CONFIG_DEBUG_INFO=y             ← every .o + .mod.c compiled with -g
CONFIG_DEBUG_KERNEL=y           ← debug subsystem enabled
CONFIG_KALLSYMS_ALL=y           ← all symbols in kallsyms (not just exports)
CONFIG_MAGIC_SYSRQ=y            ← SysRq enabled
CONFIG_MAGIC_SYSRQ_SERIAL=y     ← SysRq over serial console
CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x1
CONFIG_UNWINDER_ARM=y           ← ARM stack unwinder
# CONFIG_KGDB is not set        ← no in-kernel debugger
# CONFIG_KDB is not set         ← no kdb shell
```

And the factory rootfs has **no** `gdb` / `gdbserver` / `addr2line` /
`crash` / `kgdb`-helper binaries (verified by `tar -tJf … | grep -iE …`).

The chain that produces the flat copy's retained-but-useless DWARF:

1. **`CONFIG_DEBUG_INFO=y` in the kernel config** tells `make modules` to add
   `-g` to every CFLAGS invocation, including the one that compiles the
   modpost-generated `8821cu.mod.c` into `8821cu.mod.o`.

2. **The Realtek driver's `.c` files arrive pre-stripped.** Realtek's vendor
   delivery to Allwinner (or to FF) ships `rtw_*.c` + headers + a Makefile.
   The Realtek-provided Makefile strips `-g` from the driver-source CFLAGS
   before any kernel-side build sees them (standard Realtek practice — they
   don't want integrators to have source-line debug info on their
   proprietary-but-GPL driver internals). So `rtw_cmd.o`, `rtw_io.o`, etc.
   land in the kernel build with **zero** `.debug_*` sections from the start.

3. **`8821cu.mod.c` is generated AFTER the driver-source compile**, by the
   kernel's standard `scripts/Makefile.modpost`. The kernel build compiles
   it with the kernel's own CFLAGS (`-g` included per
   `CONFIG_DEBUG_INFO=y`). So `8821cu.mod.o` gets ~36 KB of DWARF — but it's
   debug info for the wrapper, not the real driver, and `debug_aranges`
   confirms it covers **zero** address ranges of executable code.

4. **Final link**: `8821cu.ko` = `rtw_*.o` (no debug, Realtek-stripped) +
   `8821cu.mod.o` (debug, kernel-built). Net result — the linked `.ko` has
   `.debug_*` sections that describe nothing executable.

5. **`make modules_install` runs `strip --strip-debug`.** Tina SDK's
   `envsetup.sh` exports `INSTALL_MOD_STRIP=1` (or similar), so
   `Makefile.modinst` runs the toolchain's `strip --strip-debug` on each
   `.ko` before placing it under `/lib/modules/5.4.61/`. That's why 23 of 25
   modules on the rootfs are debug-stripped at the standard path.

6. **The flat-copy install path bypasses strip.** Somewhere in FF's
   image-assembly pipeline (or in the Auto SDK's packaging step) there's a
   `cp build/output/8821cu.ko /lib/modules/8821cu.ko` that happens **before**
   the strip-on-install runs. So the flat copy retains the wrapper's
   harmless DWARF.

7. **`xr829.ko` retains DWARF in `5.4.61/` for the same reason.** The Auto
   SDK's xr829 module lives at `platform/framework/auto/kernel/xr829/` (per
   its DWARF `comp_dir`), built as an out-of-tree module (`M=…`) rather than
   in-tree. Out-of-tree builds use a different install path that doesn't
   honor `INSTALL_MOD_STRIP` — so the unstripped `.ko` lands directly in
   `/lib/modules/5.4.61/`. (Consistent with `xr829_wep.ko` and `xr819s.ko`,
   also xr829-family but built via different paths, being correctly stripped.)

### Why no one cleaned it up

No functional or diagnostic reason. The 36 KB is:

- **Invisible to runtime** — the kernel doesn't read `.debug_*` from
  modules; `insmod` only allocates the `SHF_ALLOC` sections (`.text`,
  `.data`, `.rodata`, etc.), so DWARF sections occupy zero in-memory bytes.
- **Invisible to anyone not running `readelf`** — normal users see a 2.4 MB
  WiFi driver vs a 2.4 MB WiFi driver. No symptom triggers investigation.
- **No security exposure** — nothing in the DWARF reveals more than the
  `.symtab` already does (`.symtab` carries the same `FILE` and `FUNC`
  entries).
- **1.5 % of the `.ko` size** — not enough to trigger any size budget.
- **No actionable debug value** — even an FF engineer with the panic
  backtrace + the `.ko` + `addr2line` on a workstation gets
  `rtw_mp_cmd_hdl at rtw_cmd.c:?` (function name from `.symtab`, line `?`
  because Realtek pre-stripped the driver-source DWARF). The retained
  wrapper DWARF adds nothing to what `.symtab` already provides.

So "why ship debug symbols?" reframes as "why didn't anyone notice that one
specific cp-path in the image builder skipped the strip step?" The honest
answer is: **because it doesn't matter**. The bytes are inert, the
diagnostic value is zero, and the size overhead is negligible. The flat
copy's vestigial DWARF is a build-pipeline curiosity, not a feature.

## 8. Why have two copies of `8821cu.ko` at all? — the channel-separation design

The DWARF question is one mystery; the bigger one is: "why does FF maintain a
second copy of `8821cu.ko` at the flat path when `make modules_install`
already put it at the standard path?" The answer isn't accident — it's a
deliberate **OTA channel design** that becomes obvious once you walk through
the constraints.

### The constraint

Months after release, FF wants to push a WiFi-driver bug fix via OTA —
*without* rebuilding the rootfs (which is what the `software-*.tar.xz` OTA
does, slow and rare) and *without* shipping a whole new kernel (which is what
the `kernel-*.tar.xz` does for major kernel updates). They want a fast,
targeted, single-`.ko` refresh path.

### Why option A (update the standard path) doesn't work

If the OTA installer wrote to `/lib/modules/5.4.61/8821cu.ko`:

1. **Path requires `uname -r`.** Either hard-code `5.4.61` (fragile across
   kernel updates) or compute it at install time. Either way, more
   script complexity than a fixed flat path. With `5.4.61` hard-coded
   today, a future Plan-5-style kernel bump silently misses the new path.

2. **`modules.dep` needs `depmod -a 5.4.61` after the cp.** And the rootfs
   doesn't ship `depmod` (verified: `tar -tJf factory.tar.xz | grep -i depmod`
   returns empty). Updating the `.ko` without rebuilding `modules.dep` leaves
   `modprobe 8821cu` resolving against a stale dependency tree.

3. **It wouldn't actually load the new driver.** Nothing on the device
   `modprobe`s 8821cu. There's no udev rule firing on `MODALIAS`, no init
   script reading `modules.dep`, no kernel `request_module("8821cu")` call.
   The driver is loaded **only** by the explicit `insmod` in `auto_run.sh`
   — and that `insmod` reads a literal path. Whatever path that literal
   names is the one that actually matters; everything else is dead inventory.

### Why option B (the flat path) works

```
OTA install:       cp_file $WIFI_DRIVER /lib/modules/8821cu.ko   # one line, no uname -r
Runtime loader:    insmod /lib/modules/8821cu.ko                  # same path, every boot
```

Idempotent, version-independent, depmod-independent. The OTA owns one path;
the loader reads that same path. Update flows end-to-end with no
moving parts.

### So why ALSO ship the standard tree at factory time?

Three reasons, weakest → strongest:

1. **Side-effect of `make modules_install`.** The Tina SDK's image-builder
   runs `make modules_install` by default. The standard tree appears
   automatically. Excluding it would require an explicit `rm -rf` in FF's
   image-assembly step.

2. **The other 23 modules in the tree ARE used.** The standard tree contains
   camera sensors (`gc*_mipi.ko`, `ov*.ko`, `imx*_mipi.ko`, `nvp6158.ko`),
   the touchscreen (`gt9xxnew_ts.ko`), crypto (`sunxi-ce.ko`, `md5.ko`,
   `sha1_generic.ko`), and alternate WiFi/BT chips (`xr819s.ko`, `xr829.ko`,
   `xr829_wep.ko`, `xradio_btlpm.ko`). These load via the kernel's own
   `request_module()` path on hotplug / probe events — which **does** need
   `modules.dep` and the standard layout. (Even without udev in userspace,
   `request_module()` itself invokes `/sbin/modprobe` from the kernel side
   via `call_usermodehelper`, and busybox provides a minimal `modprobe`
   that reads `modules.dep`.) Killing the standard tree would break camera
   and touchscreen loading.

3. **8821cu is the deliberate exception.** It's the one driver that needs
   (a) load-at-boot guarantee (WiFi has to be up before Moonraker / cloud
   services), (b) a known fixed location (USB-internal, no hotplug
   variation), and (c) OTA-updatability without rebuilding the rootfs.
   So FF carves out a dedicated flat-path slot + explicit `insmod` for
   exactly this one driver. Everything else stays on the standard load path.

### Why `auto_run.sh` loads the flat one specifically

If `auto_run.sh` `insmod`'d the standard-path copy at
`/lib/modules/5.4.61/8821cu.ko`:

- OTA WiFi-driver updates would be **invisible** — nothing in the kernel-OTA
  flow ever writes to `/lib/modules/5.4.61/`.
- The device would run the **factory-original 8821cu forever**, regardless
  of how many WiFi fixes FF shipped via OTA.
- The entire OTA mechanism for WiFi-driver updates would be defeated.

By loading the flat path, `auto_run.sh` automatically picks up whatever the
latest kernel-OTA wrote. **Flat path = live channel; standard path = factory
snapshot.**

### The one-sentence summary

The two-copy layout is a **deliberate channel separation**: the standard
kbuild tree (`/lib/modules/5.4.61/`) is factory inventory for hotplug-loadable
hardware (cameras, touchscreen, alt WiFi/BT chips — all of which the kernel
loads via `request_module()` and so need `modules.dep`), and the flat copy
(`/lib/modules/8821cu.ko`) is the OTA-controllable single point for the one
driver FF wants to be able to update without rebuilding the rootfs or running
depmod. Loading from the flat path is how OTA updates actually take effect.

### Did FF ever actually use the hotfix mechanism? — No, never

Empirically verified by extracting every Pro OTA we hold (3.1.3, 5.0.3,
5.1.2, 5.1.4 — spanning ~3 years of shipped firmware) and md5-summing the
kernel-OTA payload inside each:

| OTA | tar owner | `8821cu.ko` mtime | `kernel-2.1.6.tar` payload MD5s |
|---|---|---|---|
| `pro-3.1.3.tgz` | `larry/larry` | 2023-08-01 10:24 | `8821cu.ko`=`609e66d877…`, `uImage`=`9f145b0b10…`, `sunxi.dtb`=`c4aabbae50…`, `run.sh`=`8eef8d43a0…`, `rcS`=`a25c992521…` |
| `pro-5.0.3.tgz` | `wsl/wsl` | 2025-09-28 09:47 | **all 5 MD5s identical to 3.1.3** |
| `pro-5.1.2.tgz` | `wsl/wsl` | 2025-09-28 09:47 | **all 5 MD5s identical to 3.1.3** |
| `pro-5.1.4.tgz` | `wsl/wsl` | 2026-05-09 10:08 | **all 5 MD5s identical to 3.1.3** |

And nothing WiFi-driver-related leaks into the rootfs (`software-*.tar.xz`)
or library (`library-*.tar.xz`) tarballs either — verified by
`tar -xf pro-*.tgz -O ./{software,library,control}-*.tar.xz | tar -tJ | grep -iE "8821cu|modules/|rtl8821"`
returning empty for all 12 inner tarballs across the 4 versions.

**FF built the kernel + WiFi driver exactly once in August/September 2023 and
has re-shipped that bit-identical bundle in every Pro OTA ever since.** Only
the userspace layer (`firmwareExe`, libraries) evolves — the kernel side is
frozen at 2023 levels regardless of OTA version installed.

Two telling details from the tar metadata:

1. **Tar owner switched from `larry/larry` to `wsl/wsl`** between 3.1.3 (2023)
   and 5.0.3+ (2025+). Different machine, different person.
2. **The 5.0.3 and 5.1.2 OTAs ship literally the same `kernel-2.1.6.tar`** —
   identical internal mtimes (`2025-09-28 09:47` on every entry). FF didn't
   even re-pack between those releases; they copy-pasted the bundle.

The simplest reading: **FF lost the build environment.** The original
engineer (`larry`) who knew how to drive the Tina SDK rotated off, and the
current release pipeline (`wsl/wsl`) just untar's the 2023 bundle and re-tar's
it with a fresh timestamp for each release. They couldn't rebuild the WiFi
driver from source today even if they wanted to. The hotfix-capable
infrastructure exists but has been completely dormant for the entire product
lifetime — not because it isn't needed, but because the team that could use
it no longer exists in a form that can.

#### Implications for ReForge

- **FF treats the kernel as immutable.** Our rebuilt BSP kernel hits "kernel
  parity" once (already done — see
  [`../research/2026-06-04-bsp-kernel-rebuild-findings.md`](../research/2026-06-04-bsp-kernel-rebuild-findings.md))
  and never needs to track ongoing FF changes; there aren't any.
- **The OTA infrastructure is designed for hotfixes but the firmware author
  has lost (or never had) the ability to ship them.** ReForge can credibly
  own the "actually-updateable kernel + drivers" story — with the OTA
  pipeline already documented (see [`../ota.md`](../ota.md)), a ReForge
  WiFi-driver hotfix would just be another release artifact.
- **The `wsl/wsl` provenance** suggests FF's build environment has degraded
  to "untar a long-term-stored bundle". Anything we want to verify about the
  stock firmware needs to be derived from what we have on disk (eMMC dumps,
  OTA tarballs, captured `.config`); there's no longer a live source-of-truth
  to ask FF about.

## 9. The corrected mental model for "in-tree" vs "out-of-tree"

The earlier wording in [`../board-notes/README.md`](../board-notes/README.md)
called `8821cu` "out-of-tree in the stock BSP". That's true in the
**source-origin** sense — the Realtek driver was never upstreamed to mainline
Linux. But it's misleading in the **build-integration** sense — the modinfo
explicitly says `intree: Y`, and the file lives at
`drivers/staging/rtl8821cu/` under the Auto SDK's kernel tree, built via the
kernel's own `make modules`. The precise breakdown:

| Question | Answer for `8821cu` |
|---|---|
| Origin of the source? | Realtek vendor (proprietary GPL, never upstreamed) |
| Where does the source live in the build tree? | `drivers/staging/rtl8821cu/` (in Allwinner Auto SDK overlay, not in our public BSP snapshot) |
| How is the source built? | `make modules` (in-tree). `modinfo`'s `intree: Y` confirms. |
| How is the resulting `.ko` installed? | **Two copies**: the standard kbuild path (`/lib/modules/5.4.61/8821cu.ko`, stripped) + a flat duplicate (`/lib/modules/8821cu.ko`, unstripped). |
| How is it loaded at runtime? | `auto_run.sh` runs `insmod /lib/modules/8821cu.ko` explicitly. |
| Does our rebuilt kernel reproduce it? | **No** — our BSP snapshot lacks the `drivers/staging/rtl8821cu/` source. The captured `.config` symbol `CONFIG_RTL8821CU=m` silently drops at `olddefconfig` time. |
| Will the stock `.ko` load on our rebuilt kernel? | **Yes** — `vermagic` matches byte-for-byte (`5.4.61 SMP preempt mod_unload ARMv7 p2v8`); GPL license; all referenced kernel symbols are present (verified via Tier 3 export coincidence at 99.99 %). |

## 10. What ReForge already does the same way

ReForge's own kernel modules (`modules/zram-bsp/` and `modules/f2fs-bsp/`)
follow exactly the FF flat-path + explicit-insmod pattern, for the same
reasons (no depmod runtime, no udev hotplug auto-load, predictable load
order). Concretely:

- Build: out-of-band against the BSP kernel headers (per the
  `modules/.../build.sh` scripts) → produces `dist/*.ko`
- Install: copied into ReForge's `/mod/modules/` directly — no
  `modules_install`, no `depmod`
- Load: explicit `insmod` from `S35zram` (for `zram.ko` + `zsmalloc.ko`) and
  from `packaging/live/flashforge_init.sh` (for `loop.ko` +
  `crc32_generic.ko` + `f2fs.ko`)
- Vermagic: built against the **stock 5.4.61 BSP** so the resulting `.ko`
  carries `5.4.61 SMP preempt mod_unload ARMv7 p2v8` and loads on the stock
  device unchanged

The lesson reinforces our existing design choice: we don't need depmod /
udev / modprobe for the small set of modules ReForge ships. Explicit
`insmod` at known absolute paths is more robust against partial filesystem
corruption, doesn't require maintaining `modules.dep` after OTA updates, and
matches how the stock device already works.

## 11. Is FF's `8821cu.ko` patched on top of vanilla Realtek? — No, never

The natural follow-up to "FF never uses the hotfix mechanism" (§8) is: did
FF ever do *any* customization to the WiFi driver source in the first place,
or are they shipping pure vanilla Realtek? Empirical answer from binary
inspection: **vanilla Realtek with only Allwinner-SDK build-integration
scaffolding** — zero FF-side source changes.

### What FF's binary corresponds to

From modinfo: `version: v5.12.0-16-g5229e7f95.20210118_COEX20200730-5151`. This
is the Realtek vendor release `v5.12.0` + 16 commits past it (HEAD
`g5229e7f95`), released 2021-01-18, bundled with Realtek's COEX (WiFi/BT
coexistence) stack version `20200730-5151`. This is the **exact same
upstream lineage** as the actively-maintained community fork
[`morrownr/8821cu-20210916`](https://github.com/morrownr/8821cu-20210916)
— both versions trace to the same Realtek `v5.12.0` base. The 5-year-old
binary FF still ships is essentially "the upstream Realtek source as of
20210118".

### Source-tree layout (from FILE symbols + DWARF strings)

`readelf -s` + `strings` show the driver was compiled from a tree at
`/home/linux/work/hard_t113/T113-Linux-Auto-v1.1/kernel/linux-5.4/drivers/staging/rtl8821cu/`
with the **standard Realtek layout** intact:

```
drivers/staging/rtl8821cu/
├── core/                 (rtw_cmd, rtw_mlme, rtw_ap, rtw_p2p, rtw_xmit, ...)
├── core/crypto/          (aes-*, ccmp, gcmp, sha256-*)
├── hal/                  (hal_com, hal_dm, hal_btcoex, halmac_*)
├── hal/rtl8821c/         (rtl8821c_cmd, rtl8821c_halinit, rtl8821c_ops, ...)
├── hal/btc/              (halbtc8821c1ant, halbtc8821c2ant, halbtc8821cwifionly)
├── hal/efuse/            (HalEfuseMask8821C_USB)
├── os_dep/linux/         (ioctl_cfg80211, ioctl_mp)
└── 8821cu.mod.c          (modpost-generated)
```

**No FF-added subdirectories**, no `ff_*.c`, no `ad5m_*.c`, no `flashforge_*.c`.
No `sunxi_rtl_*.c` or `t113_*.c` either — the Allwinner integration didn't
add source files, just Kconfig/Makefile wiring.

### Strings + symbols sweep

| Probe | Hits in `8821cu.ko` |
|---|---|
| `strings 8821cu.ko \| grep -iE 'flash\|adventurer\|ff5m\|forge\|ad5m'` | **0** |
| Symbols matching `^(ff_\|fforge_\|sunxi_rtl_\|t113_\|aw_)` | **0** |
| Symbols matching `^(sunxi_can\|sunxi_pwm_\|sunxi_ir_)` (other Allwinner drivers) | **0** — driver doesn't touch other Allwinner subsystems |
| `download_flash_88xx` / `read_flash_88xx` | present, but **these are stock Realtek functions** (88xx is the Realtek chip family) — not FF-related |
| Source paths starting with `drivers/staging/rtl8821cu/` | every `.c` file in the build (per FILE symbols), all standard Realtek paths |

### The three deltas from "pure vanilla"

All three are Allwinner-Auto-SDK build-integration scaffolding, not
functional source changes:

| Delta | What it does | Origin | Functional effect |
|---|---|---|---|
| `MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver)` ×2 | Declares the module imports kernel symbols from this namespace, satisfying the kernel-side check when the driver references `vfs_getattr`. | **Allwinner Auto SDK** — Tina-Auto's kernel exports `vfs_getattr` in this namespace (Android-GKI-style backport, same reason our `modules/f2fs-bsp/build.sh` patches `loop.c`). NOT in upstream Realtek source. | None at runtime; satisfies the kernel's namespace-check at module load. The double occurrence is modpost collecting the pragma from multiple `.o` files in the link set. |
| `CONFIG_LOAD_PHY_PARA_FROM_FILE=y` | Activates `filp_open` + `kernel_read` from `/lib/firmware/` for PHY parameter loading (instead of `request_firmware()`). | **Vanilla Realtek default** — confirmed in morrownr's Makefile (`CONFIG_LOAD_PHY_PARA_FROM_FILE = y` in the default config block). | This is what causes the driver to need the VFS namespace import. Not an FF choice. |
| No `CONFIG_PLATFORM_*` block | Uses `CONFIG_PLATFORM_AUTODETECT=y`. | Vanilla — Realtek's upstream Makefile already defaults to AUTODETECT and has no T113 platform block (the closest are `PLATFORM_ARM_SUN6I/SUN7I/SUN8I_W3P1/W5P1` for older Allwinner SoCs, all years older than T113-S3). | None — autodetect mode covers what the T113 needs (little-endian, cfg80211, USB HCI). |

### The provenance chain

```
Realtek vendor source (v5.12.0 + 16 commits + COEX 20200730-5151)
  release date: 2021-01-18
  layout: drivers/staging/rtl8821cu/{core,hal,os_dep,platform,...}
  ↓  no FF / Allwinner patches

Allwinner Auto SDK imports it verbatim at drivers/staging/rtl8821cu/
  T113-Linux-Auto-v1.1 SDK (the comp_dir we extracted from DWARF)
  ↓  adds 3 integration items:
     1. Kconfig: "config RTL8821CU tristate ..."
     2. Makefile: "obj-$(CONFIG_RTL8821CU) += 8821cu.o"
     3. MODULE_IMPORT_NS pragma in (one of the) .c files
  ↓  NO source-level patches to the Realtek driver

FlashForge builds the Tina-Linux-Auto kernel with the above
  Linaro GCC 5.3.1 20160412 + GNU ld 2.25.0 Linaro 2016_02
  Result: 8821cu.ko (in-tree built per `intree: Y` in modinfo)
  ↓  NO FF-side source patches
  ↓  NO FF-side build customizations beyond the kernel `.config`

FF OTA packages and re-ships unchanged in pro-3.1.3.tgz / 5.0.3 / 5.1.2 / 5.1.4
  (4 OTAs, bit-identical kernel payload — §8 verified)
```

### Why it matters

1. **FF is not maintaining the driver in any sense.** They imported it once
   via the Allwinner Auto SDK and have not touched it since. Any Realtek
   fixes from 2021-01-18 onward are absent from the shipped binary.

2. **Plug-compatibility with community forks.** The morrownr fork
   (`8821cu-20210916`) shares the exact same Realtek base. A binary built
   from morrownr against our rebuilt BSP kernel would be functionally
   equivalent to the FF binary, plus 5 years of community fixes for newer
   kernel API (vfs_getattr namespace handling, kernel_read signature
   changes, etc.).

3. **Zero proprietary FF code is in the binary.** Nothing to clean-room
   replicate, nothing to license around. Pure GPL Realtek + GPL Allwinner
   integration scaffolding.

4. **The earlier finding that FF never shipped a kernel-OTA hotfix (§8)
   has a stronger reading**: they're not just *not using* the hotfix
   mechanism — they don't have any source to ship as a hotfix in the
   first place. The Auto SDK build environment that originally produced
   the binary is presumably gone (per the `larry/larry` → `wsl/wsl` tar
   owner change in §8), and the Realtek-supplied source they used is
   long since superseded upstream.

## 12. Practical implications for ReForge

| Scenario | Action |
|---|---|
| Need WiFi to work under ReForge today | Use the stock `8821cu.ko` as-is. `vermagic` matches our rebuilt kernel; just copy the `.ko` and `insmod` it (forge-x's chroot model already does this on the live device). |
| Want to rebuild `8821cu.ko` from public source | Drop `morrownr/8821cu-20210916` (or equivalent community fork of the same Realtek `v5.12.0` base) into our BSP at `drivers/net/wireless/rtl8821cu/`, add the Kconfig + Makefile wiring, set `CONFIG_RTL8821CU=m`. Build will produce a functionally equivalent `.ko`. |
| Want Plan-5-style mainline WiFi | Use `CONFIG_RTW88_8821CU=m` (mainline 6.2+, solid 6.12+). Different driver entirely (rtw88 family, not the Realtek vendor source). Station-mode-solid; AP/monitor weaker but irrelevant for a printer. Already documented in `../board-notes/README.md`. |
| Need byte-identical reproduction of stock's `.ko` | Requires the **T113-Linux-Auto-v1.1 SDK** (Allwinner Auto distribution; not publicly available) + matching Linaro `arm-linux-gnueabi-gcc 5.3.1 20160412` + the SDK's strip-bypass-cp pipeline that produces the flat copy. **Not feasible** without acquiring the proprietary SDK. |

---

## Sources

### Internal evidence
- `reforge/tools/recovery/archive/Adventurer5M-factory.tar.xz` — factory
  rootfs (extracted file listing, `/lib/modules/` layout)
- `fw-analysis/pro-3.1.3.tgz` → `k-3.1.3/` — stock 3.1.3 OTA kernel-update
  component (`run.sh`, `8821cu.ko`, `sunxi.dtb`, `uImage`)
- `fw-analysis/k-3.1.3/8821cu.ko` — extracted OTA copy of the flat `.ko`
- `reforge/docs/board-notes/stock-kernel-config-5.4.61.txt.gz` — running
  `/proc/config.gz` (the `CONFIG_DEBUG_INFO=y` + `CONFIG_MAGIC_SYSRQ=y`
  evidence)
- `reforge/docs/boot.md` §4 — the `auto_run.sh` flow that does `insmod
  /lib/modules/8821cu.ko`
- `reforge/docs/research/2026-06-04-bsp-kernel-rebuild-findings.md` — vermagic
  match between our rebuilt kernel and stock

### Analysis commands run for this finding
```sh
# extract every module + classify by debug-info presence
tar -tJf Adventurer5M-factory.tar.xz | grep lib/modules
tar -xJf Adventurer5M-factory.tar.xz -C /tmp/ff-modules \
    lib/modules/8821cu.ko lib/modules/5.4.61/{8821cu,xr829,...}.ko
for m in /tmp/ff-modules/lib/modules/**/*.ko; do
    arm-linux-gnueabi-readelf -SW "$m" | grep -c '\.debug_info'
done

# modinfo + section sizes
modinfo /tmp/ff-modules/lib/modules/8821cu.ko
arm-linux-gnueabi-readelf -SW <both copies>
diff <(readelf-decode flat) <(readelf-decode standard)

# DWARF inspection
arm-linux-gnueabi-readelf --debug-dump=info <flat-copy> \
    | grep -E "DW_AT_(producer|comp_dir|name)"
```

### External
- Linux kernel `scripts/Makefile.modpost` — generates `.mod.c` wrappers
- Linux kernel `scripts/Makefile.modinst` + `INSTALL_MOD_STRIP` — module
  strip-on-install behavior
- Realtek RTL8821CU driver `v5.12.0-16-g5229e7f95` (vendor tarball lineage)
- Community fork of the same driver:
  <https://github.com/morrownr/8821cu-20210916>
