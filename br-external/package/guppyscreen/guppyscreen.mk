################################################################################
#
# guppyscreen — native LVGL touch UI for Klipper/Moonraker
# Targets FlashForge AD5M Pro (Allwinner T113-S3, Cortex-A7)
#
################################################################################

# Pinned to consp/guppyscreen flashforge_ad5m branch HEAD (2025-07 snapshot).
# Using the consp fork rather than upstream ballaswag because this branch
# already carries the FF5M-specific lv_drivers and screen-size defines that
# the three patches below depend on.
GUPPYSCREEN_VERSION = fdca5728001f7a6f6ce774dcfa3998f8b96e6878
GUPPYSCREEN_SITE = https://github.com/consp/guppyscreen.git
GUPPYSCREEN_SITE_METHOD = git
GUPPYSCREEN_GIT_SUBMODULES = YES
GUPPYSCREEN_LICENSE = GPL-3.0+
GUPPYSCREEN_LICENSE_FILES = COPYING

GUPPYSCREEN_DEPENDENCIES = libevdev wpa_supplicant

# Cortex-A7 / NEON flags injected at build time so they propagate into
# the guppyscreen Makefile's override CFLAGS += path.
GUPPYSCREEN_CFLAGS_EXTRA = -mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard

define GUPPYSCREEN_BUILD_CMDS
	# Apply in-tree source patches (stored in guppyscreen/patches/ directory):
	# 0001 adds fbdev_blank/unblank/brightness ioctls for the AD5M display.
	# 0002 fixes a spdlog fmt initializer_list issue.
	# --forward/-N means "ignore if already applied" (idempotent).
	patch --forward -N -d $(@D)/lv_drivers -p1 < \
		$(@D)/patches/0001-lv_driver_fb_ioctls_flashforge_ad5m.patch || true
	patch --forward -N -d $(@D)/spdlog -p1 < \
		$(@D)/patches/0002-spdlog_fmt_initializer_list.patch || true
	GUPPY_FF5M_SCREEN=1 $(MAKE) $(TARGET_CONFIGURE_OPTS) \
		CFLAGS="$(TARGET_CFLAGS) $(GUPPYSCREEN_CFLAGS_EXTRA)" \
		CXXFLAGS="$(TARGET_CXXFLAGS) $(GUPPYSCREEN_CFLAGS_EXTRA)" \
		-C $(@D) libhv.a
	GUPPY_FF5M_SCREEN=1 $(MAKE) $(TARGET_CONFIGURE_OPTS) \
		CFLAGS="$(TARGET_CFLAGS) $(GUPPYSCREEN_CFLAGS_EXTRA)" \
		CXXFLAGS="$(TARGET_CXXFLAGS) $(GUPPYSCREEN_CFLAGS_EXTRA)" \
		-C $(@D) libspdlog.a
	GUPPY_FF5M_SCREEN=1 $(MAKE) $(TARGET_CONFIGURE_OPTS) \
		CFLAGS="$(TARGET_CFLAGS) $(GUPPYSCREEN_CFLAGS_EXTRA)" \
		CXXFLAGS="$(TARGET_CXXFLAGS) $(GUPPYSCREEN_CFLAGS_EXTRA)" \
		-C $(@D) wpaclient
	GUPPY_FF5M_SCREEN=1 $(MAKE) $(TARGET_CONFIGURE_OPTS) \
		CFLAGS="$(TARGET_CFLAGS) $(GUPPYSCREEN_CFLAGS_EXTRA)" \
		CXXFLAGS="$(TARGET_CXXFLAGS) $(GUPPYSCREEN_CFLAGS_EXTRA)" \
		-C $(@D)
endef

define GUPPYSCREEN_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/build/bin/guppyscreen \
		$(TARGET_DIR)/opt/guppyscreen/guppyscreen
	# Install assets/themes directory if present
	if [ -d "$(@D)/assets" ]; then \
		cp -a $(@D)/assets $(TARGET_DIR)/opt/guppyscreen/; \
	fi
	if [ -d "$(@D)/themes" ]; then \
		cp -a $(@D)/themes $(TARGET_DIR)/opt/guppyscreen/; \
	fi
endef

$(eval $(generic-package))
