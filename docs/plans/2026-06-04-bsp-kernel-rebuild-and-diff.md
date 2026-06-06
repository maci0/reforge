# Plan — rebuild the stock BSP kernel from source and diff against on-device

**Date:** 2026-06-04
**Status:** ✅ **EXECUTED 2026-06-04.** Findings:
[`../research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md`](../research/kernel/2026-06-04-bsp-kernel-rebuild-findings.md).
**Verdict:** Tier 1 + Tier 2 + Tier 3 PASS — build is functionally
equivalent to stock (Image size Δ −756 B / −0.0058%, vermagic byte-identical,
99.99% export coincidence). Green light for Path A enablement
(`CONFIG_KEXEC=y` on top of this baseline).
No flash, no FEL, no eMMC modification attempted.
**Upstream:** [`../research/kernel/2026-06-04-brick-safe-kernel-test-paths.md`](../research/kernel/2026-06-04-brick-safe-kernel-test-paths.md)
([`Path A — kexec hybrid` §2.3](../research/kernel/2026-06-04-brick-safe-kernel-test-paths.md#23-the-hybrid-plan-one-time-bootimg-reflash-then-iterate-freely-via-kexec)
and the precondition checklist).
**See also:** [`../boot.md`](../boot.md) §1 (boot chain + Android boot-image
format on `mmcblk0p4`), [`../board-notes/`](../board-notes/) (captured
`.config` + cmdline + uname), `tests/qemu-harness/extract-stock-rootfs.sh`
(the established sfdisk + dd partition-slice recipe).

---

## 1. Goal

Build a kernel from our pinned BSP source + the captured stock `.config`, and
compare the resulting image against the kernel actually running on the device
(extracted from the golden eMMC dump). The output of this exercise is a
**concrete, evidence-backed answer** to:

> *"Can we reproduce the on-device kernel from public, pinned sources well
> enough to trust an eventual repacked `boot.img` (or an FEL-loaded image) to
> behave like stock?"*

Until we have that answer, every downstream path (kexec-enable hybrid, FEL
kernel test, Plan 5 mainline-LTS port) is built on an unverified assumption.

### Why now, before any FEL / kexec / reflash work

- **Zero device risk.** Pure host-side build + compare. No JTAG, no UART, no
  USB-OTG, no `dd`, no opening the case.
- **Catches the cheapest failures first.** Wrong commit, missing vendor patch,
  silently-altered Kconfig, embedded blob path — all surface here for free,
  before they have a chance to brick.
- **Sets the toolchain baseline.** Stock was compiled with **Linaro GCC
  5.3-2016.05 (5.3.1)**; our vendor pin is **GCC 9.5.0 nolibc** (per
  `pins.lock`). The size/shape of that delta is something we need to *measure*,
  not guess.
- **Establishes "stock-equivalent" as a named, version-pinned artifact** we can
  build on top of (e.g. `+ CONFIG_KEXEC=y` for the Path A hybrid).

---

## 2. Inputs (everything we already have)

| Input | Path | Provenance |
|---|---|---|
| BSP source | `vendor/kernels/tina-bsp-kernel` (submodule @ commit `349a0b9`) | `pins.lock:6` — `iLotusK9/linux_kernel_aw_t113@5.4.61` |
| Stock `.config` | `docs/board-notes/stock-kernel-config-5.4.61.txt.gz` | `cp /proc/config.gz` from `root@192.168.0.158` (`kunos`) |
| Stock kernel cmdline | `docs/board-notes/running-unit-probe.txt` | UART-equivalent capture from device |
| Stock kernel uname | `docs/board-notes/running-unit-probe.txt` | `Linux kunos 5.4.61 #52 SMP PREEMPT Wed Aug 23 15:33:33 CST 2023 armv7l` |
| Golden eMMC dump (clean stock) | `tools/recovery/golden.img.gz` (~919 MB compressed, 7.3 GB raw) | `tools/recovery/recovery-sources.md` — produced by `make-clean-golden.sh` |
| Toolchain | `vendor/toolchains/gcc-9.5.0-nolibc/arm-linux-gnueabi/` | `pins.lock:9` (sha256-pinned tarball) |
| Existing kernel-build harness | `tests/qemu-harness/build-test-kernel.sh` | Builds qemu virt kernel from same BSP — pattern to copy |
| Existing partition-slice recipe | `tests/qemu-harness/extract-stock-rootfs.sh` | Rootless sfdisk + dd from golden (does p6 today; we want p4) |

### Inputs we do **not** need

- A second toolchain (we will NOT pin Linaro 5.3.1 — see §3.1).
- UART / FEL / device access.
- A second eMMC dump.

---

## 3. Build plan

### 3.1 Toolchain decision — use GCC 9.5.0, document the delta

Stock was built with `arm-linux-gnueabi-gcc (Linaro GCC 5.3-2016.05) 5.3.1`
(per `CONFIG_CC_VERSION_TEXT`). We will **not** pin Linaro 5.3.1 because:

- It is unmaintained, has no security updates, and is not in our pin graph.
- The point of this exercise is to validate **our** pinned toolchain against
  stock, not to recreate stock's toolchain choice. If the GCC 9.5.0 build is
  functionally equivalent, we are done. If not, we know exactly which
  differences came from the toolchain.
- Buildroot / `reforge_defconfig` already builds glibc + the whole userspace
  with GCC 9.5.0 against the stock 5.4.61 kernel ABI without issue — so the
  GCC delta is known to be **userspace-safe**. The question is whether the
  *kernel* image it produces is similarly compatible.

**Recorded expectation:** small code-gen differences on every function are
*normal* under a GCC major bump (5 → 9 = 4 majors). What we look for is:

- Same set of symbols (`nm`).
- Same Kconfig fingerprint (re-extracted IKCONFIG matches the captured one).
- Same vermagic string components that gate module loading.
- Same DTB output for the AD5M Pro board.

### 3.2 Build sequence — exact commands

These should land as a new tracked script `tools/build/build-bsp-kernel.sh`
(naming consistent with the existing `tools/build/build.sh` + `env.sh`). For
the plan they live here:

```sh
# --- environment ----------------------------------------------------------
REPO_ROOT=/home/maci/Desktop/Projects/flashforge/reforge
KSRC="${REPO_ROOT}/vendor/kernels/tina-bsp-kernel"
TC="${REPO_ROOT}/vendor/toolchains/gcc-9.5.0-nolibc/arm-linux-gnueabi/bin/arm-linux-gnueabi-"
OUT="${REPO_ROOT}/build/bsp-kernel-rebuild"   # gitignored under /build/

# Reproducibility: pin SOURCE_DATE_EPOCH to the stock build timestamp so
# embedded __DATE__/__TIME__ macros stop being a diff source. The stock build
# string is "Wed Aug 23 15:33:33 CST 2023" → 2023-08-23 07:33:33 UTC.
export SOURCE_DATE_EPOCH=1692776013
export KBUILD_BUILD_TIMESTAMP="Wed Aug 23 15:33:33 CST 2023"
export KBUILD_BUILD_USER="root"
export KBUILD_BUILD_HOST="kunos"     # match stock uname `Linux kunos`

# --- 1. load the stock .config (single source of truth) -------------------
mkdir -p "${OUT}"
zcat "${REPO_ROOT}/docs/board-notes/stock-kernel-config-5.4.61.txt.gz" > "${OUT}/.config"

# --- 2. normalize against current source (selects defaults for any new   --
#       symbols, no interactive prompts) -----------------------------------
make -C "${KSRC}" O="${OUT}" ARCH=arm CROSS_COMPILE="${TC}" olddefconfig

# Capture the diff between captured .config and what olddefconfig produced;
# any non-trivial delta means BSP source ≠ on-device kernel source.
diff -u "${OUT}/.config.captured" "${OUT}/.config" \
    > "${OUT}/diff-captured-vs-olddefconfig.txt" || true

# --- 3. build the image + dtb + modules -----------------------------------
JOBS="${BUILD_JOBS:-$(nproc)}"
make -C "${KSRC}" O="${OUT}" ARCH=arm CROSS_COMPILE="${TC}" -j"${JOBS}" \
    zImage modules dtbs

# --- 4. stage the artifacts for diff --------------------------------------
mkdir -p "${OUT}/artifacts"
cp "${OUT}/arch/arm/boot/zImage"                       "${OUT}/artifacts/zImage.ours"
cp "${OUT}/vmlinux"                                    "${OUT}/artifacts/vmlinux.ours"
cp "${OUT}/System.map"                                 "${OUT}/artifacts/System.map.ours"
# DTB(s) — we don't yet know which file(s) the stock kernel uses for AD5M Pro;
# enumerate everything that mentions sun8i-t113 and pick the matching one
# during the diff step.
find "${OUT}/arch/arm/boot/dts" -name '*t113*' -o -name '*ad5m*' \
    | xargs -I{} cp {} "${OUT}/artifacts/"
```

### 3.3 Extract the on-device kernel — exact commands

The stock kernel lives in `mmcblk0p4` (boot-resource partition) as an
**Android boot-image** (`ANDROID!` magic; kernel + dtb + ramdisk + cmdline).
Per `docs/boot.md` §1.

```sh
# --- 1. decompress golden (rootless, large temp file ~7.3 GB) ------------
GOLDEN_RAW="${OUT}/golden-raw.img"
gzip -dc "${REPO_ROOT}/tools/recovery/golden.img.gz" > "${GOLDEN_RAW}"

# --- 2. read GPT, find p4 byte offsets + size (same idiom as ------------
#       extract-stock-rootfs.sh) ------------------------------------------
P4_START=$(sfdisk -d "${GOLDEN_RAW}" \
    | awk '/start=/ && /name="boot"/ {gsub("[,a-zA-Z=]","",$4); print $4}')
P4_SIZE=$(sfdisk -d "${GOLDEN_RAW}" \
    | awk '/start=/ && /name="boot"/ {gsub("[,a-zA-Z=]","",$6); print $6}')
P4_OFFSET_BYTES=$(( P4_START * 512 ))
P4_BYTES=$(( P4_SIZE * 512 ))

# --- 3. dd p4 out --------------------------------------------------------
dd if="${GOLDEN_RAW}" of="${OUT}/p4-bootimg.bin" \
    bs=1M iflag=skip_bytes,count_bytes \
    skip="${P4_OFFSET_BYTES}" count="${P4_BYTES}"
rm -f "${GOLDEN_RAW}"   # reclaim ~7 GB

# --- 4. unpack the Android boot-image ------------------------------------
#       Two pure-Python options that ship in any distro tree:
#         a) abootimg (apt: abootimg)         — simplest
#         b) extract-android-boot-image.py    — easy to bundle
mkdir -p "${OUT}/stock-bootimg"
abootimg -x "${OUT}/p4-bootimg.bin" \
    "${OUT}/stock-bootimg/bootimg.cfg" \
    "${OUT}/stock-bootimg/kernel" \
    "${OUT}/stock-bootimg/initramfs" \
    "${OUT}/stock-bootimg/dtb" \
    2>"${OUT}/stock-bootimg/abootimg.log"

# --- 5. unwrap the kernel image -----------------------------------------
#       The "kernel" payload is the gzip'd Image (CONFIG_KERNEL_GZIP=y in
#       stock; .config shows that). The first 2 bytes are 0x1f 0x8b.
file "${OUT}/stock-bootimg/kernel"
# Decompressed Image:
mkdir -p "${OUT}/artifacts"
gzip -dc "${OUT}/stock-bootimg/kernel" > "${OUT}/artifacts/Image.stock" \
    || { echo "kernel not gzip — try lz4/xz"; exit 1; }
cp "${OUT}/stock-bootimg/dtb"       "${OUT}/artifacts/dtb.stock"
cp "${OUT}/stock-bootimg/bootimg.cfg" "${OUT}/artifacts/bootimg-cmdline.stock"
```

After §3.2 + §3.3 the `artifacts/` dir contains the matched pair:

```
artifacts/
├── zImage.ours              (compressed wrapper, gzip self-decompressing)
├── vmlinux.ours             (uncompressed ELF with debug, our build)
├── System.map.ours
├── sun8i-t113-*.dtb         (our build)
├── Image.stock              (decompressed stock kernel, no ELF symbols)
├── dtb.stock
└── bootimg-cmdline.stock
```

---

## 4. Comparison methodology

Ordered from "easy + decisive" to "deep + diagnostic". The goal is to walk
the rubric until either the build clears every check or a single failure
pins down the cause.

### 4.1 Tier 1 — config + DTB equivalence (decisive)

```sh
# A. The captured .config and the .config our build settled on must match.
diff "${OUT}/.config.captured" "${OUT}/.config" \
    | tee "${OUT}/diff-config.txt"
# Empty / only-comment diff = PASS. Real diff = STOCK SOURCE ≠ OUR SOURCE.

# B. Pull the embedded IKCONFIG out of the stock kernel (CONFIG_IKCONFIG
#    must be =y in the captured .config for this to exist) and diff it.
zcat docs/board-notes/stock-kernel-config-5.4.61.txt.gz \
    | grep -E "^CONFIG_IKCONFIG" || echo "IKCONFIG not set — skip B"

# C. DTB equivalence: decompile both, normalize whitespace, diff.
dtc -O dts -I dtb "${OUT}/artifacts/dtb.stock"          > "${OUT}/dtb.stock.dts"
dtc -O dts -I dtb "${OUT}/artifacts/sun8i-t113-*.dtb"   > "${OUT}/dtb.ours.dts"
diff -u "${OUT}/dtb.stock.dts" "${OUT}/dtb.ours.dts" \
    > "${OUT}/diff-dtb.txt" || true
```

**Pass criteria (Tier 1):**
- `.config` diff is empty (no Kconfig delta).
- DTB diff is empty or limited to phandles / cell-order normalization that
  `fdtdump` flattens identically.

If Tier 1 fails, **stop here** and fix it. The toolchain delta does not
cause Kconfig or DTB to differ.

### 4.2 Tier 2 — image-level structural diff (high signal)

```sh
# A. Sizes + sections.
size "${OUT}/artifacts/Image.stock" "${OUT}/artifacts/vmlinux.ours"      \
    > "${OUT}/diff-size.txt"
arm-linux-gnueabi-objdump -h "${OUT}/artifacts/vmlinux.ours"             \
    > "${OUT}/sections-ours.txt"
# Stock has no ELF, so we approximate via section magics in Image.stock.

# B. Vermagic string — the gatekeeper for module ABI.
strings "${OUT}/artifacts/Image.stock"  | grep -m1 'SMP preempt mod_unload' \
    > "${OUT}/vermagic-stock.txt"
strings "${OUT}/artifacts/vmlinux.ours" | grep -m1 'SMP preempt mod_unload' \
    > "${OUT}/vermagic-ours.txt"
diff "${OUT}/vermagic-stock.txt" "${OUT}/vermagic-ours.txt"
# Stock vermagic: "5.4.61 SMP preempt mod_unload ARMv7 p2v8 "
# (verified — modules/zram-bsp + modules/f2fs-bsp/dist were built against
# this exact string, and they load on the device.)
```

**Pass criteria (Tier 2):**
- `size` deltas within ~5% per-section (GCC 9 vs 5.3 code-gen).
- `vermagic` byte-identical. If different, document precisely *why*
  (Kconfig delta? `MODULE_VERMAGIC_INFO` change?) and decide whether to
  match-or-bridge before any reflash.

### 4.3 Tier 3 — symbol set equivalence (functional equivalence)

```sh
# A. Exported symbol set (kernel <-> module ABI surface)
arm-linux-gnueabi-nm --defined-only --print-size --size-sort \
    "${OUT}/artifacts/vmlinux.ours" \
    | awk '{print $3}' | sort -u > "${OUT}/syms-ours.txt"

# Stock has no debug ELF. Approximation: pull __ksymtab_strings from Image.
# (CONFIG_KALLSYMS=y in the captured config, so the kernel does carry the
# kallsyms table; locating it requires walking past the decompressor stub.)
# Simpler: extract symbols from a stock module on the device (8821cu.ko) and
# diff the SYMBOLS it depends on against what our vmlinux EXPORTS.
arm-linux-gnueabi-objdump -t /path/to/8821cu.ko \
    | awk '$0 ~ /UND/ {print $NF}' | sort -u > "${OUT}/syms-stock-needs.txt"
comm -23 "${OUT}/syms-stock-needs.txt" "${OUT}/syms-ours.txt" \
    > "${OUT}/diff-missing-exports.txt"
```

**Pass criteria (Tier 3):**
- `diff-missing-exports.txt` is empty (our kernel exports every symbol the
  stock `8821cu.ko` references).
- If non-empty, the missing symbols name precisely which Kconfig / patch we
  are missing.

### 4.4 Tier 4 — code-gen diff (informational, expected to differ)

```sh
# Disassemble a known-stable function on both sides and eyeball the result.
# We expect MANY instruction-level differences (GCC 5 → 9). Goal: confirm
# the diffs are pure code-gen, not missing/added basic blocks.
arm-linux-gnueabi-objdump -d "${OUT}/artifacts/vmlinux.ours" \
    | awk '/<start_kernel>:/,/^$/'      > "${OUT}/asm-ours.txt"
# Stock side: requires loading the decompressed Image at known address +
# walking System.map (unavailable). Treat Tier 4 as advisory only.
```

**No pass criteria here**, this is read-only diagnostic.

### 4.5 Decision rubric

| Tier 1 | Tier 2 | Tier 3 | Verdict |
|---|---|---|---|
| ✅ | ✅ | ✅ | **Functionally equivalent.** Green light to layer `CONFIG_KEXEC=y` (or any other targeted Kconfig delta) on top with confidence. Save this `.config` as `vendor/kernels/configs/ad5m-stock-equivalent.config`. |
| ✅ | ✅ | ❌ | Specific missing exports — almost certainly Kconfig (a `EXPORT_SYMBOL_GPL` gated by some `CONFIG_*`). Diff isolates which. Fix the `.config` capture, rebuild, re-diff. |
| ✅ | ❌ | ✅ | vermagic differs but symbol set matches. Most common cause: a missed `CONFIG_LOCALVERSION` or `CONFIG_LOCALVERSION_AUTO`. Document, fix, repeat. |
| ❌ | — | — | Kconfig / DTB delta. Either our submodule HEAD differs from what FF shipped, or FF carries unpublished vendor patches. Hard stop — escalate to a deeper RE pass on the BSP commit history before going further. |

---

## 5. Outputs of this exercise

When the plan executes, it produces:

1. **`tools/build/build-bsp-kernel.sh`** — the codified `§3.2 + §3.3` build
   script (paste from this plan; gitignored output under `build/bsp-kernel-rebuild/`).
2. **`Makefile` target** — `make bsp-kernel-rebuild` that calls the above
   (mirrors the existing `qemu-kernel` target shape).
3. **`vendor/kernels/configs/ad5m-stock-equivalent.config`** — the validated
   `.config` (committed only if Tier 1 + Tier 3 pass; otherwise stays in
   build/).
4. **`docs/research/2026-XX-XX-bsp-kernel-rebuild-findings.md`** — the
   captured deltas (Tier 1–4 output + verdict + any patches found).
5. (Optional) **`vendor/kernels/patches/`** — any vendor patches surfaced by
   Tier 1 / Tier 3 that need carrying. Empty if none.

---

## 6. Out of scope (explicitly)

- Adding `CONFIG_KEXEC=y` — that comes in a *follow-up* plan after this one
  passes ("Path A enablement plan"). Mixing the two would conflate
  "is our build stock-equivalent?" with "does our build do something
  different on purpose?".
- Repacking the resulting kernel into an Android boot-image and flashing
  `mmcblk0p4` — that is Path A (per the brick-safe-kernel-test-paths note),
  gated behind this plan finishing green.
- Touching FEL / USB0 / UART soldering — Path B, separate hardware-mod track.
- Bumping to a different kernel version (mainline 6.x LTS) — Plan 5.

---

## 7. Risks for this plan itself (host-only)

| Risk | Mitigation |
|---|---|
| `vendor/kernels/tina-bsp-kernel` submodule HEAD has drifted from what FF actually shipped | Tier 1 catches it (Kconfig / DTB delta). Fix by walking the iLotusK9 commit history around 2023-08 (stock build date). |
| BSP source needs out-of-tree vendor patches we don't have | Tier 1 / Tier 3 fail the same way (missing Kconfig symbols or missing exports). The diff itself names the patches needed. |
| `abootimg` not the right unpacker (some FF OTAs have a tweaked header) | Fall back to `mkbootimg --extract` or the Python `extract-android-boot-image.py`. The header's `ANDROID!` magic + `page_size 2048` is standard per the §1 cmdline format. |
| GCC 9 produces a kernel that won't even compile on this 5.4 source | Documented upstream: 5.4 LTS supports up to GCC 11 with the usual `-Wno-*` toggles. If we hit a hard error, pin Linaro 5.3.1 in `vendor/toolchains/` *just for this comparison build* — but only after confirming GCC 9 is the actual blocker, not us. |
| Symbol diff in Tier 3 needs a stock module on the device, but we don't ship one | The on-device `8821cu.ko` is loaded by stock (`docs/board-notes/running-unit-probe.txt` `lsmod`). Pull it via SSH (read-only) to `lab/scratch/`; gitignored. No write to device. |
| Toolchain produces unreproducible binaries (timestamps, build-id) | `SOURCE_DATE_EPOCH` + `KBUILD_BUILD_TIMESTAMP`/`KBUILD_BUILD_USER`/`KBUILD_BUILD_HOST` set in §3.2 environment block. |

---

## 8. Execution prerequisites (read once before starting)

1. `./vendor/fetch.sh` has run successfully (submodules + toolchain tarball).
2. `tools/recovery/golden.img.gz` is the **clean** golden (`golden.size`
   reports `7818182656`) — not a `forge-x-*` dump.
3. Host has `~10 GB` free for the temp `golden-raw.img`.
4. Host packages: `gcc-arm-none-eabi` toolchain not needed (we use vendor),
   but: `make`, `bc`, `cpio`, `xz-utils`, `kmod`, `dtc`, `sfdisk`, `debugfs`,
   `abootimg` (Debian: `apt install abootimg device-tree-compiler util-linux
   e2fsprogs`).
5. Pull `/lib/modules/<vermagic>/kernel/drivers/net/wireless/8821cu.ko` from
   the device (read-only, via SSH) into `lab/scratch/8821cu.ko` for Tier 3.
   Gitignored.

---

## 9. Concrete next step (when work resumes)

Smallest committable PR shape:

```
+ tools/build/build-bsp-kernel.sh                       (executable, ~120 lines)
+ Makefile                                              (+ `bsp-kernel-rebuild` target)
+ .gitignore                                            (+ /build/bsp-kernel-rebuild/)
+ docs/research/2026-XX-XX-bsp-kernel-rebuild-findings.md
    (the Tier 1–4 actual results + verdict + decision)
```

Optionally, **if and only if** Tier 1 + 3 pass green:

```
+ vendor/kernels/configs/ad5m-stock-equivalent.config   (the validated baseline)
```

Nothing in `br-external/` or `packaging/` changes here.

---

## 10. Sources

### Internal
- `vendor/kernels/tina-bsp-kernel/` — BSP source @ `349a0b9`
- `docs/board-notes/stock-kernel-config-5.4.61.txt.gz` — the captured `.config`
- `docs/board-notes/running-unit-probe.txt` — `uname` + `cmdline` + `lsmod`
- `tools/recovery/golden.img.gz` + `tools/recovery/golden.size`
- `tools/recovery/recovery-sources.md` — image provenance
- `tests/qemu-harness/build-test-kernel.sh` — existing build harness (same BSP)
- `tests/qemu-harness/extract-stock-rootfs.sh` — established sfdisk + dd recipe
- `docs/boot.md` §1 — Android boot-image format on `mmcblk0p4`
- `docs/research/kernel/2026-06-04-brick-safe-kernel-test-paths.md` — why this plan
  must complete before Path A or Path B is attempted
- `pins.lock` — `tina-bsp-kernel@349a0b9`, GCC `9.5.0` sha256 `81669db4…`

### External
- Linux kernel `Documentation/admin-guide/reproducible-builds.rst` —
  `SOURCE_DATE_EPOCH`, `KBUILD_BUILD_TIMESTAMP`, etc.
- Linux kernel `Documentation/process/changes.rst` — supported toolchains for
  5.4 LTS (GCC 5.1 to GCC 11+).
- Android `boot.img` format reference —
  <https://source.android.com/docs/core/architecture/bootloader/boot-image-header>
- `abootimg` upstream — <https://github.com/ggrandou/abootimg>
- Linaro toolchain archive (kept for *recovery only*, not pinned) —
  <https://releases.linaro.org/components/toolchain/binaries/5.3-2016.05/arm-linux-gnueabi/>
