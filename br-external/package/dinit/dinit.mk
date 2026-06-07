################################################################################
#
# dinit
#
################################################################################

DINIT_VERSION = 0.22.0
DINIT_SOURCE = dinit-$(DINIT_VERSION).tar.xz
DINIT_SITE = https://github.com/davmac314/dinit/releases/download/v$(DINIT_VERSION)
DINIT_LICENSE = Apache-2.0
DINIT_LICENSE_FILES = LICENSE

# dinit ships a hand-written ./configure that emits an mconfig consumed by make
# (no autotools, no meson — Meson support was dropped in 0.20). So this is a
# GENERIC_PACKAGE with explicit configure/build/install steps.
#
# --sbindir=/sbin       dinit/dinitctl/dinitcheck are system binaries.
# --disable-shutdown    do NOT install dinit's shutdown/poweroff/reboot/halt —
#                       they would collide with the BusyBox applets, and we are
#                       not wiring dinit as init yet (package only, no scripts).
# --disable-strip       dinit's install otherwise runs the host `strip` on the
#                       cross-built ARM binaries ("Unable to recognise the
#                       architecture"). Buildroot strips target binaries itself.
# CXX_FOR_BUILD=HOSTCXX  any build-time helper compiles with the host compiler.
define DINIT_CONFIGURE_CMDS
	cd $(@D) && \
		CXX="$(TARGET_CXX)" \
		CXX_FOR_BUILD="$(HOSTCXX)" \
		CXXFLAGS="$(TARGET_CXXFLAGS)" \
		CPPFLAGS="$(TARGET_CPPFLAGS)" \
		LDFLAGS="$(TARGET_LDFLAGS)" \
		./configure --prefix=/usr --sbindir=/sbin \
			--disable-shutdown --disable-strip
endef

define DINIT_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)
endef

define DINIT_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

$(eval $(generic-package))
