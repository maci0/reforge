#!/usr/bin/env bash
# Reconstruct the original kernel and modules from pinned source; never flash.
set -euo pipefail
if (( $# < 4 || $# > 5 )); then
    echo "usage: $0 KERNEL_SOURCE_TAR WIFI_SOURCE_TAR STOCK_IMAGE STOCK_WIFI_MODULE [OUTPUT_DIR]" >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/../.." && pwd)
kernel_archive=$(realpath "$1")
wifi_archive=$(realpath "$2")
reference=$(realpath "$3")
wifi_reference=$(realpath "$4")
out=$(realpath -m "${5:-${OUT:-$repo/build/bsp-kernel-rebuild-stock}}")
die() { echo "build-bsp-kernel-stock: $*" >&2; exit 1; }
[[ ! -e "$out" ]] || die "Output directory must be new: $out"
command -v bwrap >/dev/null || die 'bubblewrap is required for the original virtual build paths'
python3 -c 'import elftools' || die 'pyelftools is required for module verification'
cross="$repo/vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-"
[[ -x "${cross}gcc" ]] || die 'install the pinned Linaro 5.3.1 toolchain first'
patchdir="$repo/vendor/kernels/stock-patches"
mkdir -p "$(dirname "$out")"
python3 - "$repo" "$kernel_archive" "$wifi_archive" "$reference" "$wifi_reference" "$out" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
repo, kernel, wifi, reference, wifi_reference, out = map(Path, sys.argv[1:])
pins = {}
for line in (repo / 'pins.lock').read_text().splitlines():
    if line.strip() and not line.lstrip().startswith('#'):
        fields = line.split()
        if fields[0] in ('stock-kernel', 'stock-rtl8821cu', 'tina-bsp-kernel'):
            pins[fields[0]] = {'ref': fields[2], 'sha': fields[3], 'url': fields[4]}
def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()
for name, path in (('stock-kernel', kernel), ('stock-rtl8821cu', wifi)):
    if digest(path) != pins[name]['sha']:
        raise SystemExit(f'{name}: source archive SHA-256 mismatch')
for path, expected in ((reference, '902f44fe517aedd9424fa14adbf4f7c6212f372cfed10b19d479044a53111fa6'),
                       (wifi_reference, '7c0a036726227752359556f8e109683d5ce836bb65ec64afd46bfb754d6afa69')):
    if digest(path) != expected:
        raise SystemExit(f'{path}: original reference SHA-256 mismatch')
def extract(archive, destination, expected_root):
    with tarfile.open(archive) as source:
        members = source.getmembers()
        if not members or any(m.name != expected_root and not m.name.startswith(expected_root + '/')
                              for m in members):
            raise ValueError('source archive root does not match its pinned revision')
        if any(m.isfile() and Path(m.name).suffix in {'.o', '.a', '.ko', '.bin', '.elf'}
               for m in members):
            raise ValueError('prebuilt target member in source archive')
        source.extractall(destination, filter='data')
    return destination / expected_root
out.mkdir()
src = extract(kernel, out, 'longan-t113-linux-5.4-' + pins['stock-kernel']['ref'])
src.rename(out / 'source-tree')
src = out / 'source-tree'
staging = src / 'drivers/staging'
driver = extract(wifi, staging, '8821cu-20210118-' + pins['stock-rtl8821cu']['ref'])
driver.rename(staging / 'rtl8821cu')
# These original driver revisions are present in the held, pinned BSP source.
backports = ['drivers/net/can/sunxi_can.c',
             'drivers/i2c/busses/i2c-sunxi.c', 'drivers/pwm/pwm-sunxi-group.c',
             'drivers/pwm/pwm-sunxi-group.h']
backport_hashes = {}
for name in backports:
    data = subprocess.check_output(['git', '-C', str(repo / 'vendor/kernels/tina-bsp-kernel'),
                                    'show', pins['tina-bsp-kernel']['sha'] + ':' + name])
    (src / name).write_bytes(data)
    backport_hashes[name] = hashlib.sha256(data).hexdigest()
(out / 'inputs.json').write_text(json.dumps({
    'source_pins': pins, 'source_backports': backport_hashes,
    'kernel_reference_sha256': digest(reference),
    'wifi_reference_sha256': digest(wifi_reference),
    'target_objects_imported': False,
}, indent=2) + '\n')
PY
src="$out/source-tree"
obj="$out/kernel"
mkdir "$obj" "$out/artifacts"
patch --batch --forward --fuzz=0 -s -p1 -d "$src/drivers/staging/rtl8821cu" < "$patchdir/rtl8821cu.patch"
patches=("$patchdir/0001-source-integration.patch" "$patchdir/0002-stock-display.patch"
         "$patchdir/0003-stock-gmac-spi.patch" "$patchdir/0004-stock-goodix-mmc.patch"
         "$patchdir/0005-stock-tail.patch" "$patchdir/0006-stock-can.patch")
for source_patch in "${patches[@]}"; do
    patch --batch --forward --fuzz=0 -s -p1 -d "$src" < "$source_patch"
done
sha256sum "$patchdir/rtl8821cu.patch" "${patches[@]}" > "$out/source-patches.sha256"
{
    "${cross}gcc" --version
    "${cross}ld" --version
    sha256sum "${cross}gcc" "${cross}ld" "$("${cross}gcc" -print-prog-name=cc1)"
} > "$out/toolchain.txt"
: > "$src/.scmversion"
printf '51\n' > "$obj/.version"
gzip -dc "$repo/docs/board-notes/stock-kernel-config-5.4.61.txt.gz" > "$obj/.config"
cp "$obj/.config" "$obj/.config.captured"
stock_src=/home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4
stock_out=/home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/out/kernel/build
wifi_src=/home/linux/work/hard_t113/T113-Linux-Auto-v1.1/kernel/linux-5.4
wifi_out=/home/linux/work/hard_t113/T113-Linux-Auto-v1.1/out/kernel/build
# Both historical paths exist only inside this private namespace.
namespace=(bwrap --ro-bind / / --dev /dev --proc /proc --bind /tmp /tmp
           --tmpfs /home --ro-bind "$HOME" "$HOME"
           --dir "$(dirname "$stock_src")" --bind "$src" "$stock_src"
           --dir "$(dirname "$stock_out")" --bind "$obj" "$stock_out"
           --dir "$(dirname "$wifi_src")" --bind "$src" "$wifi_src"
           --dir "$(dirname "$wifi_out")" --bind "$obj" "$wifi_out"
           --bind "$out" "$out" --die-with-parent)
export SOURCE_DATE_EPOCH=1692776013
export KBUILD_BUILD_TIMESTAMP='Wed Aug 23 15:33:33 CST 2023'
export KBUILD_BUILD_USER=root KBUILD_BUILD_HOST=linux-virtual-machine KBUILD_BUILD_VERSION=52
common=(HOSTCXX=/bin/false ARCH=arm "CROSS_COMPILE=$cross")
"${namespace[@]}" make -C "$stock_src" "O=$stock_out" "${common[@]}" olddefconfig > "$out/configure.log" 2>&1
cmp -s "$obj/.config.captured" "$obj/.config" || die "configuration differs from stock; inspect $obj/.config"
if ! "${namespace[@]}" make -C "$stock_src" "O=$stock_out" "${common[@]}" -j"${BUILD_JOBS:-8}" Image > "$out/kernel.log" 2>&1; then
    tail -40 "$out/kernel.log" >&2
    exit 1
fi
# Wi-Fi's original module used this path/tuning and its own recovered build date.
if ! "${namespace[@]}" make -C "$wifi_src" "O=$wifi_out" "${common[@]}" \
    KCFLAGS=-mtune=cortex-a9 CONFIG_RTL8821CU=m CONFIG_PLATFORM_I386_PC=n \
    USER_EXTRA_CFLAGS='-DCONFIG_LITTLE_ENDIAN -DCONFIG_IOCTL_CFG80211 -DRTW_USE_CFG80211_STA_EVENT' \
    -j"${BUILD_JOBS:-8}" modules > "$out/modules.log" 2>&1; then
    tail -40 "$out/modules.log" >&2
    exit 1
fi
cp "$obj/arch/arm/boot/Image" "$out/artifacts/Image"
cp "$obj/vmlinux" "$obj/System.map" "$out/artifacts/"
cp "$obj/.config" "$out/artifacts/kernel.config"
cp "$obj/drivers/staging/rtl8821cu/8821cu.ko" "$out/artifacts/8821cu.ko"
python3 "$repo/tools/build/compare-stock-module.py" "$wifi_reference" "$out/artifacts/8821cu.ko" "$out/wifi-comparison.json"
python3 "$repo/tools/build/compare-stock-kernel.py" "$reference" "$out/artifacts/Image" "$out/comparison.json"
python3 - "$out" <<'PYREPORT'
import json
from pathlib import Path
import sys
out = Path(sys.argv[1])
kernel = json.loads((out / 'comparison.json').read_text())
wifi = json.loads((out / 'wifi-comparison.json').read_text())
print(json.dumps({'kernel_payload_equal': kernel['payload_equal'],
                  'kernel_full_file_equal': kernel['full_file_equal'],
                  'wifi_static_equivalent': wifi['runtime_equivalent'],
                  'wifi_full_file_equal': wifi['full_file_equal'],
                  'artifacts': str(out / 'artifacts')}))
PYREPORT
