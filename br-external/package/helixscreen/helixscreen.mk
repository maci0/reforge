################################################################################
#
# helixscreen
#
################################################################################

# ReForge: lab/eval package (default n; enabled only for the lab/helixscreen-eval qemu
# render+RAM eval, NOT the shipped image). HelixScreen is GuppyScreen-class (LVGL/fbdev).
# Pinned to release/1.1 until the v1.1.0 tag exists.
HELIXSCREEN_VERSION = 265d34259685029586cdd33af9cac24d250fc973
HELIXSCREEN_SITE = https://github.com/prestonbrown/helixscreen.git
HELIXSCREEN_SITE_METHOD = git
HELIXSCREEN_GIT_SUBMODULES = yes
HELIXSCREEN_LICENSE = GPL-3.0-or-later
HELIXSCREEN_LICENSE_FILES = LICENSE
HELIXSCREEN_DEPENDENCIES = libevdev openssl tslib

# PLATFORM_TARGET=ad5m-br takes the compiler, sysroot and flags from Buildroot's
# environment, and HelixScreen patches its submodules in Buildroot's extracted
# tree itself, so the package needs no fixups.
HELIXSCREEN_MAKE_OPTS = PLATFORM_TARGET=ad5m-br

# Pass the toolchain flags as ENV (via TARGET_MAKE_ENV), NOT as make command-line
# vars. HelixScreen sets its own CXXFLAGS (-DHELIX_*, -march, -std=c++17) with
# `:=`, and its nested makefiles build include paths with `+=`; a command-line
# CXXFLAGS/CPPFLAGS would override both. Env lets HelixScreen's own flags win.
define HELIXSCREEN_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) $(MAKE) $(HELIXSCREEN_MAKE_OPTS) -C $(@D) build/ad5m-br/bin/helix-screen
endef

define HELIXSCREEN_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/opt/helixscreen/bin
	cp -a $(@D)/build/ad5m-br/bin/helix-screen $(TARGET_DIR)/opt/helixscreen/bin/
	cp -a $(@D)/ui_xml $(@D)/assets $(TARGET_DIR)/opt/helixscreen/ 2>/dev/null || true
endef

$(eval $(generic-package))
