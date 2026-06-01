BUILD := tools/build/build.sh
.PHONY: rootfs defconfig clean smoke repro integration guppy smoke-guppy tgz validate-loopback \
        qemu-kernel qemu-initramfs qemu-smoke qemu-all \
        qemu-stock-rootfs qemu-run qemu-update qemu-render
rootfs:            ; $(BUILD) rootfs
defconfig:         ; $(BUILD) defconfig
clean:             ; $(BUILD) clean
smoke:             ; tests/smoke/smoke_rootfs.sh
repro:             ; tests/smoke/repro_check.sh
integration:       ; tests/smoke/chroot_integration.sh
guppy:             ; $(BUILD) rootfs guppyscreen
smoke-guppy:       ; tests/smoke/smoke_guppy.sh
tgz:               ; packaging/build-tgz.sh
validate-loopback: ; sudo tests/loopback-install-test.sh

# --- P3 Task 4: qemu virt test kernel (vendor 5.4.61, ARCH_SUNXI=n, 800x480x32 fb) ---
# build zImage + initramfs + run smoke test
qemu-kernel:       ; tests/qemu-harness/build-test-kernel.sh kernel
qemu-initramfs:    ; tests/qemu-harness/build-test-kernel.sh initramfs
qemu-smoke:        ; tests/qemu-harness/build-test-kernel.sh smoke
qemu-all:          ; tests/qemu-harness/build-test-kernel.sh all

# --- P3 Task 5: extract stock rootfs (p6) from golden eMMC dump + run wrapper ---
# Extract mmcblk0p6 (~1.31 GB ext4) from tools/recovery/golden-kunos-*.img.gz.
# Requires sudo for losetup + mount.  Output: tests/qemu-harness/build/stock-rootfs.ext4
qemu-stock-rootfs: ; sudo tests/qemu-harness/extract-stock-rootfs.sh

# Generic qemu run helper: pass ROOT=<image-or-cpio> and optionally QEMU_ARGS=...
# Example: make qemu-run ROOT=tests/qemu-harness/build/stock-rootfs.ext4
# Example: make qemu-run ROOT=tests/qemu-harness/build/initramfs.cpio.gz --vnc
ROOT ?= tests/qemu-harness/build/initramfs.cpio.gz
qemu-run:          ; tests/qemu-harness/run-qemu.sh $(ROOT) $(QEMU_ARGS)

# --- P3 Task 6: qemu update-process test (install → ReForge boots) ---
# Needs sudo for loopback mount.  Timeout generous (qemu + python startup is slow).
qemu-update:       ; sudo tests/qemu-harness/update-process-test.sh

# --- P3 Task 7: GuppyScreen render test (800x480 fb, screendump non-blank) ---
# Boots ReForge with SCREEN_MODE=GUPPY under --vnc (virtio-gpu /dev/fb0) and
# asserts GuppyScreen draws a non-blank frame.  Needs sudo for loop mount.
# Output: tests/qemu-harness/build/guppy-screenshot.ppm (gitignored)
qemu-render:       ; sudo tests/qemu-harness/reforge-render-test.sh
