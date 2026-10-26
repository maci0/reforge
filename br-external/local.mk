# Kernel-variant selector. REFORGE_KERNEL picks which Linux .config the Buildroot
# `linux` package uses (both build the SAME vendor Tina source via OVERRIDE_SRCDIR):
#   device (default) — the captured stock config (board/reforge/linux.config),
#                      the real AD5M/Pro kernel.
#   virt             — the qemu `-M virt` test config (board/reforge/linux-virt.config:
#                      multi_v7 + virtio/drm/fb, ARCH_SUNXI off), for boot testing.
# Override on the command line, e.g.  make -C buildroot ... REFORGE_KERNEL=virt linux
# (the `make kernel` / `make kernel-virt` targets do this). These selectors must
# be defined here before linux/linux.mk validates the custom DTS setting.
REFORGE_KERNEL ?= device
ifeq ($(REFORGE_KERNEL),virt)
REFORGE_LINUX_CONFIG = linux-virt.config
REFORGE_LINUX_DTS = virt/board.dts
else
REFORGE_LINUX_CONFIG = linux.config
REFORGE_LINUX_DTS = board.dts
endif

# ReForge Buildroot package-override file (selected via BR2_PACKAGE_OVERRIDE_FILE
# in reforge_defconfig). Buildroot rsyncs an OVERRIDE_SRCDIR into its build tree
# instead of downloading + extracting that package.
#
# Build the Linux kernel from our in-tree Tina BSP source (vendor/kernels/
# tina-bsp-kernel, 5.4.61) rather than fetching linux-5.4.61.tar.xz from kernel.org
# — the BSP carries Allwinner sun8iw20 (T113-S3) drivers that mainline lacks.
# Buildroot still builds it with its NATIVE toolchain (gcc 15.x); the standalone
# tools/build/build-bsp-kernel*.sh scripts remain the device-faithful references.
#
# BR2_EXTERNAL_REFORGE_PATH is <repo>/br-external, so the kernel tree is one level
# up under vendor/.
LINUX_OVERRIDE_SRCDIR = $(BR2_EXTERNAL_REFORGE_PATH)/../vendor/kernels/tina-bsp-kernel

# Modern-toolchain fixups, applied to Buildroot's RSYNCED COPY only (post-rsync),
# so the shared vendor/ source stays pristine and the standalone byte-identical /
# gcc-9.5 kernel scripts (which use binutils 2.25 / 2.39 that accept the old
# syntax) are unaffected.
#
# binutils 2.44 (the Buildroot toolchain) removed the legacy ARM section-flag
# syntax `.section name, #alloc[, #execinstr]` — it now wants ELF flag strings
# ("a"/"ax"/"x"). Rewrite it across arch/arm/*.S in the build copy.
define REFORGE_LINUX_TOOLCHAIN_FIXUPS
	find $(LINUX_DIR)/arch/arm -name '*.S' -print0 | xargs -0 -r sed -i \
		-e 's/,[[:space:]]*#alloc[[:space:]]*,[[:space:]]*#execinstr/, "ax"/g' \
		-e 's/,[[:space:]]*#execinstr[[:space:]]*,[[:space:]]*#alloc/, "ax"/g' \
		-e 's/,[[:space:]]*#alloc/, "a"/g' \
		-e 's/,[[:space:]]*#execinstr/, "x"/g'
	# Build board.dtb (fed via BR2_LINUX_KERNEL_CUSTOM_DTS_PATH)
	# unconditionally. The device config gets it from `dtb-$(CONFIG_ARCH_SUN8IW20)`,
	# but the virt config (ARCH_SUNXI off) wouldn't — yet DTS_SUPPORT still expects
	# a board.dtb to install. Appending an unconditional dtb-y satisfies both
	# (make de-dups the target, so the device build is unaffected).
	grep -q '^dtb-y += board.dtb' $(LINUX_DIR)/arch/arm/boot/dts/Makefile \
		|| printf '\ndtb-y += board.dtb\n' >> $(LINUX_DIR)/arch/arm/boot/dts/Makefile
endef
LINUX_POST_RSYNC_HOOKS += REFORGE_LINUX_TOOLCHAIN_FIXUPS
