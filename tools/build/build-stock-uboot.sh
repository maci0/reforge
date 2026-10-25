#!/usr/bin/env bash
# Build a stock-comparison candidate from local SDK source; never flash it.
set -euo pipefail
if (( $# < 3 || $# > 4 )); then
    echo "usage: $0 LICHEE_ZIP CROSS_PREFIX STOCK_UBOOT_BIN [OUTPUT_DIR]" >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/../.." && pwd)
sdk=$(realpath "$1")
cross=$2
reference=$(realpath "$3")
out=$(realpath -m "${4:-$repo/build/stock-uboot}")
[[ -f "$sdk" && -f "$reference" ]] || { echo 'SDK or stock reference missing' >&2; exit 1; }
for tool in gcc ld.bfd objcopy; do
    command -v "${cross}${tool}" >/dev/null || { echo "missing compiler tool: ${cross}${tool}" >&2; exit 1; }
done
# Make invokes the prefix after changing directories.
cross=$(dirname "$(realpath "$(command -v "${cross}gcc")")")/$(basename "$cross")
# A fresh output directory cannot contain symlinks or overwrite the reference.
mkdir -p "$(dirname "$out")"
mkdir "$out" || { echo 'output directory must be new; choose another path' >&2; exit 1; }
work=$(mktemp -d /tmp/reforge-stock-uboot.XXXXXX)
trap 'rm -rf "$work"' EXIT
python3 - "$sdk" "$reference" "$work" "$out" <<'PY'
import hashlib
import calendar
import json
from pathlib import Path
import re
import stat
import struct
import sys
from zipfile import ZipFile
sdk, reference, work, out = map(Path, sys.argv[1:])
prefix = 'lichee/brandy-2.0/u-boot-2018/'
source = work / 'u-boot-2018'
source.mkdir()
with ZipFile(sdk) as archive:
    for entry in archive.infolist():
        if not entry.filename.startswith(prefix) or entry.is_dir():
            continue
        relative = Path(entry.filename[len(prefix):])
        if not relative.parts or relative.parts[0] == '.git':
            continue
        destination = (source / relative).resolve()
        if not destination.is_relative_to(source):
            raise SystemExit(f'unsafe SDK source member: {entry.filename}')
        if stat.S_ISLNK(entry.external_attr >> 16):
            target = archive.read(entry).decode('utf-8')
            if not (destination.parent / target).resolve().is_relative_to(source):
                raise SystemExit(f'unsafe SDK symlink: {entry.filename}')
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.symlink_to(target)
            continue
        if destination.suffix in {'.a', '.o', '.bin', '.elf'}:
            raise SystemExit(f'prebuilt target member in source tree: {entry.filename}')
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(archive.read(entry))
        destination.chmod((entry.external_attr >> 16) & 0o777 or 0o644)
source_digest = hashlib.sha256()
for path in sorted(source.rglob('*')):
    if path.is_file() or path.is_symlink():
        source_digest.update(path.relative_to(source).as_posix().encode() + b'\0')
        source_digest.update(path.readlink().as_posix().encode() if path.is_symlink() else path.read_bytes())
        source_digest.update(b'\0')
with sdk.open('rb') as stream:
    sdk_digest = hashlib.file_digest(stream, 'sha256').hexdigest()
# Suppress the vendor Makefile's unconditional binary toolchain extraction.
for name in ('gcc-linaro-7.2.1-2017.11-x86_64_arm-linux-gnueabi',
             'riscv64-linux-x86_64-20200528'):
    (work / 'tools/toolchain' / name).mkdir(parents=True)
stock = reference.read_bytes()
if len(stock) < 0x600 or stock[4:12] != b'uboot\0\0\0':
    raise SystemExit('reference is not a complete Allwinner U-Boot payload')
base = struct.unpack_from('<I', stock, 44)[0]
challenge_address = struct.unpack_from('<I', stock, 0x508)[0]
offset = challenge_address - base
if base != 0x43000000 or not 0x600 <= offset <= len(stock) - 128:
    raise SystemExit('reference challenge pointer does not match the source header layout')
# This is generated source data from the original build, not reused target code.
challenge = stock[offset:offset + 128]
c_source = ('__attribute__((__used__))\nunsigned char sunxi_challenge[] = {\n'
            + ',\n'.join('  ' + ', '.join(f'0x{x:02x}' for x in challenge[n:n+8])
                         for n in range(0, 128, 8))
            + '\n};\n__attribute__((__used__))\nunsigned int sunxi_challenge_len = 128;\n')
(source / 'board/sunxi/sunxi_challenge.c').write_text(c_source)
(out / 'sunxi_challenge.c').write_text(c_source)
match = re.search(rb'U-Boot 2018\.05 \(([A-Z][a-z]{2} [ 0-9][0-9] [0-9]{4}) - '
                  rb'([0-9:]{8}) ([+-][0-9]{4})\)', stock)
if match is None:
    raise SystemExit('expected original U-Boot 2018.05 build timestamp not found')
date, time, zone = (value.decode('ascii') for value in match.groups())
month, day, year = date.split()
month_number = list(calendar.month_abbr).index(month)
dmi_date = f'{month_number:02}/{int(day):02}/{year}'
build_date = f'{year}{month_number:02}{int(day):02}'
metadata = 'define filechk_timestamp.h\n(printf "%s\\n" '
metadata += ' '.join("'#define " + key + ' "' + value + '"' + "'" for key, value in
                     [('U_BOOT_DATE', date), ('U_BOOT_TIME', time), ('U_BOOT_TZ', zone),
                      ('U_BOOT_DMI_DATE', dmi_date)])
metadata += " '#define U_BOOT_BUILD_DATE 0x" + build_date + "')\nendef\n"
(out / 'build-metadata.mk').write_text(metadata)
(work / 'build-metadata.mk').write_text(metadata)
manifest = {'status': 'candidate-unverified', 'defconfig': 'sun8iw20p1_auto_defconfig',
            'sdk_sha256': sdk_digest,
            'source_tree_sha256_before_generated_inputs': source_digest.hexdigest(),
            'reference_sha256': hashlib.sha256(stock).hexdigest(),
            'challenge_offset': hex(offset), 'challenge_sha256': hashlib.sha256(challenge).hexdigest(),
            'timestamp': f'{date} {time} {zone}',
            'disabled_configs': ['CONFIG_LCD_SUPPORT_T050K589', 'CONFIG_SUNXI_MEM_INFO'],
            'control_dtb_source': 'stock-control.dts (recovered configuration, recompiled from source)',
            'packing': '16-KiB alignment, 0xff fill, regenerated lengths and additive checksum',
            'limitations': ['Original complete FlashForge defconfig and source revision remain unproven.',
                            'Matching packed size does not establish byte identity.',
                            'Boot0, OP-TEE and target blobs are not built or imported.']}
(out / 'inputs.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
src="$work/u-boot-2018"
python3 "$repo/tools/build/stock-uboot-image.py" extract-dtb "$reference" "$out/stock-control.reference.dtb"
common=(ARCH=arm "PWD=$src" "CROSS_COMPILE=$cross" "LICHEE_CHIP_CONFIG_DIR=$work/install" "LICHEE_PLAT_OUT=$work/install")
mkdir -p "$work/install/bin"
{
    "${cross}gcc" --version
    "${cross}ld.bfd" --version
    sha256sum "${cross}gcc" "${cross}ld.bfd" "$("${cross}gcc" -print-prog-name=cc1)"
    printf 'candidate config: sun8iw20p1_auto_defconfig\n'
    printf 'build inputs: %s\n' "$out/inputs.json"
} > "$out/toolchain.txt"
make -C "$src" "${common[@]}" sun8iw20p1_auto_defconfig > "$out/configure.log" 2>&1
# These generic SDK features are absent from the measured stock core.
python3 - "$src/.config" <<'PYCONFIG'
from pathlib import Path
import sys
config = Path(sys.argv[1])
text = config.read_text()
for name in ('CONFIG_LCD_SUPPORT_T050K589', 'CONFIG_SUNXI_MEM_INFO'):
    setting = name + '=y'
    if text.count(setting) != 1:
        raise SystemExit(f'expected one enabled SDK setting: {name}')
    text = text.replace(setting, '# ' + name + ' is not set')
config.write_text(text)
PYCONFIG
make -C "$src" "${common[@]}" olddefconfig >> "$out/configure.log" 2>&1
for setting in CONFIG_LCD_SUPPORT_T050K589 CONFIG_SUNXI_MEM_INFO; do
    grep -qx "# $setting is not set" "$src/.config"
done
# Avoid modern host version.h collisions and the old dtc's -fno-common failure.
printf '#define PLAIN_VERSION "2018.05"\n' > "$work/host-version.h"
hostflags="-O2 -fcommon -include $work/host-version.h"
if ! make -C "$src" -f Makefile -f "$work/build-metadata.mk" "${common[@]}" \
    "HOSTCFLAGS=$hostflags" -j"${JOBS:-8}" > "$out/build.log" 2>&1; then
    tail -40 "$out/build.log" >&2
    exit 1
fi
cp "$src/.config" "$out/uboot.config"
for artifact in u-boot u-boot-nodtb.bin u-boot.map; do
    cp "$src/$artifact" "$out/$artifact"
done
# Compile the original board configuration as source, then apply image packing.
"$src/scripts/dtc/dtc" -I dtb -O dts -o "$out/stock-control.dts" \
    "$out/stock-control.reference.dtb" 2> "$out/dtc.log"
"$src/scripts/dtc/dtc" -I dts -O dtb -o "$out/u-boot.dtb" \
    "$out/stock-control.dts" 2>> "$out/dtc.log"
python3 "$repo/tools/build/stock-uboot-image.py" pack "$out/u-boot-nodtb.bin" \
    "$out/u-boot.dtb" "$reference" "$out/u-boot.bin"
python3 - "$out" "$reference" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
out, reference = map(Path, sys.argv[1:])
a, b = reference.read_bytes(), (out / 'u-boot.bin').read_bytes()
report = {'status': 'identical' if a == b else 'different',
          'reference_bytes': len(a), 'candidate_bytes': len(b),
          'size_delta': len(b) - len(a), 'size_matches': len(a) == len(b),
          'packing_fill_bytes': len(b) - (out / 'u-boot-nodtb.bin').stat().st_size - (out / 'u-boot.dtb').stat().st_size,
          'reference_sha256': hashlib.sha256(a).hexdigest(),
          'candidate_sha256': hashlib.sha256(b).hexdigest(),
          'overlapping_mismatched_bytes': sum(x != y for x, y in zip(a, b)),
          'first_difference': next((n for n, (x, y) in enumerate(zip(a, b)) if x != y), None)}
(out / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
if a != b:
    raise SystemExit('SOURCE BUILD SUCCEEDED, BYTE-IDENTICAL REPRODUCTION FAILED; see comparison.json')
PY
