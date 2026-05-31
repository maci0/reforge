BUILD := build_scripts/build.sh
.PHONY: rootfs defconfig clean smoke repro integration guppy smoke-guppy tgz validate-loopback \
        qemu-kernel qemu-initramfs qemu-smoke qemu-all \
        qemu-stock-rootfs qemu-run
rootfs:            ; $(BUILD) rootfs
defconfig:         ; $(BUILD) defconfig
clean:             ; $(BUILD) clean
smoke:             ; scripts/smoke_rootfs.sh
repro:             ; scripts/repro_check.sh
integration:       ; scripts/chroot_integration.sh
guppy:             ; $(BUILD) rootfs guppyscreen
smoke-guppy:       ; scripts/smoke_guppy.sh
tgz:               ; packaging/build-tgz.sh
validate-loopback: ; sudo validation/loopback-install-test.sh

# --- P3 Task 4: qemu virt test kernel (vendor 5.4.61, ARCH_SUNXI=n, 800x480x32 fb) ---
# build zImage + initramfs + run smoke test
qemu-kernel:       ; validation/qemu-harness/build-test-kernel.sh kernel
qemu-initramfs:    ; validation/qemu-harness/build-test-kernel.sh initramfs
qemu-smoke:        ; validation/qemu-harness/build-test-kernel.sh smoke
qemu-all:          ; validation/qemu-harness/build-test-kernel.sh all

# --- P3 Task 5: extract stock rootfs (p6) from golden eMMC dump + run wrapper ---
# Extract mmcblk0p6 (~1.31 GB ext4) from recovery/golden-kunos-*.img.gz.
# Requires sudo for losetup + mount.  Output: validation/qemu-harness/build/stock-rootfs.ext4
qemu-stock-rootfs: ; sudo validation/qemu-harness/extract-stock-rootfs.sh

# Generic qemu run helper: pass ROOT=<image-or-cpio> and optionally QEMU_ARGS=...
# Example: make qemu-run ROOT=validation/qemu-harness/build/stock-rootfs.ext4
# Example: make qemu-run ROOT=validation/qemu-harness/build/initramfs.cpio.gz --vnc
ROOT ?= validation/qemu-harness/build/initramfs.cpio.gz
qemu-run:          ; validation/qemu-harness/run-qemu.sh $(ROOT) $(QEMU_ARGS)
