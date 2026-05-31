################################################################################
#
# python-preprocess-cancellation
#
################################################################################
# Single-file pure Python package (pyproject.toml uses old poetry format
# without [build-system] section; standard build tools cannot handle it).
# Install the single .py module directly to site-packages.

PYTHON_PREPROCESS_CANCELLATION_VERSION = 0.2.1
PYTHON_PREPROCESS_CANCELLATION_SOURCE = preprocess_cancellation-$(PYTHON_PREPROCESS_CANCELLATION_VERSION).tar.gz
PYTHON_PREPROCESS_CANCELLATION_SITE = https://files.pythonhosted.org/packages/4a/56/7e18b0336c1e6c6622411dd0d3a7634b171e4d156a13b1ceaa048682454a
PYTHON_PREPROCESS_CANCELLATION_LICENSE = GPL-3.0
PYTHON_PREPROCESS_CANCELLATION_LICENSE_FILES = LICENSE

define PYTHON_PREPROCESS_CANCELLATION_INSTALL_TARGET_CMDS
	$(INSTALL) -m 0644 $(@D)/preprocess_cancellation.py \
		$(TARGET_DIR)/usr/lib/python$(PYTHON3_VERSION_MAJOR)/site-packages/
endef

$(eval $(generic-package))
