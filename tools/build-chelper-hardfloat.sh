#!/bin/sh
# build-chelper-hardfloat.sh — cross-compile a HARD-FLOAT (armhf) c_helper.so for the
# AD5M / 5M Pro (Allwinner T113-S3, Cortex-A7), so forge-x's klippy can run under the
# hard-float moonraker-env python3.11 — one shared interpreter instead of two, dropping
# the second interpreter's RSS.
#
# Why: forge-x ships a SOFT-FLOAT klipper world (stock python3.7 + a soft-float
# c_helper.so) and a separate HARD-FLOAT moonraker-env (python3.11). A soft-float .so
# cannot be dlopen()'d into a hard-float process — that is the `OSError: ... internal
# error` you get trying to point klippy at moonraker-env's python. This rebuilds
# c_helper.so hard-float from forge-x's OWN chelper sources (so the cffi cdef/symbol set
# matches that exact klipper version), using a cross toolchain — no gcc on the device.
#
# Usage:
#   tools/build-chelper-hardfloat.sh <path-to/klippy/chelper> [output.so]
# Copy forge-x's /opt/klipper/klippy/chelper off the device first, e.g.:
#   scp -r root@PRINTER:/opt/klipper/klippy/chelper /tmp/fx-chelper
#   tools/build-chelper-hardfloat.sh /tmp/fx-chelper
# then drop the resulting c_helper.so back into /opt/klipper/klippy/chelper on the device
# and point S60klipper's python at /root/moonraker-env/bin/python3.
set -eu

SRC="${1:?usage: build-chelper-hardfloat.sh <klippy/chelper dir> [out.so]}"
OUT="${2:-$SRC/c_helper.so}"
[ -f "$SRC/__init__.py" ] || { echo "error: no chelper/__init__.py in '$SRC' (point at klippy/chelper)" >&2; exit 1; }
# Resolve OUT to an absolute path NOW: the compile step cd's into $SRC, so a relative
# OUT (e.g. ./c_helper.hf.so) would otherwise be written relative to the chelper dir.
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac

# Cross compiler: prefer ReForge's buildroot armhf toolchain (its glibc is <= the
# device's, so the .so won't demand newer GLIBC symbols); else a system gnueabihf;
# else gnueabi forced to hard-float by the flags below.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CC=""
for c in "$REPO/build/output/host/bin/arm-buildroot-linux-gnueabihf-gcc" \
         arm-linux-gnueabihf-gcc arm-linux-gnueabi-gcc; do
  if command -v "$c" >/dev/null 2>&1; then CC="$c"; break; fi
done
[ -n "$CC" ] || { echo "error: no ARM cross gcc found (build ReForge once for its toolchain, or install arm-linux-gnueabihf-gcc)" >&2; exit 1; }

# Source list straight from the target's chelper/__init__.py SOURCE_FILES, so the built
# .so matches THIS klipper version's ffi cdef exactly. Fall back to every *.c in the dir.
SRCS=$(awk '/^SOURCE_FILES *= *\[/{f=1} f{print} f&&/\]/{exit}' "$SRC/__init__.py" \
       | grep -oE "'[A-Za-z0-9_]+\.c'" | tr -d "'" | tr '\n' ' ')
[ -n "$SRCS" ] || SRCS=$(cd "$SRC" && ls *.c | tr '\n' ' ')

echo "CC      = $CC"
echo "sources = $SRCS"
echo "output  = $OUT"

# Klipper's own COMPILE_ARGS (-O2 -shared -fPIC -flto -fwhole-program ...) + the
# Cortex-A7 hard-float flags from br-external/package/klipper/klipper.mk.
( cd "$SRC" && "$CC" \
    -O2 -mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard \
    -Wall -shared -fPIC -flto -fwhole-program -fno-use-linker-plugin \
    -o "$OUT" $SRCS )

# Verify it really is hard-float (the entire point) — fail loud otherwise.
# Authoritative check is the ELF header flags (0x*400 = hard-float, 0x*200 = soft);
# `file` mis-reports unstripped LTO objects, so use readelf.
RD=""; for r in "${CC%-gcc}-readelf" arm-linux-gnueabi-readelf readelf; do
  command -v "$r" >/dev/null 2>&1 && { RD="$r"; break; }
done
FLAGS=$("$RD" -h "$OUT" 2>/dev/null | sed -n 's/.*Flags:[[:space:]]*//p')
case "$FLAGS" in
  *hard-float*) echo "OK: hard-float c_helper.so built ($FLAGS)" ;;
  *) echo "ERROR: output is NOT hard-float ABI (flags: ${FLAGS:-unknown})" >&2; exit 1 ;;
esac
