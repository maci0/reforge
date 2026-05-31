################################################################################
#
# moonraker
#
################################################################################
#
# DEPENDENCY CLASSIFICATION (pinned commit: 9008485843740c93e0154ccbdac1fc2b02b03aaa)
# ──────────────────────────────────────────────────────────────────────────────
# Source: scripts/moonraker-requirements.txt
#
# BUCKET A — available in upstream Buildroot (2026.02.2)
#   tornado>=6.2.0     BR2_PACKAGE_PYTHON_TORNADO    (CORE: application.py server)
#   pyserial==3.4      BR2_PACKAGE_PYTHON_SERIAL     (klippy_connection; already in klipper)
#   pillow>=9.5.0      BR2_PACKAGE_PYTHON_PILLOW     (CORE: metadata.py thumbnail extraction)
#   distro==1.9.0      BR2_PACKAGE_PYTHON_DISTRO     (CORE: machine.py OS detection)
#   dbus-fast>=2.21.3  BR2_PACKAGE_PYTHON_DBUS_FAST  (CORE: dbus_manager component)
#   zeroconf>=0.131.0  BR2_PACKAGE_PYTHON_ZEROCONF   (optional: zeroconf mDNS component)
#   paho-mqtt==2.1.0   BR2_PACKAGE_PYTHON_PAHO_MQTT  (optional: mqtt component)
#   jinja2==3.1.6      BR2_PACKAGE_PYTHON_JINJA2     (already in klipper; template.py)
#   python-periphery   BR2_PACKAGE_PYTHON_PERIPHERY  (optional: gpio component)
#   wrapt              BR2_PACKAGE_PYTHON_WRAPT       (transitive: smart-open dep)
#   libsodium          BR2_PACKAGE_LIBSODIUM          (transitive: libnacl ctypes dep)
#
# BUCKET B — packaged in br-external (NOT in upstream Buildroot)
#   inotify-simple==2.0.1       python-inotify-simple
#     → pure Python (ctypes), CORE (file_manager/file_manager.py hard import)
#   libnacl==2.1.0              python-libnacl
#     → pure Python (ctypes/libsodium), CORE (authorization.py hard import)
#   streaming-form-data<=1.19.1 python-streaming-form-data
#     → C extension (Cython, pre-generated .c), CORE (application.py hard import)
#     → dep: smart-open>=7.0.5  python-smart-open (pure Python)
#   importlib-metadata<=8.7.1   python-importlib-metadata
#     → pure Python, CORE (utils/source_info.py hard import)
#     → dep: zipp>=3.20          python-zipp (pure Python)
#   preprocess-cancellation=0.2.1 python-preprocess-cancellation
#     → pure Python, LAZY import in file_manager/metadata.py (try/except ImportError)
#
# BUCKET C — stdlib / not needed at runtime
#   (none — all requirements.txt entries either bucketed or dropped below)
#
# DROPPED optional components (import guarded by config section presence):
#   apprise>=1.9.3    → used ONLY by notifier.py; that component is NOT in
#                       CORE_COMPONENTS and loads ONLY when [notifier] section
#                       is present in moonraker.conf. Default conf has no [notifier].
#                       apprise itself depends on >10 optional plugins (requests,
#                       markdown, PyYAML, etc.) — too heavy, dropped.
#   ldap3==2.9.1      → used ONLY by ldap.py (optional LDAP auth). Not in
#                       CORE_COMPONENTS. Default conf has no [ldap]. Dropped.
# ──────────────────────────────────────────────────────────────────────────────

# Pinned master SHA — recorded in pins.lock.
MOONRAKER_VERSION = 9008485843740c93e0154ccbdac1fc2b02b03aaa
MOONRAKER_SITE = https://github.com/Arksine/moonraker.git
MOONRAKER_SITE_METHOD = git

MOONRAKER_LICENSE = GPL-3.0
MOONRAKER_LICENSE_FILES = LICENSE

MOONRAKER_DEPENDENCIES = \
	python3 \
	python-tornado \
	python-serial \
	python-pillow \
	python-distro \
	python-dbus-fast \
	python-zeroconf \
	python-paho-mqtt \
	python-jinja2 \
	python-periphery \
	python-wrapt \
	python-inotify-simple \
	python-libnacl \
	python-streaming-form-data \
	python-importlib-metadata \
	python-preprocess-cancellation \
	iproute2

define MOONRAKER_INSTALL_TARGET_CMDS
	# Install the moonraker Python tree to /opt/moonraker/
	rm -rf $(TARGET_DIR)/opt/moonraker
	mkdir -p $(TARGET_DIR)/opt/moonraker
	cp -r $(@D)/moonraker $(@D)/docs $(@D)/LICENSE $(@D)/README.md \
		$(TARGET_DIR)/opt/moonraker/

	# Write the pinned SHA as .version so moonraker can report it
	printf '%s\n' "$(MOONRAKER_VERSION)" \
		> $(TARGET_DIR)/opt/moonraker/moonraker/.version

	# Install default moonraker.conf (disabled non-essential components)
	$(INSTALL) -d $(TARGET_DIR)/etc/reforge
	$(INSTALL) -m 0644 $(MOONRAKER_PKGDIR)/moonraker.conf \
		$(TARGET_DIR)/etc/reforge/moonraker.conf
endef

$(eval $(generic-package))
