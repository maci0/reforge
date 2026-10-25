################################################################################
#
# python-zipp
#
################################################################################

PYTHON_ZIPP_VERSION = 4.1.2
PYTHON_ZIPP_SOURCE = zipp-$(PYTHON_ZIPP_VERSION).tar.gz
PYTHON_ZIPP_SITE = https://files.pythonhosted.org/packages/18/05/ba1458dee0ac485b2a01071c1b88f5199fe878a485df482e10e1ef2205cc
PYTHON_ZIPP_SETUP_TYPE = setuptools
PYTHON_ZIPP_LICENSE = MIT
PYTHON_ZIPP_LICENSE_FILES = LICENSE
# setuptools_scm is used to determine version from VCS; need host dep
PYTHON_ZIPP_DEPENDENCIES = host-python-setuptools-scm host-python-coherent-licensed
PYTHON_ZIPP_ENV = SETUPTOOLS_SCM_PRETEND_VERSION_FOR_ZIPP=$(PYTHON_ZIPP_VERSION)

$(eval $(python-package))
