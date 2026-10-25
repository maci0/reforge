################################################################################
#
# python-importlib-metadata
#
################################################################################
# Latest version supported by Moonraker (upstream caps importlib_metadata at 9.0.0).

PYTHON_IMPORTLIB_METADATA_VERSION = 9.0.0
PYTHON_IMPORTLIB_METADATA_SOURCE = importlib_metadata-$(PYTHON_IMPORTLIB_METADATA_VERSION).tar.gz
PYTHON_IMPORTLIB_METADATA_SITE = https://files.pythonhosted.org/packages/a9/01/15bb152d77b21318514a96f43af312635eb2500c96b55398d020c93d86ea
PYTHON_IMPORTLIB_METADATA_SETUP_TYPE = setuptools
PYTHON_IMPORTLIB_METADATA_LICENSE = Apache-2.0
PYTHON_IMPORTLIB_METADATA_LICENSE_FILES = LICENSE
# setuptools_scm provides version from VCS; pretend-version avoids git requirement
PYTHON_IMPORTLIB_METADATA_DEPENDENCIES = python-zipp host-python-setuptools-scm host-python-coherent-licensed
PYTHON_IMPORTLIB_METADATA_ENV = SETUPTOOLS_SCM_PRETEND_VERSION_FOR_IMPORTLIB_METADATA=$(PYTHON_IMPORTLIB_METADATA_VERSION)

$(eval $(python-package))
