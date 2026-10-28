#!/usr/bin/env bash
# Build only CPython's core; retain the fixture's stdlib and native extensions.
set -euo pipefail
[[ $# = 5 ]] || { echo "usage: $0 arm-o3|thumb-os|thumb-os-lto SOURCE SYSROOT HOST_PYTHON NEW_OUTPUT" >&2; exit 2; }
variant=$1
source_dir=$(realpath "$2")
sysroot=$(realpath "$3")
host_python=$(realpath "$4")
out=$(realpath -m "$5")
repo=$(cd "$(dirname "$0")/../.." && pwd)
cross=${CROSS_COMPILE:-$repo/build/output/host/bin/arm-buildroot-linux-gnueabihf-}
case $variant in
    arm-o3) flags='-marm -O3'; lto=no ;;
    thumb-os) flags='-mthumb -Os'; lto=no ;;
    thumb-os-lto) flags='-mthumb -Os'; lto=full ;;
    *) echo "unknown variant: $variant" >&2; exit 2 ;;
esac
[[ ! -e $out ]] || { echo "output must be new: $out" >&2; exit 2; }
[[ -f $source_dir/Include/Python.h && -f $sysroot/usr/lib/libc.so && -x $host_python ]] || exit 2
mkdir -p "$out"
# Bypass Reforge's toolchain wrapper so its product flags cannot affect this trial.
compiler=${cross}gcc.br_real
[[ -x $compiler ]] || compiler=${cross}gcc
printf '#!/bin/sh\nexec %q --sysroot=%q -mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard "$@"\n' "$compiler" "$sysroot" > "$out/trial-gcc"
chmod +x "$out/trial-gcc"
cd "$out"
READELF="${cross}readelf" PKG_CONFIG=/bin/false CC="$out/trial-gcc" AR="${cross}gcc-ar" RANLIB="${cross}gcc-ranlib" \
    CFLAGS="$flags -g0 -D_LARGEFILE_SOURCE -D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64 -D_FORTIFY_SOURCE=1" \
    OPT='-DNDEBUG -fwrapv -Wall' \
    ac_cv_file__dev_ptmx=yes ac_cv_file__dev_ptc=no ac_cv_buggy_getaddrinfo=no \
    "$source_dir/configure" --host=arm-linux-gnueabihf --build=x86_64-pc-linux-gnu \
      --prefix=/usr --enable-shared --without-ensurepip --disable-test-modules \
      --with-build-python="$host_python" --with-lto="$lto" > configure.log 2>&1
if [[ $lto = full ]]; then
    grep -q '^CONFIGURE_CFLAGS_NODIST=.*-flto' Makefile
fi
make -j"${BUILD_JOBS:-12}" python > build.log 2>&1
mkdir artifacts
cp python artifacts/python3.11
cp libpython3.11.so.1.0 artifacts/
"${cross}strip" --strip-unneeded artifacts/python3.11 artifacts/libpython3.11.so.1.0
"${cross}readelf" -A artifacts/libpython3.11.so.1.0 > attributes.txt
"${cross}readelf" -V artifacts/libpython3.11.so.1.0 > versions.txt
"${cross}nm" -D artifacts/libpython3.11.so.1.0 > dynamic-symbols.txt
python3 - "$variant" "$source_dir" "$compiler" <<'PY'
import hashlib, json, pathlib, re, shlex, subprocess, sys
variant, source, compiler = sys.argv[1:]
artifacts = {str(p): {'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
             for p in pathlib.Path('artifacts').iterdir()}
report = {'variant': variant, 'source': source, 'compiler': subprocess.check_output([compiler, '--version'], text=True).splitlines()[0],
          'artifacts': artifacts, 'make_flags': [l for l in pathlib.Path('Makefile').read_text().splitlines()
                                               if l.startswith(('CONFIGURE_CFLAGS=', 'OPT=', 'PY_CFLAGS=', 'PY_CORE_CFLAGS=', 'PY_LDFLAGS=', 'CONFIGURE_CFLAGS_NODIST=', 'CONFIGURE_LDFLAGS_NODIST='))]}
ceval = next(l for l in pathlib.Path('build.log').read_text().splitlines() if ' -c ' in l and 'Python/ceval.c' in l)
assert ('-flto' in ceval) == (variant == 'thumb-os-lto'), ceval
tokens = shlex.split(ceval)
optimizations = [t for t in tokens if re.fullmatch(r'-O[0-3sgz]|-Ofast', t)]
assert optimizations[-1] == ('-O3' if variant == 'arm-o3' else '-Os'), optimizations
assert ('-marm' if variant == 'arm-o3' else '-mthumb') in tokens
versions = sorted(set(re.findall(r'GLIBC_[0-9.]+', pathlib.Path('versions.txt').read_text())),
                  key=lambda v: tuple(map(int, v[6:].split('.'))))
assert tuple(map(int, versions[-1][6:].split('.'))) <= (2, 38), versions
report['maximum_required_glibc'] = versions[-1]
report['ceval_compile_command'] = ceval
pathlib.Path('trial-build.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
PY
