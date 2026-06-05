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
	# Mainsail's upstream config.json ships "port": null, which makes the SPA
	# connect to Moonraker on the *page's own* port. ReForge serves Mainsail via
	# busybox httpd on :80 while Moonraker listens on :7125 with NO reverse proxy
	# (S70httpd is static-only), so with null the UI hits :80 and reports
	# "Cannot connect to Moonraker". Pin the port explicitly (same as forge-x).
	cp $(MAINSAIL_PKGDIR)/config.json $(TARGET_DIR)/var/www/mainsail/config.json
endef

MAINSAIL_LICENSE = GPL-3.0
MAINSAIL_LICENSE_FILES = LICENSE

$(eval $(generic-package))
