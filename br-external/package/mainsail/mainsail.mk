################################################################################
#
# mainsail
#
################################################################################

MAINSAIL_VERSION = v2.19.0
MAINSAIL_SITE = $(call github,mainsail-crew,mainsail,$(MAINSAIL_VERSION))
MAINSAIL_DEPENDENCIES = host-nodejs-src host-zip

# Use upstream's locked source dependencies and production build. Cypress is
# only a host test tool; its browser binary is not needed to compile the SPA.
define MAINSAIL_BUILD_CMDS
	cd $(@D) && $(HOST_MAKE_ENV) CYPRESS_INSTALL_BINARY=0 \
		$(HOST_DIR)/bin/npm ci --no-audit --no-fund
	cd $(@D) && $(HOST_MAKE_ENV) $(HOST_DIR)/bin/npm run build
endef

define MAINSAIL_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/var/www/mainsail
	mkdir -p $(TARGET_DIR)/var/www/mainsail
	cp -a $(@D)/dist/. $(TARGET_DIR)/var/www/mainsail/
	rm -f $(TARGET_DIR)/var/www/mainsail/mainsail.zip
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
