################################################################################
#
# klipper
#
################################################################################

# Pinned to Klipper master SHA — recorded in pins.lock.
# Python 3.12+ / numpy 2.x compatible (verified against master 2025-12-xx).
KLIPPER_VERSION = b7c0329f1dcc159bb20148afa65b113a34c51efa
KLIPPER_SITE = https://github.com/Klipper3d/klipper.git
KLIPPER_SITE_METHOD = git

KLIPPER_LICENSE = GPL-3.0
KLIPPER_LICENSE_FILES = COPYING

KLIPPER_DEPENDENCIES = \
	python3 \
	python-cffi \
	python-serial \
	python-greenlet \
	python-numpy \
	python-jinja2 \
	python-markupsafe

# ---------------------------------------------------------------------------
# chelper source files — match exactly what klippy/chelper/__init__.py lists
# in SOURCE_FILES at this pinned commit (see klippy/chelper/__init__.py).
# ---------------------------------------------------------------------------
KLIPPER_CHELPER_SRCS = \
	pyhelper.c \
	serialqueue.c \
	stepcompress.c \
	steppersync.c \
	itersolve.c \
	trapq.c \
	pollreactor.c \
	msgblock.c \
	trdispatch.c \
	kin_cartesian.c \
	kin_corexy.c \
	kin_corexz.c \
	kin_delta.c \
	kin_deltesian.c \
	kin_polar.c \
	kin_rotary_delta.c \
	kin_winch.c \
	kin_extruder.c \
	kin_shaper.c \
	kin_idex.c \
	kin_generic.c

# ---------------------------------------------------------------------------
# Build chelper with cross compiler + Cortex-A7 NEON flags at BUILD time so
# the .so ships pre-compiled and tuned (no GCC needed on target).
# We match Klipper's own COMPILE_ARGS but swap GCC_CMD for cross compiler and
# add ARM-specific flags.  See klippy/chelper/__init__.py for the original cmd.
# ---------------------------------------------------------------------------
define KLIPPER_BUILD_CMDS
	$(RM) -f $(@D)/klippy/chelper/c_helper.so
	cd $(@D)/klippy/chelper && \
	$(TARGET_CC) $(TARGET_CFLAGS) \
		-O2 -mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard \
		-Wall -shared -fPIC \
		-flto -fwhole-program -fno-use-linker-plugin \
		-o c_helper.so \
		$(KLIPPER_CHELPER_SRCS) \
		$(TARGET_LDFLAGS)
endef

define KLIPPER_INSTALL_TARGET_CMDS
	# Install the klippy tree (rm first so cp -r does not nest on reinstall)
	rm -rf $(TARGET_DIR)/opt/klipper/klippy
	mkdir -p $(TARGET_DIR)/opt/klipper
	cp -r $(@D)/klippy $(TARGET_DIR)/opt/klipper/klippy

	# Install c_helper.so built above (overwrite if cp -r already copied it)
	$(INSTALL) -m 0755 $(@D)/klippy/chelper/c_helper.so \
		$(TARGET_DIR)/opt/klipper/klippy/chelper/c_helper.so

	# Write the pinned SHA as .version so klippy/util.py get_version_from_file()
	# returns something meaningful instead of "?" when git is unavailable.
	printf '%s\n' "$(KLIPPER_VERSION)" \
		> $(TARGET_DIR)/opt/klipper/klippy/.version

	# Install AD5M-specific klippy extension plugins into extras/
	$(INSTALL) -d $(TARGET_DIR)/opt/klipper/klippy/extras
	$(INSTALL) -m 0644 $(KLIPPER_PKGDIR)/extensions/*.py \
		$(TARGET_DIR)/opt/klipper/klippy/extras/
endef

$(eval $(generic-package))
