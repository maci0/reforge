include $(sort $(wildcard $(BR2_EXTERNAL_REFORGE_PATH)/package/*/*.mk))

# Kernel-variant selector. REFORGE_KERNEL picks which Linux .config the Buildroot
# `linux` package uses (both build the SAME vendor Tina source via OVERRIDE_SRCDIR):
#   device (default) — the captured stock config (board/reforge/linux.config),
#                      the real AD5M/Pro kernel.
#   virt             — the qemu `-M virt` test config (board/reforge/linux-virt.config:
#                      multi_v7 + virtio/drm/fb, ARCH_SUNXI off), for boot testing.
# Override on the command line, e.g.  make -C buildroot ... REFORGE_KERNEL=virt linux
# (the `make kernel` / `make kernel-virt` targets do this). REFORGE_LINUX_CONFIG is
# consumed by BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE in reforge_defconfig.
REFORGE_KERNEL ?= device
ifeq ($(REFORGE_KERNEL),virt)
REFORGE_LINUX_CONFIG = linux-virt.config
else
REFORGE_LINUX_CONFIG = linux.config
endif
