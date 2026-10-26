include $(sort $(wildcard $(BR2_EXTERNAL_REFORGE_PATH)/package/*/*.mk))

# Kernel source/config selectors live in local.mk, loaded before linux/linux.mk.
