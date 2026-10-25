################################################################################
#
# python-smart-open
#
################################################################################

PYTHON_SMART_OPEN_VERSION = 8.0.4
PYTHON_SMART_OPEN_SOURCE = smart_open-$(PYTHON_SMART_OPEN_VERSION).tar.gz
PYTHON_SMART_OPEN_SITE = https://files.pythonhosted.org/packages/68/e3/1fb5c310b1f55d99ba51cb81b8f1a0e4b5f89be44de69405aeeb12814778
PYTHON_SMART_OPEN_SETUP_TYPE = setuptools
PYTHON_SMART_OPEN_LICENSE = MIT
PYTHON_SMART_OPEN_LICENSE_FILES = LICENSE

PYTHON_SMART_OPEN_DEPENDENCIES = python-wrapt host-python-setuptools-scm
PYTHON_SMART_OPEN_ENV = SETUPTOOLS_SCM_PRETEND_VERSION_FOR_SMART_OPEN=$(PYTHON_SMART_OPEN_VERSION)

$(eval $(python-package))
