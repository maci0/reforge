################################################################################
#
# python-importlib-metadata
#
################################################################################
# Use 6.7.0 (minimum of moonraker's pinned range >= 6.7.0, <= 8.7.1).
# 6.7.0 requires only setuptools + setuptools_scm at build time.
# Newer versions add coherent.licensed as an additional build dep.

PYTHON_IMPORTLIB_METADATA_VERSION = 6.7.0
PYTHON_IMPORTLIB_METADATA_SOURCE = importlib_metadata-$(PYTHON_IMPORTLIB_METADATA_VERSION).tar.gz
PYTHON_IMPORTLIB_METADATA_SITE = https://files.pythonhosted.org/packages/a3/82/f6e29c8d5c098b6be61460371c2c5591f4a335923639edec43b3830650a4
PYTHON_IMPORTLIB_METADATA_SETUP_TYPE = setuptools
PYTHON_IMPORTLIB_METADATA_LICENSE = Apache-2.0
PYTHON_IMPORTLIB_METADATA_LICENSE_FILES = LICENSE
# setuptools_scm provides version from VCS; pretend-version avoids git requirement
PYTHON_IMPORTLIB_METADATA_DEPENDENCIES = python-zipp host-python-setuptools-scm
PYTHON_IMPORTLIB_METADATA_ENV = SETUPTOOLS_SCM_PRETEND_VERSION_FOR_IMPORTLIB_METADATA=$(PYTHON_IMPORTLIB_METADATA_VERSION)

$(eval $(python-package))
