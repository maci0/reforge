#!/usr/bin/env bash
# =============================================================================
# ReForge P3 Task 4: build-test-kernel.sh
# Builds a TEST-ONLY zImage for qemu -M virt with 800x480x32 framebuffer.
# NEVER shipped — purely a qemu test bed.
#
# Source: Allwinner Tina BSP kernel (vendor 5.4.61, same ABI as stock).
# Fix applied: ARCH_SUNXI=n so drivers/clk/sunxi/ (broken vs vendor clk-factors)
#              is not compiled.  A qemu -M virt kernel needs ZERO sunxi drivers.
#
# Fallback (only if vendor truly unbuildable after real effort):
#   modules/zram-bsp/linux-5.4.61  (mainline 5.4.61, same version, builds clean)
#   DO NOT use 6.x mainline.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"

VENDOR_KSRC="${REPO_ROOT}/modules/zram-bsp/tina-bsp-kernel"
MAINLINE_KSRC="${REPO_ROOT}/modules/zram-bsp/linux-5.4.61"   # fallback (5.4.61 only)
CROSS="${REPO_ROOT}/modules/zram-bsp/gcc-9.5.0-nolibc/arm-linux-gnueabi/bin/arm-linux-gnueabi-"
JOBS="${BUILD_JOBS:-$(nproc)}"

log()  { echo "[build-test-kernel] $*"; }
die()  { echo "[build-test-kernel] ERROR: $*" >&2; exit 1; }
warn() { echo "[build-test-kernel] WARN:  $*" >&2; }

# ---------------------------------------------------------------------------
# Step 0: clean mainline 6.x leftovers, recreate build dir
# ---------------------------------------------------------------------------
clean_build_dir() {
    log "Cleaning build directory of prior leftovers ..."
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    log "Build dir ready: ${BUILD_DIR}"
}

# ---------------------------------------------------------------------------
# scripts/config helper — writes directly into $O/.config
# Usage: sc_enable SYMBOL | sc_disable SYMBOL | sc_module SYMBOL
# Note: scripts/config adds CONFIG_ prefix automatically; pass bare symbol name.
# ---------------------------------------------------------------------------
sc() {
    local KSRC="$1"; shift
    local KBUILD="$1"; shift
    "${KSRC}/scripts/config" --file "${KBUILD}/.config" "$@"
}

# ---------------------------------------------------------------------------
# Build vendor kernel (Tina BSP 5.4.61)
# ---------------------------------------------------------------------------
build_vendor_kernel() {
    local KSRC="${VENDOR_KSRC}"
    local KBUILD="${BUILD_DIR}/kbuild"

    log "=== VENDOR PATH: Tina BSP 5.4.61 + multi_v7_defconfig ==="
    log "  KSRC  : ${KSRC}"
    log "  O     : ${KBUILD}"
    log "  CROSS : ${CROSS}gcc"
    log "  JOBS  : ${JOBS}"

    [[ -f "${KSRC}/Makefile" ]] || die "Vendor kernel not found at ${KSRC}"
    [[ -x "${CROSS}gcc" ]]     || die "Cross-compiler not found: ${CROSS}gcc"

    mkdir -p "${KBUILD}"

    # Common make arguments (no -j here; add per-target as needed)
    local M=(
        make -C "${KSRC}"
        O="${KBUILD}"
        ARCH=arm
        CROSS_COMPILE="${CROSS}"
    )

    # -------------------------------------------------------------------
    # 1. Base config
    # -------------------------------------------------------------------
    log "Step 1: make multi_v7_defconfig ..."
    "${M[@]}" multi_v7_defconfig

    # -------------------------------------------------------------------
    # 2. Apply virt-specific config fragment via scripts/config
    #    KEY FIX: disable ARCH_SUNXI so drivers/clk/sunxi/ is never built.
    #             The broken clk-mod0.c / clk-factors is inside sunxi/ and
    #             a -M virt kernel needs zero sunxi drivers.
    # -------------------------------------------------------------------
    log "Step 2: applying virt config fragment (ARCH_SUNXI=n) ..."

    # -- DISABLE all sunxi/allwinner drivers --
    sc "${KSRC}" "${KBUILD}" \
        --disable ARCH_SUNXI \
        --disable CLK_SUNXI \
        --disable CLK_SUNXI_CLOCKS \
        --disable CLK_SUNXI_DDR \
        --disable CLK_SUNXI_PRCM_SUN6I \
        --disable CLK_SUNXI_PRCM_SUN8I \
        --disable CLK_SUNXI_PRCM_SUN9I \
        --disable SUNXI_CCU \
        --disable COMMON_CLK_SUNXI

    # -- ENABLE virt platform --
    sc "${KSRC}" "${KBUILD}" \
        --enable ARCH_VIRT

    # -- ENABLE VirtIO transport + devices --
    sc "${KSRC}" "${KBUILD}" \
        --enable VIRTIO \
        --enable VIRTIO_PCI \
        --enable VIRTIO_MMIO \
        --enable VIRTIO_BLK \
        --enable VIRTIO_NET \
        --enable VIRTIO_CONSOLE \
        --enable VIRTIO_INPUT

    # -- ENABLE DRM + virtio-gpu --
    sc "${KSRC}" "${KBUILD}" \
        --enable DRM \
        --enable DRM_KMS_HELPER \
        --enable DRM_TTM \
        --enable DRM_VIRTIO_GPU

    # -- ENABLE framebuffer (FB_SIMPLE for ramfb / simple-framebuffer) --
    sc "${KSRC}" "${KBUILD}" \
        --enable FB \
        --enable FB_SIMPLE \
        --enable FRAMEBUFFER_CONSOLE

    # -- ENABLE filesystems + initramfs --
    sc "${KSRC}" "${KBUILD}" \
        --enable EXT4_FS \
        --enable BLK_DEV_INITRD

    # -- ENABLE device management --
    sc "${KSRC}" "${KBUILD}" \
        --enable DEVTMPFS \
        --enable DEVTMPFS_MOUNT

    # -- ENABLE PL011 serial console (virt machine UART) --
    sc "${KSRC}" "${KBUILD}" \
        --enable SERIAL_AMBA_PL011 \
        --enable SERIAL_AMBA_PL011_CONSOLE

    # -------------------------------------------------------------------
    # 3. Resolve dependencies, filling in any new defaults
    # -------------------------------------------------------------------
    log "Step 3: make olddefconfig (resolve deps) ..."
    "${M[@]}" olddefconfig

    # -------------------------------------------------------------------
    # 4. Verify ARCH_SUNXI is truly OFF and virtio/fb are ON
    # -------------------------------------------------------------------
    log "Step 4: config verification ..."
    local CFG="${KBUILD}/.config"

    local FAIL=0
    # These MUST be not-set (the known broken drivers)
    for sym in CONFIG_ARCH_SUNXI CONFIG_CLK_SUNXI CONFIG_CLK_SUNXI_CLOCKS; do
        if grep -q "^${sym}=y" "${CFG}"; then
            warn "  ${sym} is still =y — this may cause build failures!"
            FAIL=1
        else
            log "  OK (disabled): ${sym}"
        fi
    done

    # These MUST be enabled
    for sym in CONFIG_ARCH_VIRT CONFIG_VIRTIO_PCI CONFIG_VIRTIO_MMIO \
               CONFIG_BLK_DEV_INITRD CONFIG_DEVTMPFS \
               CONFIG_SERIAL_AMBA_PL011 CONFIG_SERIAL_AMBA_PL011_CONSOLE; do
        if grep -q "^${sym}=y" "${CFG}"; then
            log "  OK (enabled):  ${sym}"
        else
            warn "  ${sym} not =y in final config"
        fi
    done

    # DRM_VIRTIO_GPU may be =y or =m — either works
    if grep -qE "^CONFIG_DRM_VIRTIO_GPU=[ym]" "${CFG}"; then
        log "  OK: CONFIG_DRM_VIRTIO_GPU enabled"
    else
        warn "  CONFIG_DRM_VIRTIO_GPU not enabled — virtio-gpu won't work"
    fi

    # FB_SIMPLE for ramfb
    if grep -q "^CONFIG_FB_SIMPLE=y" "${CFG}"; then
        log "  OK: CONFIG_FB_SIMPLE=y"
    else
        warn "  CONFIG_FB_SIMPLE not y — simple framebuffer won't work"
    fi

    [[ "${FAIL}" -eq 0 ]] || warn "Config issues found above — build may fail"

    # -------------------------------------------------------------------
    # 5. Build zImage
    #    If specific drivers still fail, add --disable for that CONFIG here.
    #    Iterate until clean (see KNOWN FAILURES comment below).
    # -------------------------------------------------------------------
    log "Step 5: make zImage (10-30 min) ..."
    log "  Build log: ${BUILD_DIR}/build.log"
    local t0
    t0=$(date +%s)

    if ! "${M[@]}" -j"${JOBS}" zImage 2>&1 | tee "${BUILD_DIR}/build.log"; then
        local t1
        t1=$(date +%s)
        log "Build failed after $(( t1 - t0 ))s — check ${BUILD_DIR}/build.log"
        log ""
        log "Last 40 lines of build log:"
        tail -40 "${BUILD_DIR}/build.log" >&2
        return 1
    fi

    local t1
    t1=$(date +%s)
    log "Build completed in $(( t1 - t0 ))s"

    local ZIMG="${KBUILD}/arch/arm/boot/zImage"
    [[ -f "${ZIMG}" ]] || die "zImage not found after build: ${ZIMG}"
    cp "${ZIMG}" "${BUILD_DIR}/zImage"
    log "zImage -> ${BUILD_DIR}/zImage ($(stat -c%s "${BUILD_DIR}/zImage") bytes)"

    # Record what source we used
    echo "vendor-5.4.61" > "${BUILD_DIR}/kernel-source.txt"
    "${M[@]}" kernelversion >> "${BUILD_DIR}/kernel-source.txt" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Build mainline 5.4.61 fallback (ONLY if vendor is truly broken)
# ---------------------------------------------------------------------------
build_mainline_fallback() {
    log ""
    log "=== FALLBACK: mainline Linux 5.4.61 ==="
    log "  (vendor BSP failed; using clean mainline of same version)"
    log "  NOTE: 5.4.61 ABI maintained — only source differs from vendor BSP"

    # Extract if not already done
    if [[ ! -f "${MAINLINE_KSRC}/Makefile" ]]; then
        local TARBALL="${REPO_ROOT}/modules/zram-bsp/linux-5.4.61.tar.xz"
        [[ -f "${TARBALL}" ]] || die "Mainline tarball not found: ${TARBALL}"
        log "Extracting mainline 5.4.61 ..."
        mkdir -p "${MAINLINE_KSRC}"
        tar -xJf "${TARBALL}" -C "${REPO_ROOT}/modules/zram-bsp/" 2>&1 | tail -5
        # tar may extract as linux-5.4.61/; check
        if [[ ! -f "${MAINLINE_KSRC}/Makefile" ]]; then
            # Try moving extracted dir
            local extracted
            extracted=$(find "${REPO_ROOT}/modules/zram-bsp" -maxdepth 1 -name "linux-5.4*" -type d | head -1)
            [[ -n "${extracted}" ]] || die "Cannot find extracted mainline source"
            [[ "${extracted}" == "${MAINLINE_KSRC}" ]] || mv "${extracted}" "${MAINLINE_KSRC}"
        fi
        log "Mainline extracted to ${MAINLINE_KSRC}"
    fi

    local KSRC="${MAINLINE_KSRC}"
    local KBUILD="${BUILD_DIR}/kbuild"
    mkdir -p "${KBUILD}"

    local M=(
        make -C "${KSRC}"
        O="${KBUILD}"
        ARCH=arm
        CROSS_COMPILE="${CROSS}"
    )

    log "Step 1: make multi_v7_defconfig ..."
    "${M[@]}" multi_v7_defconfig

    log "Step 2: applying virt config fragment ..."
    sc "${KSRC}" "${KBUILD}" \
        --enable ARCH_VIRT \
        --enable VIRTIO \
        --enable VIRTIO_PCI \
        --enable VIRTIO_MMIO \
        --enable VIRTIO_BLK \
        --enable VIRTIO_NET \
        --enable VIRTIO_CONSOLE \
        --enable VIRTIO_INPUT \
        --enable DRM \
        --enable DRM_KMS_HELPER \
        --enable DRM_TTM \
        --enable DRM_VIRTIO_GPU \
        --enable FB \
        --enable FB_SIMPLE \
        --enable FRAMEBUFFER_CONSOLE \
        --enable EXT4_FS \
        --enable BLK_DEV_INITRD \
        --enable DEVTMPFS \
        --enable DEVTMPFS_MOUNT \
        --enable SERIAL_AMBA_PL011 \
        --enable SERIAL_AMBA_PL011_CONSOLE

    log "Step 3: olddefconfig ..."
    "${M[@]}" olddefconfig

    log "Step 4: make zImage ..."
    log "  Build log: ${BUILD_DIR}/build.log"
    local t0
    t0=$(date +%s)

    "${M[@]}" -j"${JOBS}" zImage 2>&1 | tee "${BUILD_DIR}/build.log" \
        || die "Mainline 5.4.61 build failed — see ${BUILD_DIR}/build.log"

    local t1
    t1=$(date +%s)
    log "Mainline build completed in $(( t1 - t0 ))s"

    local ZIMG="${KBUILD}/arch/arm/boot/zImage"
    [[ -f "${ZIMG}" ]] || die "zImage not found: ${ZIMG}"
    cp "${ZIMG}" "${BUILD_DIR}/zImage"
    log "zImage -> ${BUILD_DIR}/zImage ($(stat -c%s "${BUILD_DIR}/zImage") bytes)"

    echo "mainline-5.4.61" > "${BUILD_DIR}/kernel-source.txt"
}

# ---------------------------------------------------------------------------
# Build initramfs: tiny busybox init that probes /dev/fb0 geometry
# ---------------------------------------------------------------------------
build_initramfs() {
    log "=== Building probe initramfs ==="
    local INITRD_DIR="${BUILD_DIR}/initramfs-root"
    rm -rf "${INITRD_DIR}"
    mkdir -p "${INITRD_DIR}"/{bin,proc,sys,dev,mnt,lib}

    # Primary strategy: compile a minimal static ARM init from configs/init.c
    # Uses ARM EABI syscalls directly (no libc) — zero dynamic linking issues.
    # Cross-compiled with the same GCC 9.5 used for zram modules.
    local USE_STATIC_INIT=0
    local INIT_C="${HARNESS_DIR}/configs/init.c"
    if [[ -f "${INIT_C}" ]]; then
        log "  Compiling static ARM init from configs/init.c ..."
        if "${CROSS}gcc" \
            -static \
            -nostdlib \
            -nostartfiles \
            -ffreestanding \
            -Os \
            -march=armv7-a \
            -mabi=aapcs \
            -o "${INITRD_DIR}/init" \
            "${INIT_C}" 2>&1; then
            chmod +x "${INITRD_DIR}/init"
            log "  Static ARM init compiled OK: $(stat -c%s "${INITRD_DIR}/init") bytes"
            log "  $(file "${INITRD_DIR}/init")"
            USE_STATIC_INIT=1
        else
            log "  WARNING: static init compile failed"
            rm -f "${INITRD_DIR}/init"
        fi
    fi

    # Fallback: extract busybox + shared libs from Plan-1 rootfs
    local USE_BUSYBOX=0
    local BB="${INITRD_DIR}/bin/busybox"
    local ROOTFS_XZ="${REPO_ROOT}/output/images/rootfs.tar.xz"

    if [[ "${USE_STATIC_INIT}" -eq 0 ]]; then
        if [[ -f "${ROOTFS_XZ}" ]]; then
            log "  Falling back to busybox from Plan-1 rootfs ..."
            local BBEXTRACT
            BBEXTRACT=$(mktemp -d)
            # Extract busybox + all libs into temp dir
            (cd "${BBEXTRACT}" && tar -xJf "${ROOTFS_XZ}" 2>/dev/null || true)
            local found
            found=$(find "${BBEXTRACT}" -name 'busybox' -type f 2>/dev/null | head -1)
            if [[ -n "${found}" ]]; then
                if file "${found}" 2>/dev/null | grep -qi 'ARM\|arm'; then
                    cp "${found}" "${BB}"
                    chmod +x "${BB}"
                    USE_BUSYBOX=1
                    log "  Found ARM busybox from rootfs ($(file "${BB}"))"
                    # Copy needed shared libs
                    for lib in ld-linux-armhf.so.3 libc.so.6 libresolv.so.2 libdl.so.2 libm.so.6; do
                        local libsrc="${BBEXTRACT}/lib/${lib}"
                        [[ -f "${libsrc}" ]] && cp -P "${libsrc}" "${INITRD_DIR}/lib/" 2>/dev/null || true
                        [[ -L "${libsrc}" ]] && cp -P "${libsrc}" "${INITRD_DIR}/lib/" 2>/dev/null || true
                    done
                    log "  Copied libs: $(ls "${INITRD_DIR}/lib/" 2>/dev/null | tr '\n' ' ')"
                fi
            fi
            rm -rf "${BBEXTRACT}"
        fi
    fi

    if [[ "${USE_STATIC_INIT}" -eq 0 && "${USE_BUSYBOX}" -eq 0 ]]; then
        log "  WARNING: no ARM init available — kernel will boot but init will panic"
        log "           'Linux version 5.4.61' will still appear in the log"
    fi

    # -------------------------------------------------------------------
    # Create device nodes
    # -------------------------------------------------------------------
    mknod -m 600 "${INITRD_DIR}/dev/console" c 5 1 2>/dev/null || true
    mknod -m 666 "${INITRD_DIR}/dev/null"    c 1 3 2>/dev/null || true
    mknod -m 666 "${INITRD_DIR}/dev/tty"     c 5 0 2>/dev/null || true

    # -------------------------------------------------------------------
    # Create busybox symlinks (if ARM binary found)
    # -------------------------------------------------------------------
    # If we only have busybox (not static init), create busybox symlinks
    # using a hardcoded list of common applets (can't run armhf on x86 host)
    # -------------------------------------------------------------------
    if [[ "${USE_STATIC_INIT}" -eq 0 && "${USE_BUSYBOX}" -eq 1 ]]; then
        for applet in sh ash cat echo ls mount dmesg sleep poweroff halt reboot; do
            ln -sf busybox "${INITRD_DIR}/bin/${applet}" 2>/dev/null || true
        done
        log "  Created busybox symlinks for: sh ash cat echo ls mount dmesg sleep poweroff halt"
    fi

    # -------------------------------------------------------------------
    # Write /init shell script (if we don't have a static binary already)
    # -------------------------------------------------------------------
    if [[ "${USE_STATIC_INIT}" -eq 0 ]]; then
        # Write shell script init (requires ARM sh/busybox in /bin)
        cat > "${INITRD_DIR}/init" << 'INIT_EOF'
#!/bin/sh
# ReForge qemu-virt framebuffer probe init
mount -t proc     none /proc  2>/dev/null || true
mount -t sysfs    none /sys   2>/dev/null || true
mount -t devtmpfs none /dev   2>/dev/null || true

echo ""
echo "========================================="
echo "  ReForge qemu-virt boot probe"
echo "========================================="
echo ""

# Small delay for device enumeration
sleep 1

echo "--- /sys/class/graphics/fb0 ---"
if [ -d /sys/class/graphics/fb0 ]; then
    echo "virtual_size:   $(cat /sys/class/graphics/fb0/virtual_size   2>/dev/null || echo N/A)"
    echo "bits_per_pixel: $(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null || echo N/A)"
    echo "name:           $(cat /sys/class/graphics/fb0/name           2>/dev/null || echo N/A)"
else
    echo "fb0: not found"
    echo "available graphics:"
    ls /sys/class/graphics/ 2>/dev/null || echo "  (none)"
fi

echo ""
echo "--- dmesg (fb/drm/virtio) ---"
dmesg 2>/dev/null | grep -iE 'fb|framebuffer|drm|virtio|800|pixel' | head -30 || true

echo ""
echo "========================================="
echo "  PROBE DONE"
echo "========================================="

# Halt cleanly
echo o > /proc/sysrq-trigger 2>/dev/null \
  || poweroff -f 2>/dev/null \
  || halt -f 2>/dev/null \
  || sleep 999
INIT_EOF
        chmod +x "${INITRD_DIR}/init"
        log "  Using shell script /init (requires ARM sh/busybox)"
    else
        log "  /init is compiled static ARM binary (no shell needed)"
    fi

    # -------------------------------------------------------------------
    # Pack as cpio.gz
    # -------------------------------------------------------------------
    log "Packing initramfs.cpio.gz ..."
    (
        cd "${INITRD_DIR}"
        find . | cpio -H newc -o 2>/dev/null
    ) | gzip -9 > "${BUILD_DIR}/initramfs.cpio.gz"

    local sz
    sz=$(stat -c%s "${BUILD_DIR}/initramfs.cpio.gz")
    log "initramfs.cpio.gz: ${sz} bytes -> ${BUILD_DIR}/initramfs.cpio.gz"
}

# ---------------------------------------------------------------------------
# Smoke test: boot in qemu -M virt, verify fb0 geometry
#
# FB pinning method: -device virtio-gpu-pci,xres=800,yres=480
#   The virtio-gpu DRM driver registers /dev/fb0 via DRM fbdev emulation
#   (CONFIG_DRM_VIRTIO_GPU=y + CONFIG_DRM_FBDEV_EMULATION=y).
#   Resolution is fixed at 800x480, 32bpp xRGB8888 (virtio_gpudrmfb).
#
#   IMPORTANT: use -M virt,highmem=off to keep the PCI ECAM address below
#   4 GiB.  Without highmem=off the pci-host-generic driver gets -EBUSY
#   (address conflict on 64-bit highmem window) and the whole PCI bus fails
#   to probe, so virtio-gpu never appears.
#
#   -device ramfb was tried but requires EDK2/UEFI pflash firmware to populate
#   the simple-framebuffer DT node; without firmware it silently does nothing.
# ---------------------------------------------------------------------------
run_smoke_test() {
    log "=== Smoke test: qemu -M virt boot ==="
    local ZIMAGE="${BUILD_DIR}/zImage"
    local INITRD="${BUILD_DIR}/initramfs.cpio.gz"
    local LOGFILE="${BUILD_DIR}/qemu-smoke.log"

    [[ -f "${ZIMAGE}" ]] || die "zImage not found: ${ZIMAGE}"
    [[ -f "${INITRD}" ]] || die "initramfs not found: ${INITRD}"

    command -v qemu-system-arm >/dev/null 2>&1 \
        || die "qemu-system-arm not found in PATH"

    log "  kernel : ${ZIMAGE}"
    log "  initrd : ${INITRD}"
    log "  log    : ${LOGFILE}"
    log "  timeout: 120s"
    log ""
    log "FB pinning: -M virt,highmem=off -device virtio-gpu-pci,xres=800,yres=480"
    log "  => DRM virtio-gpu registers fb0 as virtio_gpudrmfb at 800x480x32"
    log "Console:    ttyAMA0 (PL011 UART on -M virt)"

    timeout 120 qemu-system-arm \
        -M virt,highmem=off \
        -cpu cortex-a7 \
        -m 256 \
        -nographic \
        -kernel "${ZIMAGE}" \
        -initrd "${INITRD}" \
        -device virtio-gpu-pci,xres=800,yres=480 \
        -append "console=ttyAMA0,115200 earlyprintk loglevel=8 rdinit=/init" \
        2>&1 | tee "${LOGFILE}" || true

    echo ""
    log "=== Smoke test results ==="
    echo ""

    grep -iE 'Linux version|Freeing init|fb0|800|virtual_size|bits_per_pixel|virtio.gpu|framebuffer|Kernel panic|Oops|end Kernel' \
        "${LOGFILE}" | head -40 || echo "(no matching lines)"
    echo ""

    local BOOTED=0 FB_FOUND=0 SIZE_OK=0 BPP_OK=0

    grep -q 'Linux version'          "${LOGFILE}" && BOOTED=1
    grep -q 'fb0'                    "${LOGFILE}" && FB_FOUND=1
    grep -qE '800,480|800x480'       "${LOGFILE}" && SIZE_OK=1
    grep -qE 'bits_per_pixel: 32|bpp.*32|32.*bpp' "${LOGFILE}" && BPP_OK=1

    if [[ "${BOOTED}" -eq 1 ]]; then
        log "PASS: kernel booted ('Linux version' found)"
        grep "Linux version" "${LOGFILE}" | head -2
    else
        log "FAIL: kernel did not boot"
    fi

    if [[ "${FB_FOUND}" -eq 1 ]]; then
        log "PASS: fb0 device appeared"
    else
        log "FAIL: fb0 not found in log"
    fi

    if [[ "${SIZE_OK}" -eq 1 ]]; then
        log "PASS: 800x480 geometry confirmed in log"
    else
        log "FAIL: 800x480 not found in log"
    fi

    if [[ "${BPP_OK}" -eq 1 ]]; then
        log "PASS: 32bpp confirmed"
    else
        log "FAIL: 32bpp not found in log"
    fi

    echo ""
    log "Full log: ${LOGFILE}"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main() {
    local MODE="${1:-all}"

    log "ReForge P3 Task 4: qemu virt test kernel"
    log "  Repo root : ${REPO_ROOT}"
    log "  Build dir : ${BUILD_DIR}"
    log "  Mode      : ${MODE}"
    echo ""

    case "${MODE}" in
        clean)
            clean_build_dir
            ;;
        kernel)
            clean_build_dir
            if ! build_vendor_kernel; then
                warn "Vendor BSP build failed — attempting mainline 5.4.61 fallback"
                build_mainline_fallback
            fi
            ;;
        initramfs)
            build_initramfs
            ;;
        smoke)
            run_smoke_test
            ;;
        all)
            clean_build_dir
            if ! build_vendor_kernel; then
                warn "Vendor BSP build failed — attempting mainline 5.4.61 fallback"
                build_mainline_fallback
            fi
            build_initramfs
            run_smoke_test
            ;;
        *)
            echo "Usage: $0 [clean|kernel|initramfs|smoke|all]"
            echo "  clean      — remove build dir"
            echo "  kernel     — build zImage only (vendor 5.4.61)"
            echo "  initramfs  — build probe initramfs only"
            echo "  smoke      — run qemu boot test only"
            echo "  all        — clean + kernel + initramfs + smoke (default)"
            exit 1
            ;;
    esac

    log "Done."
}

main "$@"
