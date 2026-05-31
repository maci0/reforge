BUILD := build_scripts/build.sh
.PHONY: rootfs defconfig clean smoke repro integration guppy smoke-guppy tgz validate-loopback qemu-kernel qemu-initramfs qemu-smoke qemu-all
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
