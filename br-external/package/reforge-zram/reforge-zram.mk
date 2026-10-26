################################################################################
#
# reforge-zram — source-built zram modules for the stock 5.4.61 kernel
#
# A private BSP copy preserves the stock ABI without changing the Linux
# package's configuration (which can also select the QEMU kernel profile).
#
################################################################################

REFORGE_ZRAM_VERSION = 5.4.61
REFORGE_ZRAM_SITE = $(BR2_EXTERNAL_REFORGE_PATH)/../vendor/kernels/tina-bsp-kernel
REFORGE_ZRAM_SITE_METHOD = local
REFORGE_ZRAM_LICENSE = GPL-2.0+
REFORGE_ZRAM_LICENSE_FILES = COPYING
REFORGE_ZRAM_DEPENDENCIES = linux

define REFORGE_ZRAM_CONFIGURE_CMDS
	cp $(BR2_EXTERNAL_REFORGE_PATH)/board/reforge/linux.config $(@D)/.config
	$(@D)/scripts/config --file $(@D)/.config --module ZSMALLOC --module ZRAM
	touch $(@D)/.scmversion
	$(LINUX_MAKE_ENV) $(BR2_MAKE) $(LINUX_MAKE_FLAGS) -C $(@D) olddefconfig
	$(LINUX_MAKE_ENV) $(BR2_MAKE) $(LINUX_MAKE_FLAGS) -C $(@D) modules_prepare
	cp $(LINUX_DIR)/Module.symvers $(@D)/Module.symvers
endef

define REFORGE_ZRAM_BUILD_CMDS
	$(LINUX_MAKE_ENV) $(BR2_MAKE) $(LINUX_MAKE_FLAGS) -C $(@D) \
		mm/zsmalloc.ko drivers/block/zram/zram.ko
	set -e; for module in $(@D)/mm/zsmalloc.ko $(@D)/drivers/block/zram/zram.ko; do \
		$(TARGET_CROSS)strings $$module | \
			grep -Fxq 'vermagic=5.4.61 SMP preempt mod_unload ARMv7 p2v8 '; \
	done
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -static \
		$(BR2_EXTERNAL_REFORGE_PATH)/../modules/zram-bsp/swapon_prio.c \
		-o $(@D)/swapon_prio
endef

define REFORGE_ZRAM_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/opt/reforge/zram
	$(INSTALL) -D -m 0644 $(@D)/mm/zsmalloc.ko \
		$(TARGET_DIR)/opt/reforge/zram/zsmalloc.ko
	$(INSTALL) -D -m 0644 $(@D)/drivers/block/zram/zram.ko \
		$(TARGET_DIR)/opt/reforge/zram/zram.ko
	$(INSTALL) -D -m 0755 $(@D)/swapon_prio \
		$(TARGET_DIR)/opt/reforge/zram/swapon_prio
endef

$(eval $(generic-package))
