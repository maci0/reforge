################################################################################
#
# klipper13
#
################################################################################

# AD5M board-support fork: host and both MCUs use this exact source pin.
KLIPPER13_VERSION = fc2aaae692b5f703420915390a3dcb8cd514c384
KLIPPER13_SITE = https://github.com/xblax/klipper.git
KLIPPER13_SITE_METHOD = git
KLIPPER13_BUILD_VERSION = v0.13.0-285-gfc2aaae69-ffadm5-reforge
KLIPPER13_INSTALL_IMAGES = YES
KLIPPER13_LICENSE = GPL-3.0
KLIPPER13_LICENSE_FILES = COPYING
KLIPPER13_DEPENDENCIES = python3 python-cffi python-serial python-greenlet \
	python-numpy python-jinja2 python-markupsafe newlib-bare-metal host-python3

# SOURCE_FILES from the pinned fork's klippy/chelper/__init__.py.
KLIPPER13_CHELPER_SRCS = pyhelper.c serialqueue.c stepcompress.c steppersync.c itersolve.c \
	trapq.c pollreactor.c msgblock.c trdispatch.c kin_cartesian.c kin_corexy.c \
	kin_corexz.c kin_delta.c kin_deltesian.c kin_polar.c kin_rotary_delta.c \
	kin_winch.c kin_extruder.c kin_shaper.c kin_idex.c kin_generic.c

ifeq ($(BR2_PACKAGE_KLIPPER13),y)
ifneq ($(call qstrip,$(BR2_TOOLCHAIN_BARE_METAL_BUILDROOT_ARCH)),arm-none-eabi)
$(error klipper13 requires the arm-none-eabi bare metal architecture tuple)
endif
ifeq ($(BR2_TOOLCHAIN_BARE_METAL_BUILDROOT_MULTILIB),y)
$(error klipper13 requires bare metal multilib disabled for its Cortex-M4 libraries)
endif
# Both N32G455 boards require Thumb-only M-profile runtime libraries.
HOST_GCC_BARE_METAL_CONF_OPTS += --with-cpu=cortex-m4 --with-mode=thumb --with-float=soft
# Debug paths in linked libc must be normalized when libc itself is compiled.
NEWLIB_BARE_METAL_CONF_OPTS += \
	CFLAGS_FOR_TARGET='-g -O2 -ffile-prefix-map=$(BASE_DIR)=/reforge/build -ffile-prefix-map=$(HOST_DIR)=/reforge/host'
NEWLIB_BARE_METAL_MAKE_OPTS += \
	AR_FOR_TARGET='$(HOST_DIR)/bin/arm-none-eabi-ar -D' \
	RANLIB_FOR_TARGET='$(HOST_DIR)/bin/arm-none-eabi-ranlib -D'
endif

define KLIPPER13_BUILD_CMDS
	$(RM) -f $(@D)/klippy/chelper/c_helper.so
	cd $(@D)/klippy/chelper && \
	$(TARGET_CC) $(TARGET_CFLAGS) \
		-O2 -mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard \
		-Wall -shared -fPIC -flto -fwhole-program -fno-use-linker-plugin \
		-o c_helper.so $(KLIPPER13_CHELPER_SRCS) $(TARGET_LDFLAGS)
	printf '%s\n' "$(KLIPPER13_BUILD_VERSION)" > $(@D)/klippy/.version
	mkdir -p $(@D)/firmware
	set -e; for board in mainboard eboard; do \
		rm -rf $(@D)/out; \
		cp $(KLIPPER13_PKGDIR)/mcu-configs/$$board $(@D)/.config; \
		$(HOST_MAKE_ENV) $(MAKE) -C $(@D) \
			CROSS_PREFIX=$(HOST_DIR)/bin/arm-none-eabi- PYTHON=$(HOST_DIR)/bin/python3 olddefconfig && \
		$(HOST_MAKE_ENV) $(MAKE) -C $(@D) \
			CROSS_PREFIX=$(HOST_DIR)/bin/arm-none-eabi- PYTHON=$(HOST_DIR)/bin/python3 \
			EXTRA_CFLAGS='-ffile-prefix-map=$(@D)=. -ffile-prefix-map=$(HOST_DIR)=/reforge/host' && \
		$(HOST_DIR)/bin/python3 $(KLIPPER13_PKGDIR)/check-mcu.py \
			$(@D)/out $(@D)/.config $$board "$(KLIPPER13_BUILD_VERSION)" || exit 1; \
		for ext in bin hex elf dict; do \
			cp $(@D)/out/klipper.$$ext $(@D)/firmware/$$board.$$ext || exit 1; \
		done; \
		cp $(@D)/.config $(@D)/firmware/$$board.config || exit 1; \
	done
	printf '%s\n%s\n' "$(KLIPPER13_BUILD_VERSION)" "$(KLIPPER13_VERSION)" > $(@D)/firmware/SOURCE
	cd $(@D)/firmware && sha256sum SOURCE mainboard.* eboard.* > SHA256SUMS
endef

define KLIPPER13_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/opt/klipper/klippy
	mkdir -p $(TARGET_DIR)/opt/klipper
	cp -r $(@D)/klippy $(TARGET_DIR)/opt/klipper/klippy
	$(INSTALL) -m 0755 $(@D)/klippy/chelper/c_helper.so \
		$(TARGET_DIR)/opt/klipper/klippy/chelper/c_helper.so
	printf '%s\n' "$(KLIPPER13_BUILD_VERSION)" \
		> $(TARGET_DIR)/opt/klipper/klippy/.version
	$(INSTALL) -m 0644 $(BR2_EXTERNAL_REFORGE_PATH)/package/klipper/extensions/*.py \
		$(TARGET_DIR)/opt/klipper/klippy/extras/
	mkdir -p $(TARGET_DIR)/opt/klipper/firmware
	cp $(@D)/firmware/* $(TARGET_DIR)/opt/klipper/firmware/
endef

define KLIPPER13_INSTALL_IMAGES_CMDS
	mkdir -p $(BINARIES_DIR)/klipper13
	cp $(@D)/firmware/* $(BINARIES_DIR)/klipper13/
endef

$(eval $(generic-package))
