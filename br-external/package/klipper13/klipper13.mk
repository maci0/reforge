################################################################################
#
# klipper13
#
################################################################################

# v0.13.0 release; opt-in alternative to stock-MCU-compatible klipper v0.11.0.
KLIPPER13_VERSION = 61c0c8d2ef40340781835dd53fb04cc7a454e37a
KLIPPER13_SITE = https://github.com/Klipper3d/klipper.git
KLIPPER13_SITE_METHOD = git
KLIPPER13_LICENSE = GPL-3.0
KLIPPER13_LICENSE_FILES = COPYING
KLIPPER13_DEPENDENCIES = python3 python-cffi python-serial python-greenlet \
	python-numpy python-jinja2 python-markupsafe

# SOURCE_FILES from v0.13.0 klippy/chelper/__init__.py (includes kin_idex.c).
KLIPPER13_CHELPER_SRCS = pyhelper.c serialqueue.c stepcompress.c itersolve.c \
	trapq.c pollreactor.c msgblock.c trdispatch.c kin_cartesian.c kin_corexy.c \
	kin_corexz.c kin_delta.c kin_deltesian.c kin_polar.c kin_rotary_delta.c \
	kin_winch.c kin_extruder.c kin_shaper.c kin_idex.c

define KLIPPER13_BUILD_CMDS
	$(RM) -f $(@D)/klippy/chelper/c_helper.so
	cd $(@D)/klippy/chelper && \
	$(TARGET_CC) $(TARGET_CFLAGS) \
		-O2 -mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard \
		-Wall -shared -fPIC -flto -fwhole-program -fno-use-linker-plugin \
		-o c_helper.so $(KLIPPER13_CHELPER_SRCS) $(TARGET_LDFLAGS)
endef

define KLIPPER13_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/opt/klipper/klippy
	mkdir -p $(TARGET_DIR)/opt/klipper
	cp -r $(@D)/klippy $(TARGET_DIR)/opt/klipper/klippy
	$(INSTALL) -m 0755 $(@D)/klippy/chelper/c_helper.so \
		$(TARGET_DIR)/opt/klipper/klippy/chelper/c_helper.so
	printf '%s\n' "$(KLIPPER13_VERSION)" \
		> $(TARGET_DIR)/opt/klipper/klippy/.version
	$(INSTALL) -m 0644 $(BR2_EXTERNAL_REFORGE_PATH)/package/klipper/extensions/*.py \
		$(TARGET_DIR)/opt/klipper/klippy/extras/
endef

$(eval $(generic-package))
