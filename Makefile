BUILD := build_scripts/build.sh
.PHONY: rootfs defconfig clean smoke repro integration
rootfs:      ; $(BUILD) rootfs
defconfig:   ; $(BUILD) defconfig
clean:       ; $(BUILD) clean
smoke:       ; scripts/smoke_rootfs.sh
repro:       ; scripts/repro_check.sh
integration: ; scripts/chroot_integration.sh
