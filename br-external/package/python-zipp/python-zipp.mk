################################################################################
#
# python-zipp
#
################################################################################

PYTHON_ZIPP_VERSION = 3.20.2
PYTHON_ZIPP_SOURCE = zipp-$(PYTHON_ZIPP_VERSION).tar.gz
PYTHON_ZIPP_SITE = https://files.pythonhosted.org/packages/54/bf/5c0000c44ebc80123ecbdddba1f5dcd94a5ada602a9c225d84b5aaa55e86
PYTHON_ZIPP_SETUP_TYPE = setuptools
PYTHON_ZIPP_LICENSE = MIT
PYTHON_ZIPP_LICENSE_FILES = LICENSE
# setuptools_scm is used to determine version from VCS; need host dep
PYTHON_ZIPP_DEPENDENCIES = host-python-setuptools-scm
PYTHON_ZIPP_ENV = SETUPTOOLS_SCM_PRETEND_VERSION_FOR_ZIPP=$(PYTHON_ZIPP_VERSION)

$(eval $(python-package))
