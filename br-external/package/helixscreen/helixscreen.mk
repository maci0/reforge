################################################################################
#
# helixscreen
#
################################################################################

# ReForge: lab/eval package (default n; enabled only for the lab/helixscreen-eval qemu
# render+RAM eval, NOT the shipped image). HelixScreen is GuppyScreen-class (LVGL/fbdev).
# Pinned to the commit behind upstream release v1.0.11.
HELIXSCREEN_VERSION = 9e251a7bad126bfbe4f7e1e03294b8d91b67e471
HELIXSCREEN_SITE = https://github.com/prestonbrown/helixscreen.git
HELIXSCREEN_SITE_METHOD = git
HELIXSCREEN_GIT_SUBMODULES = yes
HELIXSCREEN_LICENSE = GPL-3.0-or-later
HELIXSCREEN_LICENSE_FILES = LICENSE
HELIXSCREEN_DEPENDENCIES = libevdev libnl openssl tslib

# HelixScreen applies ~40 LVGL + 3 libhv patches via its own `apply-patches`
# target, which uses `git apply`/`git checkout` against the submodule worktrees.
# Buildroot extracts submodules as plain files (no .git), so make them throwaway
# git repos so HelixScreen's patching works. Strip hardcoded host paths and give
# the wpa client its source includes and Buildroot's libnl headers.
define HELIXSCREEN_FIXUP_FOR_BUILDROOT
	for sub in lib/lvgl lib/libhv; do \
		rm -f $(@D)/$$sub/.git; \
		( cd $(@D)/$$sub && git init -q && git add -A && \
		  git -c user.email=b@b -c user.name=b commit -qm init ); \
	done
	$(SED) 's#CXXFLAGS += -isystem /usr/include/libusb-1.0 -DHELIX_HAS_LIBUSB=1#\# ReForge: libusb disabled for ad5m (host path is cross-unsafe)#' $(@D)/Makefile
	$(SED) 's#-L/usr/lib/$$(TARGET_TRIPLE) ##' $(@D)/Makefile
	$(SED) 's#EXTRA_CFLAGS="$$(WPA_CFLAGS) $$(LIBNL_INC)"#EXTRA_CFLAGS="$$(WPA_CFLAGS) $$(LIBNL_INC) -I$$(abspath $$(WPA_DIR)/src) -I$$(abspath $$(WPA_DIR)/src/utils)"#' $(@D)/mk/deps.mk
	$(SED) 's#^$$(WPA_CLIENT_LIB): | $$(BUILD_DIR)/lib libnl-build$$#$$(WPA_CLIENT_LIB): | $$(BUILD_DIR)/lib#' $(@D)/mk/deps.mk
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
# HelixScreen selects the embedded linker rules only when CROSS_COMPILE is set.
# Reuse Buildroot's libnl, which the default image already ships for wpa_supplicant.
HELIXSCREEN_MAKE_OPTS = PLATFORM_TARGET=ad5m-br CROSS_COMPILE="$(TARGET_CROSS)" \
	LIBNL_LIBS="-lnl-genl-3 -lnl-3" LIBNL_INC="-I$(STAGING_DIR)/usr/include/libnl3" \
	LIBNL_LIB= SPDLOG_SYSTEM_HEADER=

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
