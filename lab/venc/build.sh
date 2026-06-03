#!/bin/sh
# build.sh — cross-compile the Cedar HW H.264 encoder probe for the AD5M (soft-float).
#
# The device's /usr/lib/libvenc*.so are SOFT-FLOAT (0x5000202, /lib/ld-linux.so.3), so the
# hard-float ReForge buildroot toolchain CANNOT be used — you need an arm-linux-gnueabi
# (soft-float) compiler. Linaro 7.5 works:
#   curl -fsSLO https://releases.linaro.org/components/toolchain/binaries/7.5-2019.12/arm-linux-gnueabi/gcc-linaro-7.5.0-2019.12-x86_64_arm-linux-gnueabi.tar.xz
#   tar xf gcc-linaro-*.tar.xz
#
# Stage the device's encoder libs into ./devlibs first (scp lacks sftp-server; use cat-pipe):
#   mkdir -p devlibs
#   for f in libvencoder libvenc_base libvenc_codec libvenc_common libvenc_h264 \
#            libvenc_h265 libvenc_jpeg libVE libMemAdapter libcdc_base; do
#     ssh root@PRINTER "cat /usr/lib/$f.so" > devlibs/$f.so; done
set -eu
CC="${CC:-arm-linux-gnueabi-gcc}"   # soft-float cross gcc (override with CC=/path/...-gcc)
"$CC" -O2 -march=armv7-a -mfloat-abi=soft -o enc_nv12_h264 enc_nv12_h264.c \
  -Ldevlibs -Wl,-rpath-link,devlibs \
  -lvencoder -lMemAdapter -lVE -lvenc_base -lvenc_codec -lvenc_common \
  -lvenc_h264 -lvenc_h265 -lvenc_jpeg -lcdc_base \
  -Wl,--allow-shlib-undefined -Wl,--unresolved-symbols=ignore-in-shared-libs \
  -lpthread -lm -lrt
echo "built enc_nv12_h264 ($("$CC" -dumpmachine))"
echo "deploy:  cat enc_nv12_h264 | ssh root@PRINTER 'cat > /data/venctest/enc; chmod +x /data/venctest/enc'"
echo "run:     ./enc in.nv12 out.h264 640 480 30 15 1500   (on device, PATH incl /sbin:/usr/sbin)"
