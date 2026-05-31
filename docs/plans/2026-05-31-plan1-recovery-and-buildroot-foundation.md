# ReForge Plan 1 — Recovery Baseline & Buildroot Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the ReForge build foundation — a *fresh upstream Buildroot* `BR2_EXTERNAL` tree that reproducibly builds a minimal ARMv7 (Cortex-A7) rootfs which runs under qemu-user — and finalize the P0 recovery baseline (verified golden eMMC dump + restore runbook) before any device flash.

**Architecture:** Pinned upstream Buildroot submodule (never forked) + our `BR2_EXTERNAL` tree holding all board/package/config work. A thin top-level Makefile wraps Buildroot. Verification is build-and-run: the rootfs must build twice identically (reproducibility) and a binary from it must execute under `qemu-arm-static`. No kernel/bootloader is built in this plan (those are P4); the foundation targets userspace only. Recovery (P0) is operational tasks: verify the dump, write the runbook, stage a stock `.tgz`.

**Tech Stack:** Buildroot (latest stable release tag, ~2026.02), GNU make, git submodules, qemu-arm-static (qemu-user) for smoke tests, dtc, sha256sum, xz.

**Scope boundary:** This plan covers Phase 0 (recovery) + Phase 1 (build-system foundation) from the design spec `reforge/docs/2026-05-31-reforge-firmware-design.md`. It does NOT add Klipper/Moonraker/Mainsail/GuppyScreen (Plan 2), the `.tgz` installer (Plan 3), MCU firmware (Plan 4), or kernel/u-boot/display (Plan 5). The rootfs produced here is intentionally minimal (busybox + init).

---

## File Structure

| Path | Responsibility |
|---|---|
| `reforge/buildroot/` | Pinned upstream Buildroot (git submodule @ release tag). Never edited. |
| `reforge/pins.lock` | Authoritative SHAs/tags for every pinned component. Reproducibility anchor. |
| `reforge/br-external/external.desc` | BR2_EXTERNAL name + description (Buildroot discovery file). |
| `reforge/br-external/external.mk` | Includes our `package/*/*.mk`. |
| `reforge/br-external/Config.in` | Sources our `package/*/Config.in` into menuconfig. |
| `reforge/br-external/configs/reforge_defconfig` | The board defconfig — toolchain, arch (Cortex-A7), rootfs, no kernel. |
| `reforge/br-external/board/reforge/post-build.sh` | Rootfs post-build hook (placeholder; real overlay lands in Plan 2). |
| `reforge/br-external/board/reforge/rootfs-overlay/etc/os-release` | Brands the rootfs as ReForge (overlay smoke target). |
| `reforge/build_scripts/env.sh` | Shared build env (paths to buildroot, br-external, output). |
| `reforge/build_scripts/build.sh` | Build wrapper: prepare/build/clean verbs. |
| `reforge/Makefile` | Top-level convenience targets delegating to build.sh. |
| `reforge/scripts/smoke_rootfs.sh` | qemu-user smoke test of the built rootfs. Plan's primary "test". |
| `reforge/scripts/repro_check.sh` | Builds rootfs twice, compares for reproducibility. |
| `reforge/recovery/dump_golden.sh` | Re-runnable golden eMMC dump (parameterized host). |
| `reforge/recovery/verify_dump.sh` | Validates a golden dump is non-truncated + matches eMMC size. |
| `reforge/recovery/RUNBOOK.md` | Soft-brick + hard-brick recovery procedures. |
| `reforge/.github/workflows/build.yml` | CI: build rootfs + smoke + repro check. |

---

## Task 0: Finalize P0 recovery baseline

**Files:**
- Create: `reforge/recovery/dump_golden.sh`
- Create: `reforge/recovery/verify_dump.sh`
- Create: `reforge/recovery/RUNBOOK.md`

The golden dump is already streaming to `reforge/recovery/golden-kunos-*.img.gz`. This task makes the procedure repeatable and verifies the artifact.

- [ ] **Step 1: Write `dump_golden.sh`** (re-runnable, host as `$1`, pipes over SSH, gzips locally, never stores on device)

```sh
#!/bin/sh
# Usage: ./dump_golden.sh root@<printer-ip>
set -eu
HOST="${1:?usage: dump_golden.sh root@host}"
TS=$(date +%Y%m%d-%H%M%S)
OUT="$(dirname "$0")/golden-$(echo "$HOST" | sed 's/.*@//')-${TS}.img.gz"
echo "device eMMC size:"
# /sys/block/mmcblk0/size is in 512-byte sectors -> ×512 for bytes.
# (Do NOT change to ×1024; that is /proc/partitions' 1K-block unit, a different source.)
ssh "$HOST" 'cat /sys/block/mmcblk0/size | awk "{print \$1*512}"' | tee "${OUT%.img.gz}.size"
echo "dumping full mmcblk0 -> $OUT (raw over ssh, gzip local)"
ssh "$HOST" 'dd if=/dev/mmcblk0 bs=4M 2>/dev/null' | gzip > "$OUT"
sha256sum "$OUT" | tee "${OUT}.sha256"
echo "done: $OUT"
```

- [ ] **Step 2: Write `verify_dump.sh`** (decompress-count bytes, compare to recorded eMMC size, assert not truncated)

Robust to dumps made by either the new `dump_golden.sh` (which writes a `.size` sidecar) **or** the earlier ad-hoc dump (no `.size`, but the size is recorded in the matching `partitions-*.txt` after the `---SIZE---` marker). Generates the `.sha256` if it is missing rather than hard-failing.

```sh
#!/bin/sh
# Usage: ./verify_dump.sh golden-xxx.img.gz
set -eu
GZ="${1:?usage: verify_dump.sh <golden.img.gz>}"
DIR=$(dirname "$GZ")

# Expected eMMC size: prefer the .size sidecar; else parse partitions-*.txt
SIZEFILE="${GZ%.img.gz}.size"
if [ -f "$SIZEFILE" ]; then
  EXPECT=$(cat "$SIZEFILE")
else
  # earlier ad-hoc dump: pull the number after the ---SIZE--- marker
  PFILE=$(ls "$DIR"/partitions-*.txt 2>/dev/null | head -n1)
  EXPECT=$(awk '/---SIZE---/{getline; print; exit}' "$PFILE")
  [ -n "$EXPECT" ] || { echo "FAIL: cannot determine expected size"; exit 1; }
  echo "$EXPECT" > "$SIZEFILE"   # backfill sidecar for future runs
fi

ACTUAL=$(gzip -dc "$GZ" | wc -c)
echo "expected=$EXPECT actual=$ACTUAL"
[ "$EXPECT" = "$ACTUAL" ] || { echo "TRUNCATED/MISMATCH"; exit 1; }

# Checksum: verify if present, else create it now that the dump is complete
if [ -f "${GZ}.sha256" ]; then
  echo "sha256:"; sha256sum -c "${GZ}.sha256"
else
  echo "no .sha256 sidecar — generating one"; sha256sum "$GZ" | tee "${GZ}.sha256"
fi
echo "OK: dump is full-size and checksum-valid"
```

- [ ] **Step 3: Wait for the running dump to complete, then verify it**

The dump currently streaming (`golden-kunos-20260531-152104.img.gz`) was started by the earlier ad-hoc command, so it has **no `.size`/`.sha256` sidecars** — `verify_dump.sh` (Step 2) handles this by reading the size from `partitions-20260531-152104.txt` (the `---SIZE---` value `7818182656`) and generating the `.sha256` on first run. Wait for the background job to finish first (`du -h` stops growing; the launching command prints `EXIT=0`).

Run: `cd reforge/recovery && sh verify_dump.sh golden-kunos-*.img.gz`
Expected: `expected=7818182656 actual=7818182656` then `OK: dump is full-size and checksum-valid`
(Do NOT proceed to any device-flashing plan until this passes. This is the gate-zero deliverable.)

- [ ] **Step 4: Write `RUNBOOK.md`** documenting recovery paths

Content must cover: (a) soft-brick → reflash known-good stock `.tgz` from USB; (b) hard-brick (bad bootloader/kernel) → physically read eMMC, write back `golden-*.img.gz` via reader; (c) the explicit note that this unit has **no FEL/no UART**, so (b) is the only deep recovery; (d) where the staged stock `.tgz` lives. Include the exact `gzip -dc golden.img.gz | dd of=/dev/<reader> bs=4M` restore command with a **WARNING** to confirm the reader device node first.

- [ ] **Step 5: Commit**

```bash
cd reforge
git add recovery/dump_golden.sh recovery/verify_dump.sh recovery/RUNBOOK.md
chmod +x recovery/dump_golden.sh recovery/verify_dump.sh
git commit -m "P0: repeatable golden dump + verify + recovery runbook"
```

---

## Task 1: Pin upstream Buildroot as a submodule + start `pins.lock`

**Files:**
- Create: `reforge/buildroot/` (submodule)
- Create: `reforge/pins.lock`
- Modify: `reforge/.gitmodules` (auto)

- [ ] **Step 1: Determine the latest stable Buildroot release tag**

Run: `git ls-remote --tags https://gitlab.com/buildroot.org/buildroot.git | grep -oE 'refs/tags/20[0-9.]+$' | sort -V | tail -5`
Expected: a list ending in the newest quarterly stable (e.g. `2026.02`, `2026.02.1`). Pick the newest non-rc `.x` point release.

- [ ] **Step 2: Add the submodule pinned to that tag**

```bash
cd reforge
git submodule add https://gitlab.com/buildroot.org/buildroot.git buildroot
cd buildroot && git checkout <TAG_FROM_STEP_1> && cd ..
git -C buildroot rev-parse HEAD
```
Expected: prints the commit SHA the tag points to.

- [ ] **Step 3: Write `pins.lock`** recording the exact pin

```
# ReForge component pins — authoritative source of truth for reproducible builds.
# Format: <component> <kind> <ref> <sha>
buildroot   tag    <TAG>            <SHA_FROM_STEP_2>
# kernel / u-boot / klipper / moonraker / mainsail / guppyscreen added in later plans
```

- [ ] **Step 4: Verify submodule is recorded at the pinned SHA**

Run: `git -C reforge submodule status`
Expected: a line with the pinned SHA (no `+`/`-` prefix indicating drift) for `buildroot`.

- [ ] **Step 5: Commit**

```bash
cd reforge
git add .gitmodules buildroot pins.lock
git commit -m "P1: pin upstream Buildroot <TAG> as submodule + pins.lock"
```

---

## Task 2: BR2_EXTERNAL skeleton

**Files:**
- Create: `reforge/br-external/external.desc`
- Create: `reforge/br-external/external.mk`
- Create: `reforge/br-external/Config.in`

This is the minimum Buildroot needs to recognize our external tree (so we never patch the submodule).

- [ ] **Step 1: Write `external.desc`**

```
name: REFORGE
desc: ReForge — FlashForge AD5M/Pro custom firmware
```

- [ ] **Step 2: Write `external.mk`**

```makefile
include $(sort $(wildcard $(BR2_EXTERNAL_REFORGE_PATH)/package/*/*.mk))
```

- [ ] **Step 3: Write `Config.in`**

```
source "$BR2_EXTERNAL_REFORGE_PATH/package/Config.in"
```

- [ ] **Step 4: Create an empty `package/Config.in` so the source line resolves**

```bash
mkdir -p reforge/br-external/package
: > reforge/br-external/package/Config.in
```

- [ ] **Step 5: Verify Buildroot accepts the external tree**

Run:
```bash
cd reforge/buildroot
make BR2_EXTERNAL=$(realpath ../br-external) O=$(realpath ../output) list-defconfigs 2>&1 | grep -i reforge || echo "no reforge defconfig yet (expected at this step)"
```
Expected: command exits 0; the `External options` section of `make help` would show `REFORGE`. (No defconfig yet — that's Task 3.)

- [ ] **Step 6: Commit**

```bash
cd reforge
git add br-external/external.desc br-external/external.mk br-external/Config.in br-external/package/Config.in
git commit -m "P1: BR2_EXTERNAL skeleton (REFORGE external tree)"
```

---

## Task 3: Minimal Cortex-A7 rootfs defconfig

**Files:**
- Create: `reforge/br-external/configs/reforge_defconfig`
- Create: `reforge/br-external/board/reforge/post-build.sh`
- Create: `reforge/br-external/board/reforge/rootfs-overlay/etc/os-release`

Target the T113-S3: ARM Cortex-A7, hardfp/VFPv4/NEON, glibc (for later Python), busybox init, no kernel, no bootloader. Produce a `rootfs.tar`.

- [ ] **Step 1: Write `reforge_defconfig`** (minimal, no kernel/bootloader)

```
BR2_arm=y
BR2_cortex_a7=y
BR2_ARM_FPU_VFPV4=y
BR2_TOOLCHAIN_BUILDROOT_GLIBC=y
BR2_TOOLCHAIN_BUILDROOT_CXX=y
BR2_SYSTEM_DHCP="eth0"
BR2_TARGET_GENERIC_HOSTNAME="reforge"
BR2_TARGET_GENERIC_ISSUE="Welcome to ReForge"
BR2_ROOTFS_OVERLAY="$(BR2_EXTERNAL_REFORGE_PATH)/board/reforge/rootfs-overlay"
BR2_ROOTFS_POST_BUILD_SCRIPT="$(BR2_EXTERNAL_REFORGE_PATH)/board/reforge/post-build.sh"
BR2_TARGET_ROOTFS_TAR=y
BR2_TARGET_ROOTFS_TAR_XZ=y
# reproducible builds from the start (spec §3/§4) — avoids a Task 6 debug cycle
BR2_REPRODUCIBLE=y
# explicitly no kernel / no bootloader in this foundation plan
# BR2_LINUX_KERNEL is not set
# BR2_TARGET_UBOOT is not set
```

- [ ] **Step 2: Write `post-build.sh`** (placeholder that stamps a build marker)

```sh
#!/bin/sh
# ReForge rootfs post-build hook. Real service install lands in Plan 2.
set -e
TARGET_DIR="$1"
echo "reforge-foundation" > "$TARGET_DIR/etc/reforge-stage"
```

- [ ] **Step 3: Write the overlay `os-release`** (brands the image; also the overlay smoke target)

```
NAME=ReForge
ID=reforge
PRETTY_NAME="ReForge (FlashForge AD5M/Pro)"
```

- [ ] **Step 4: Make post-build executable + verify defconfig loads**

```bash
chmod +x reforge/br-external/board/reforge/post-build.sh
cd reforge/buildroot
make BR2_EXTERNAL=$(realpath ../br-external) O=$(realpath ../output) reforge_defconfig
```
Expected: `configuration written to .../output/.config`, exit 0.

- [ ] **Step 5: Commit**

```bash
cd reforge
git add br-external/configs/reforge_defconfig br-external/board/reforge/
git commit -m "P1: minimal Cortex-A7 rootfs defconfig + overlay"
```

---

## Task 4: Build wrapper (env.sh, build.sh, Makefile)

**Files:**
- Create: `reforge/build_scripts/env.sh`
- Create: `reforge/build_scripts/build.sh`
- Create: `reforge/Makefile`

Wrap the verbose Buildroot invocation so later plans (and CI) call one command.

- [ ] **Step 1: Write `env.sh`**

```sh
# shared build environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REFORGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export BUILDROOT_GIT="$REFORGE_ROOT/buildroot"
export BR2_EXTERNAL_DIR="$REFORGE_ROOT/br-external"
export OUTPUT_DIR="$REFORGE_ROOT/output"
export MULTICORE="-j$(nproc)"
```

- [ ] **Step 2: Write `build.sh`** (verbs: `defconfig`, `rootfs`, `clean`)

```sh
#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
verb="${1:-rootfs}"
br() { make -C "$BUILDROOT_GIT" BR2_EXTERNAL="$BR2_EXTERNAL_DIR" O="$OUTPUT_DIR" "$@"; }
case "$verb" in
  defconfig) br reforge_defconfig ;;
  rootfs)    br reforge_defconfig; br $MULTICORE ;;
  clean)     rm -rf "$OUTPUT_DIR" ;;
  *) echo "usage: build.sh {defconfig|rootfs|clean}"; exit 1 ;;
esac
```

- [ ] **Step 3: Write top-level `Makefile`**

```makefile
BUILD := build_scripts/build.sh
.PHONY: rootfs defconfig clean smoke repro
rootfs:    ; $(BUILD) rootfs
defconfig: ; $(BUILD) defconfig
clean:     ; $(BUILD) clean
smoke:     ; scripts/smoke_rootfs.sh
repro:     ; scripts/repro_check.sh
```

- [ ] **Step 4: Verify the wrapper drives a real build (this is the long one)**

```bash
chmod +x reforge/build_scripts/build.sh
cd reforge && make rootfs
```
Expected: Buildroot downloads + builds toolchain and busybox, ends with `output/images/rootfs.tar.xz` present. Verify:
`ls -la reforge/output/images/rootfs.tar.xz`

- [ ] **Step 5: Commit**

```bash
cd reforge
git add build_scripts/env.sh build_scripts/build.sh Makefile
git commit -m "P1: build wrapper (env.sh, build.sh, Makefile)"
```

---

## Task 5: qemu-user rootfs smoke test

**Files:**
- Create: `reforge/scripts/smoke_rootfs.sh`

The "test" for a rootfs: a binary from it actually executes (correct arch/ABI), and our overlay/branding is present. Uses `qemu-arm-static` with `QEMU_LD_PREFIX` — no root, no binfmt needed.

- [ ] **Step 1: Write the failing smoke test** (before relying on it, it must fail on a missing rootfs)

```sh
#!/bin/sh
# qemu-user smoke test of the built ReForge rootfs.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAR="$ROOT/output/images/rootfs.tar.xz"
EXTRACT="$ROOT/output/smoke-root"
[ -f "$TAR" ] || { echo "FAIL: no rootfs at $TAR"; exit 1; }
rm -rf "$EXTRACT"; mkdir -p "$EXTRACT"
tar -C "$EXTRACT" -xf "$TAR"

# 1) busybox must be ARM and must run under qemu-user
file "$EXTRACT/bin/busybox" | grep -q "ARM" || { echo "FAIL: busybox not ARM"; exit 1; }
OUT=$(QEMU_LD_PREFIX="$EXTRACT" qemu-arm-static "$EXTRACT/bin/busybox" echo reforge-ok)
[ "$OUT" = "reforge-ok" ] || { echo "FAIL: busybox did not run under qemu ($OUT)"; exit 1; }

# 2) our overlay + post-build markers must be present
grep -q "ID=reforge" "$EXTRACT/etc/os-release" || { echo "FAIL: os-release branding missing"; exit 1; }
[ "$(cat "$EXTRACT/etc/reforge-stage")" = "reforge-foundation" ] || { echo "FAIL: post-build marker missing"; exit 1; }

echo "PASS: rootfs runs under qemu-user and is branded ReForge"
```

- [ ] **Step 2: Run it BEFORE a build to confirm it fails correctly**

```bash
chmod +x reforge/scripts/smoke_rootfs.sh
rm -f reforge/output/images/rootfs.tar.xz
cd reforge && ./scripts/smoke_rootfs.sh; echo "exit=$?"
```
Expected: `FAIL: no rootfs at ...` and `exit=1`.

- [ ] **Step 3: Build, then run the smoke test to confirm PASS**

```bash
cd reforge && make rootfs && make smoke
```
Expected: ends with `PASS: rootfs runs under qemu-user and is branded ReForge`.

- [ ] **Step 4: Commit**

```bash
cd reforge
git add scripts/smoke_rootfs.sh
git commit -m "P1: qemu-user rootfs smoke test"
```

---

## Task 6: Reproducibility check

**Files:**
- Create: `reforge/scripts/repro_check.sh`

Reproducible builds are a spec requirement (§3/§4). Two clean builds of the rootfs must yield identical content.

- [ ] **Step 1: Write `repro_check.sh`** (compare extracted-tree manifests, not the tar — timestamps in tar headers differ legitimately)

```sh
#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
manifest() { # $1 = extract dir -> sorted "mode size sha path"
  cd "$1"; find . -type f -printf '%m %s ' -exec sha256sum {} \; | sort -k4
}
hashtree() {
  rm -rf "$ROOT/output/repro-$1"; mkdir -p "$ROOT/output/repro-$1"
  tar -C "$ROOT/output/repro-$1" -xf "$ROOT/output/images/rootfs.tar.xz"
  manifest "$ROOT/output/repro-$1" > "$ROOT/output/repro-$1.manifest"
}
cd "$ROOT"
make clean && make rootfs && hashtree a
make clean && make rootfs && hashtree b
if diff -u output/repro-a.manifest output/repro-b.manifest; then
  echo "PASS: reproducible (identical file manifests)"
else
  echo "FAIL: build is not reproducible"; exit 1
fi
```

- [ ] **Step 2: Run it**

Run: `cd reforge && chmod +x scripts/repro_check.sh && make repro`
Expected: `PASS: reproducible (identical file manifests)`.
(`BR2_REPRODUCIBLE=y` is already set in the defconfig from Task 3, so this should pass first try. If it still fails, record the offending paths — remaining causes are usually package-specific embedded build paths/timestamps; fix the specific package and re-run.)

- [ ] **Step 3: Commit**

```bash
cd reforge
git add scripts/repro_check.sh
git commit -m "P1: reproducibility check (twin-build manifest diff)"
```

---

## Task 7: CI workflow

**Files:**
- Create: `reforge/.github/workflows/build.yml`

Lock the foundation behind CI so later plans can't silently break it.

- [ ] **Step 1: Write `build.yml`**

```yaml
name: build
on: [push, pull_request]
jobs:
  rootfs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - name: install deps
        run: sudo apt-get update && sudo apt-get install -y build-essential qemu-user-static file xz-utils unzip bc cpio rsync
      - name: build rootfs
        run: make rootfs
        working-directory: reforge
      - name: smoke test
        run: make smoke
        working-directory: reforge
```

- [ ] **Step 2: Validate the YAML locally**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('reforge/.github/workflows/build.yml')); print('yaml ok')"`
Expected: `yaml ok`.

- [ ] **Step 3: Commit**

```bash
cd reforge
git add .github/workflows/build.yml
git commit -m "P1: CI — build rootfs + qemu smoke on push/PR"
```

---

## Done criteria for Plan 1

- [ ] Golden eMMC dump verified full-size + checksum-valid (`verify_dump.sh` PASS); `RUNBOOK.md` written.
- [ ] Upstream Buildroot pinned as submodule; `pins.lock` records the exact tag+SHA.
- [ ] `make rootfs` produces `output/images/rootfs.tar.xz` from a fresh tree.
- [ ] `make smoke` PASSES (rootfs binary runs under qemu-user, branded ReForge).
- [ ] `make repro` PASSES (twin builds yield identical manifests).
- [ ] CI green on push.
- [ ] Buildroot submodule is unmodified (no patches to the upstream tree) — confirm `git -C buildroot status` is clean.

**Next plan:** Plan 2 — P2 Core stack (Klipper host + Moonraker + Mainsail + GuppyScreen as `BR2_EXTERNAL` packages, started in chroot).
</content>
