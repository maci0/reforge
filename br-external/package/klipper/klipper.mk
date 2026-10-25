################################################################################
#
# klipper
#
################################################################################

# Pinned to upstream Klipper v0.11.0 (release tag, 2022-11-29) — recorded in pins.lock.
#
# Why v0.11.0: the AD5M / AD5M Pro stock MCU firmware was built from Klipper v0.11
# (build string `?-20230317_182329-…` matches the v0.11 era), and the canonical
# printer.cfg in reference/ad5m-factory-config/ (extracted verbatim from the 3.1.3
# factory image) was authored against the v0.11 host. Running a newer host against
# the v11 MCU risks protocol skew on the more dynamic commands (input shaper, ADXL).
#
# Why upstream Klipper3d/klipper rather than the FlashForge fork:
#   github.com/FlashForge/AD5M_Series_Klipper is byte-identical to upstream v0.11.0
#   except for 6 trivial files — see docs/research/2026-06-04-klipper-v0.11-fork-deltas.md
#   for the full deltas. We use upstream for cleaner provenance.
#
# Patches carried on top of v0.11.0:
#   0001-chelper-disable-runtime-build-check.patch — chelper.so is pre-compiled
#     by the cross toolchain at Buildroot time; matches the FF fork's only
#     meaningful change; defensive guard against future flows that re-touch
#     chelper sources after install.
#   0002-py3-configfile-read_file.patch — Python 3.12 removed configparser's
#     readfp() method; klippy/configfile.py calls it unconditionally and so
#     aborts at first config load on our Python 3.14. Backport of upstream
#     Klipper PR #6388 (which landed on master at klippy/configfile.py:165-169).
#   0003-py3-gcode-regex-raw-string.patch — klippy/gcode.py:396 uses a non-raw
#     string for the m112 regex (`'^...\s...'`); Python 3.14 promoted the
#     unknown-escape from SyntaxWarning to SyntaxError, so the module fails
#     to import. Matches master's gcode.py:432 (raw-string prefix).
#   0004-toolhead-backport-lookahead-flush-time.patch — backport of upstream
#     commit 16fc46fe5 by Kevin O'Connor (2025-09-30): LOOKAHEAD_FLUSH_TIME
#     0.250 → 0.150. Reduces "print stall" corner cases (which is what
#     forge-x's `fix_enable_e17` workaround addresses on this exact hardware).
#     Upstream took this change for general responsiveness; forge-x users have
#     been running the same value for months. Low-risk one-line change.
#   0005-relax-TRSYNC_TIMEOUT-ffad5m.patch — doubles MCU sync ack window
#     from 25 ms (TRSYNC_TIMEOUT = 0.025) to 50 ms. Preemptive default to
#     stop sporadic E0011 communication-timeout shutdowns observed across
#     the AD5M user base on forge-x. Same value forge-x ships as
#     fix_enable_e11. No upstream support.
#   0006-stepcompress-bump-queue-start-size.patch — matches the FlashForge
#     fork: QUEUE_START_SIZE 1024 -> 2048 in stepcompress.c. Saves one
#     realloc-and-memcpy per stepper queue at the cost of allocating twice
#     as many initial slots upfront (~5-10 KB across the AD5M's 5 steppers,
#     trivial). No upstream support.
#   0007-defer-multiprocessing-imports.patch — load process helpers only
#     when calibration or accelerometer sample export needs them.
KLIPPER_VERSION = e02b725602067a2cd098a62be9a4bb10fc74a9bd
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
# chelper source files — match SOURCE_FILES in klippy/chelper/__init__.py at
# the pinned v0.11.0 commit (not master). v0.11.0 does NOT have steppersync.c,
# kin_idex.c, or kin_generic.c — those were added in v0.12+. If the pin moves
# forward this list must be re-synced.
# ---------------------------------------------------------------------------
KLIPPER_CHELPER_SRCS = \
	pyhelper.c \
	serialqueue.c \
	stepcompress.c \
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
	kin_shaper.c

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
