################################################################################
#
# mainsail
#
################################################################################

MAINSAIL_VERSION = v2.17.0
MAINSAIL_SITE = https://github.com/mainsail-crew/mainsail/releases/download/$(MAINSAIL_VERSION)
MAINSAIL_SOURCE = mainsail.zip

# Buildroot does not auto-extract .zip archives the same way it handles
# tarballs — provide explicit extraction via host unzip.
define MAINSAIL_EXTRACT_CMDS
	$(UNZIP) $(MAINSAIL_DL_DIR)/$(MAINSAIL_SOURCE) -d $(@D)/
endef

define MAINSAIL_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/var/www/mainsail
	cp -a $(@D)/* $(TARGET_DIR)/var/www/mainsail/
endef

MAINSAIL_LICENSE = GPL-3.0
MAINSAIL_LICENSE_FILES = LICENSE

$(eval $(generic-package))
