BUILD := build_scripts/build.sh
.PHONY: rootfs defconfig clean smoke repro
rootfs:    ; $(BUILD) rootfs
defconfig: ; $(BUILD) defconfig
clean:     ; $(BUILD) clean
smoke:     ; scripts/smoke_rootfs.sh
repro:     ; scripts/repro_check.sh
