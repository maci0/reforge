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

# HelixScreen applies ~40 LVGL + 3 libhv patches via its own `apply-patches`
# target, which uses `git apply`/`git checkout` against the submodule worktrees.
# Buildroot extracts submodules as plain files (no .git), so make them throwaway
# git repos so HelixScreen's patching works. Also neutralise two host-contaminating
# bits its Makefile hardcodes (the cross-unsafe host /usr/include/libusb path —
# ad5m has no libusb, backlight is /dev/disp) and add the missing wpa src include.
define HELIXSCREEN_FIXUP_FOR_BUILDROOT
	for sub in lib/lvgl lib/libhv; do \
		rm -f $(@D)/$$sub/.git; \
		( cd $(@D)/$$sub && git init -q && git add -A && \
		  git -c user.email=b@b -c user.name=b commit -qm init ); \
	done
	$(SED) 's#CXXFLAGS += -isystem /usr/include/libusb-1.0 -DHELIX_HAS_LIBUSB=1#\# ReForge: libusb disabled for ad5m (host path is cross-unsafe)#' $(@D)/Makefile
	$(SED) 's#EXTRA_CFLAGS="$$(WPA_CFLAGS) $$(LIBNL_INC)"#EXTRA_CFLAGS="$$(WPA_CFLAGS) $$(LIBNL_INC) -I$$(abspath $$(WPA_DIR)/src) -I$$(abspath $$(WPA_DIR)/src/utils)"#' $(@D)/mk/deps.mk
	# libhv defaults to building BOTH shared+static; the shared (.so) link pulls in
	# the app LDFLAGS (libhv.a, -lusb) and fails. HelixScreen only links libhv.a —
	# force libhv static-only so the leaking .so is never built.
	$(SED) 's/^LIBHV_TARGET_TYPE ?= SHARED|STATIC/LIBHV_TARGET_TYPE ?= STATIC/' $(@D)/lib/libhv/Makefile
endef
HELIXSCREEN_POST_PATCH_HOOKS += HELIXSCREEN_FIXUP_FOR_BUILDROOT

# SPDLOG_SYSTEM_HEADER= forces the bundled lib/spdlog: HelixScreen probes the
# BUILD HOST's /usr/include for a system spdlog and, if found, empties SPDLOG_INC
# assuming the *target* has it too — which breaks the cross build on any dev box
# with system spdlog installed (the PR's clean CI host never hits this).
HELIXSCREEN_MAKE_OPTS = PLATFORM_TARGET=ad5m-br SPDLOG_SYSTEM_HEADER=

# Pass the toolchain flags as ENV (via TARGET_MAKE_ENV), NOT as make command-line
# vars. HelixScreen sets its own CXXFLAGS (-DHELIX_*, -march, -std=c++17) with
# `:=`, and its nested makefiles build include paths with `+=`; a command-line
# CXXFLAGS/CPPFLAGS would override both (passing buildroot's clobbers HelixScreen's
# -DHELIX_*; emptying them loses everything). Env lets HelixScreen's own flags win.
# The one env hazard — the app LDFLAGS leaking into libhv's shared-lib link — is
# avoided by forcing libhv static-only in the POST_PATCH above (no .so is built).
# Build only the main binary; the splash/watchdog helpers have a separate link
# issue and aren't needed for the on-screen UI.
define HELIXSCREEN_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) $(MAKE) $(HELIXSCREEN_MAKE_OPTS) -C $(@D) build/ad5m-br/bin/helix-screen
endef

define HELIXSCREEN_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/opt/helixscreen/bin
	cp -a $(@D)/build/ad5m-br/bin/helix-screen $(TARGET_DIR)/opt/helixscreen/bin/
	cp -a $(@D)/ui_xml $(@D)/assets $(TARGET_DIR)/opt/helixscreen/ 2>/dev/null || true
endef

$(eval $(generic-package))
