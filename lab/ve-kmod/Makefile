obj-m += ve_diag.o
KSRC ?= /home/maci/Desktop/Projects/flashforge/reforge/vendor/kernels/tina-bsp-kernel
CROSS ?= /home/maci/Desktop/Projects/flashforge/reforge/vendor/toolchains/gcc-9.5.0-nolibc/arm-linux-gnueabi/bin/arm-linux-gnueabi-
all:
	$(MAKE) -C $(KSRC) ARCH=arm CROSS_COMPILE=$(CROSS) M=$(PWD) modules
clean:
	$(MAKE) -C $(KSRC) ARCH=arm CROSS_COMPILE=$(CROSS) M=$(PWD) clean
