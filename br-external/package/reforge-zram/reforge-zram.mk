################################################################################
#
# reforge-zram — prebuilt zram kernel modules for the stock 5.4.61 kernel
#
# Ships zsmalloc.ko + zram.ko (Allwinner T113 BSP, vermagic 5.4.61 SMP
# preempt mod_unload ARMv7 p2v8) and the static swapon_prio helper binary.
# Targets P1-P3 devices that ride the stock kernel; P4 builds zram in-tree.
#
################################################################################

REFORGE_ZRAM_VERSION = local
# No download — files come from the ReForge tree.  Setting SOURCE to empty
# prevents Buildroot from auto-deriving a tarball name from VERSION and trying
# to fetch it.
REFORGE_ZRAM_SOURCE =
REFORGE_ZRAM_LICENSE = GPL-2.0+

REFORGE_ZRAM_DIST = $(BR2_EXTERNAL_REFORGE_PATH)/../modules/zram-bsp/dist

define REFORGE_ZRAM_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/opt/reforge/zram
	$(INSTALL) -D -m 0644 $(REFORGE_ZRAM_DIST)/zsmalloc.ko \
		$(TARGET_DIR)/opt/reforge/zram/zsmalloc.ko
	$(INSTALL) -D -m 0644 $(REFORGE_ZRAM_DIST)/zram.ko \
		$(TARGET_DIR)/opt/reforge/zram/zram.ko
	$(INSTALL) -D -m 0755 $(REFORGE_ZRAM_DIST)/swapon_prio \
		$(TARGET_DIR)/opt/reforge/zram/swapon_prio
endef

$(eval $(generic-package))
