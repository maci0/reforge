#!/usr/bin/env bash
# Target C/C++ compiler for the clang-oz variants: host clang aimed at the
# Buildroot sysroot, linking against the GCC toolchain's crt files, libgcc and
# libstdc++. Installed as host/bin/clang-cc and clang-c++ by build-oz.sh, which sets
# REFORGE_BR_HOST (the output host/ dir) and REFORGE_BR_TRIPLE (the GCC target
# triple, glibc or musl). Mirrors the -mcpu/-mfpu/-mfloat-abi and Thumb-2
# settings Buildroot's own toolchain wrapper adds for gcc.
set -euo pipefail
host=${REFORGE_BR_HOST:?REFORGE_BR_HOST unset}
triple=${REFORGE_BR_TRIPLE:?REFORGE_BR_TRIPLE unset}
case "$(basename "$0")" in
    clang-c++) cc=clang++ ;;
    *) cc=clang ;;
esac

# gcc driver spellings clang rejects or that conflict with the added flags.
icf=("-Wl,--icf=all")
args=()
link=1
for a in "$@"; do
    case "$a" in
        -r|-Wl,-r) icf=(); args+=("$a") ;;       # lld: -r and --icf are exclusive
        -z?*) args+=("-Wl,-z,${a#-z}") ;;        # gcc takes -ztext, clang only -z text
        -mfp16-format=ieee) ;;                   # gcc-only; IEEE is clang's only fp16 format
        -c|-S|-E|-M|-MM) link=0; args+=("$a") ;;
        # greenlet's arm32 slp_switch() adjusts r7 as the frame pointer and
        # asks for one with gcc's optimize("no-omit-frame-pointer"), which
        # clang ignores; without it klippy's reactor segfaults on switch.
        */greenlet/*.cpp) args+=(-fno-omit-frame-pointer "$a") ;;
        *) args+=("$a") ;;
    esac
done
# RTABI helpers clang calls but libgcc lacks (aeabi-d2h.c); archive members
# are pulled in only by objects that reference them.
if [ "$link" = 1 ] && [ -f "$host/lib/libreforge-aeabi.a" ]; then
    args+=("$host/lib/libreforge-aeabi.a")
fi

# -Qunused-arguments: the link-only flags below are also passed on compile-only
# invocations, where clang would otherwise warn (fatal under package -Werror).
# --undefined-version: lld >= 17 rejects version scripts naming undefined
# symbols (zlib.map does); GNU ld, which these packages target, accepts them.
exec "$cc" --target="$triple" --sysroot="$host/$triple/sysroot" \
    --gcc-toolchain="$host" \
    -mcpu=cortex-a7 -mfpu=vfpv4 -mfloat-abi=hard -mthumb \
    -moutline -fuse-ld=lld "${icf[@]}" -Wl,--undefined-version \
    -Qunused-arguments "${args[@]}"
