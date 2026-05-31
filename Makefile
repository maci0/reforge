BUILD := build_scripts/build.sh
.PHONY: rootfs defconfig clean smoke repro integration guppy smoke-guppy
rootfs:      ; $(BUILD) rootfs
defconfig:   ; $(BUILD) defconfig
clean:       ; $(BUILD) clean
smoke:       ; scripts/smoke_rootfs.sh
repro:       ; scripts/repro_check.sh
integration: ; scripts/chroot_integration.sh
guppy:       ; $(BUILD) rootfs guppyscreen
smoke-guppy: ; scripts/smoke_guppy.sh
