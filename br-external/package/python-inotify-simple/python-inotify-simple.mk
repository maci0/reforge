################################################################################
#
# python-inotify-simple
#
################################################################################

PYTHON_INOTIFY_SIMPLE_VERSION = 2.0.1
PYTHON_INOTIFY_SIMPLE_SOURCE = inotify_simple-$(PYTHON_INOTIFY_SIMPLE_VERSION).tar.gz
PYTHON_INOTIFY_SIMPLE_SITE = https://files.pythonhosted.org/packages/e3/5c/bfe40e15d684bc30b0073aa97c39be410a5fbef3d33cad6f0bf2012571e0
PYTHON_INOTIFY_SIMPLE_SETUP_TYPE = setuptools
PYTHON_INOTIFY_SIMPLE_LICENSE = BSD-2-Clause
PYTHON_INOTIFY_SIMPLE_LICENSE_FILES = LICENSE

$(eval $(python-package))
