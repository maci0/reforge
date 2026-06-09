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
	$(SED) 's#EXTRA_CFLAGS="$$(WPA_CFLAGS) $$(LIBNL_INC)"#&#' $(@D)/mk/deps.mk
	# libhv defaults to building BOTH shared+static; the shared (.so) link pulls in
	# the app LDFLAGS (libhv.a, -lusb) and fails. HelixScreen only links libhv.a —
	# force libhv static-only so the leaking .so is never built.
	$(SED) 's/^LIBHV_TARGET_TYPE ?= SHARED|STATIC/LIBHV_TARGET_TYPE ?= STATIC/' $(@D)/lib/libhv/Makefile
endef
HELIXSCREEN_POST_PATCH_HOOKS += HELIXSCREEN_FIXUP_FOR_BUILDROOT

# Pass the cross toolchain flags as ENVIRONMENT, not make command-line overrides.
# HelixScreen's nested makefiles (libhv, the bundled wpa_supplicant, the watchdog
# helper) build up their own include paths with `CPPFLAGS/CFLAGS += -I...`. A
# make command-line `CPPFLAGS=...` (what `$(MAKE) $(TARGET_CONFIGURE_OPTS)` does)
# OVERRIDES those `+=`, so the components lose their -I and fail (hexport.h,
# common/ieee802_11_defs.h, spdlog/spdlog.h "No such file"). As env vars the
# package's `+=` appends correctly.
# SPDLOG_SYSTEM_HEADER= : HelixScreen probes the BUILD HOST's /usr/include for a
# system spdlog ($(wildcard /usr/include/spdlog/spdlog.h ...)) and, if found,
# empties SPDLOG_INC assuming the *target* has it too — which breaks the cross
# build on any dev box that has system spdlog installed (the PR's clean CI host
# doesn't, so it never hits this). Force it empty so the bundled lib/spdlog is used.
# CPPFLAGS= : build like upstream/the PR (flags as make command-line vars) but
# override CPPFLAGS to EMPTY so it does not clobber each component's
# `CPPFLAGS += -I` (libhv/wpa). We must NOT pass flags as env instead: that leaks
# the app LDFLAGS (build/ad5m-br/lib/libhv.a, -lusb-1.0) into libhv's own .so
# link, which then fails. Build only the main binary; the splash/watchdog helpers
# have a separate link issue and aren't needed for the on-screen UI.
HELIXSCREEN_MAKE_OPTS = PLATFORM_TARGET=ad5m-br SPDLOG_SYSTEM_HEADER=

# Pass the toolchain flags as ENV (not make command-line): HelixScreen sets its
# own CXXFLAGS (-DHELIX_*, -march, -std=c++17) with `:=`, which a command-line
# CXXFLAGS would override (emptying it loses everything; passing buildroot's
# clobbers HelixScreen's). Env lets HelixScreen's `:=`/`+=` win. The one hazard
# of env — the app LDFLAGS (libhv.a, -lusb) leaking into libhv's own .so link —
# is closed by the POST_PATCH `LDFLAGS=` added to libhv's sub-make above.
define HELIXSCREEN_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) $(MAKE) $(HELIXSCREEN_MAKE_OPTS) -C $(@D) build/ad5m-br/bin/helix-screen
endef

define HELIXSCREEN_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/opt/helixscreen/bin
	cp -a $(@D)/build/ad5m-br/bin/helix-screen $(TARGET_DIR)/opt/helixscreen/bin/
	cp -a $(@D)/ui_xml $(@D)/assets $(TARGET_DIR)/opt/helixscreen/ 2>/dev/null || true
endef

$(eval $(generic-package))
