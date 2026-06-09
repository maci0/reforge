################################################################################
#
# helixscreen
#
################################################################################

# ReForge: lab/eval package (default n; enabled only for the lab/helixscreen-eval qemu
# render+RAM eval, NOT the shipped image). HelixScreen is GuppyScreen-class (LVGL/fbdev).
# Pinned to a commit SHA on prestonbrown/helixscreen main.
# Bump this to a release tag once HelixScreen cuts one.
HELIXSCREEN_VERSION = 846a6e35dd7d0ae53baab6605bd23a77956f17f3
HELIXSCREEN_SITE = https://github.com/prestonbrown/helixscreen.git
HELIXSCREEN_SITE_METHOD = git
HELIXSCREEN_GIT_SUBMODULES = yes
HELIXSCREEN_LICENSE = GPL-3.0-or-later
HELIXSCREEN_LICENSE_FILES = LICENSE
HELIXSCREEN_DEPENDENCIES = libevdev openssl tslib

# Pass the cross toolchain flags as ENVIRONMENT, not make command-line overrides.
# HelixScreen's nested makefiles (libhv, the bundled wpa_supplicant, the watchdog
# helper) build up their own include paths with `CPPFLAGS/CFLAGS += -I...`. A
# make command-line `CPPFLAGS=...` (what `$(MAKE) $(TARGET_CONFIGURE_OPTS)` does)
# OVERRIDES those `+=`, so the components lose their -I and fail (hexport.h,
# common/ieee802_11_defs.h, spdlog/spdlog.h "No such file"). As env vars the
# package's `+=` appends correctly.
define HELIXSCREEN_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) $(MAKE) PLATFORM_TARGET=ad5m-br -C $(@D)
endef

define HELIXSCREEN_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) $(MAKE) PLATFORM_TARGET=ad5m-br \
		install DESTDIR=$(TARGET_DIR) -C $(@D)
endef

$(eval $(generic-package))
