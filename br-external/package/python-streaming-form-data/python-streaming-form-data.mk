################################################################################
#
# python-streaming-form-data
#
################################################################################
# Pre-generated .c file in sdist — no Cython needed at build time.

PYTHON_STREAMING_FORM_DATA_VERSION = 2.1.0
PYTHON_STREAMING_FORM_DATA_SOURCE = streaming_form_data-$(PYTHON_STREAMING_FORM_DATA_VERSION).tar.gz
PYTHON_STREAMING_FORM_DATA_SITE = https://files.pythonhosted.org/packages/dc/fd/d49f3b4e6258e865566fd8aa3da9966f47ca5a7d7fd8ca181f8209010605
PYTHON_STREAMING_FORM_DATA_SETUP_TYPE = setuptools
PYTHON_STREAMING_FORM_DATA_LICENSE = MIT
PYTHON_STREAMING_FORM_DATA_LICENSE_FILES = LICENSE.txt
PYTHON_STREAMING_FORM_DATA_DEPENDENCIES = python-smart-open python-aiofiles

$(eval $(python-package))
