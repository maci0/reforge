#!/usr/bin/env bash
# Build the source reconstruction candidate and require an exact reference match.
set -euo pipefail
if (( $# != 5 )); then
    echo "usage: $0 PINNED_SOURCE_TAR_GZ GCC72_PREFIX GCC46_PREFIX STOCK_BOOT0_BIN NEW_OUTPUT_DIR" >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=$(realpath -m "$5")
[[ ! -e "$out" && ! -L "$out" ]] || { echo 'output directory must be new' >&2; exit 1; }
archive=$(realpath "$1")
reference=$(realpath "$4")
cross=$2
oldcross=$3
command -v "${oldcross}gcc" >/dev/null || { echo "missing Linaro GCC 4.6.3" >&2; exit 1; }
oldcross=$(dirname "$(realpath "$(command -v "${oldcross}gcc")")")/$(basename "$oldcross")
for tool in gcc ld objcopy strip ar; do
    command -v "${cross}${tool}" >/dev/null || { echo "missing tool: ${cross}${tool}" >&2; exit 1; }
done
cross=$(dirname "$(realpath "$(command -v "${cross}gcc")")")/$(basename "$cross")
mkdir -p "$(dirname "$out")"
mkdir "$out" || { echo 'output directory must be new' >&2; exit 1; }
python3 - "$archive" "$reference" "$out" "$repo/tools/build/patches/stock-boot0-reconstruction.patch" "$cross" "$oldcross" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import subprocess
import tarfile
archive, reference, out, patch = map(Path, sys.argv[1:5])
cross, oldcross = sys.argv[5:7]
expected = '2cb993eb5218ec53c9f35f8aa2435cc9e3fbee5873203149b2159509e9ef775b'
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
if digest != expected:
    raise SystemExit('source archive SHA-256 mismatch; use szemzoa/sun8iw20_spl@aedc18e734ecc71262fb64f962f485a12e56981c')
if hashlib.sha256(reference.read_bytes()).hexdigest() != 'f9397c286a0faba8cf19d7583b8f508470ce5e2ea1e6c53621d77d9f9b66093e':
    raise SystemExit('reference SHA-256 mismatch; expected the original AD5M boot0')
compiler_paths = {name + '72': Path(cross + name).resolve()
                  for name in ('gcc', 'ld', 'objcopy', 'strip', 'ar')}
compiler_paths['gcc46'] = Path(oldcross + 'gcc').resolve()
for version in ('72', '46'):
    for program in ('cc1', 'as'):
        path = subprocess.check_output([str(compiler_paths['gcc' + version]),
                                        '-print-prog-name=' + program], text=True).strip()
        compiler_paths[program + version] = Path(path).resolve()
expected_tools = {'gcc72': '20280aed3a14ae280aa206c06aa888e1d9eac3c8023f493e529c9a66ffdcb0e0', 'ld72': '0e4e83b73d008a43be937da1a0c903c6bdddad0d3be5a8a0d553551c208b32c7', 'objcopy72': 'd9fb6bea071255c49a1017d3b96977087ff7114a1280c9c273871cf72dc7b54f', 'strip72': '8fa14db0da7ec9e8874602da373099f3e00ec45f9bbfbadf7910179c3d50167c', 'gcc46': '2a1337ee0a2b1151ec87a0ca974748c975c73342e68d598e5235c3fac3c5d9a8', 'cc172': 'c27e37274963d8fd06545ac17a22a45176aa8d3652f71196ab361bd18f6e81cd', 'as72': '8f239890b7796bc45d14f7b1a0dc667731b87288190c3ef99bb06ea6b51497b9', 'cc146': 'f256ce473d1a01a36357611feb3b5eb3a6546d27528a73f49496c29b858a2847', 'as46': '83c91670e71ff5fd70c9b98d7f4e7bff1f930fffe34c323ae44333e6fe5565c3', 'ar72': 'd85ead4e88a73a3e5c21fbc466745ac6d07208ebc72983f21c60df9671a02011'}
compiler_files = {}
for name, path in compiler_paths.items():
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected_tools[name]:
        raise SystemExit(f'original compiler component SHA-256 mismatch: {name}')
    compiler_files[name] = {'path': str(path), 'sha256': actual}
source = out / 'source'
source.mkdir()
prefix = 'sun8iw20_spl-aedc18e734ecc71262fb64f962f485a12e56981c/'
discarded = []
with tarfile.open(archive) as bundle:
    for entry in bundle:
        if entry.isdir() and entry.name.rstrip('/') == prefix.rstrip('/'):
            continue
        if not entry.name.startswith(prefix):
            raise SystemExit('unexpected archive prefix')
        relative = Path(entry.name[len(prefix):])
        if entry.isdir():
            continue
        if not entry.isfile() or not relative.parts or relative.is_absolute() or '..' in relative.parts:
            raise SystemExit(f'unsafe source member: {entry.name}')
        data = bundle.extractfile(entry).read()
        if relative.as_posix() == 'drivers/dram/sun8iw20p1/libdram':
            # Bundled extensionless ELF is deliberately NEVER extracted or linked.
            if hashlib.sha256(data).hexdigest() != '4bfb0dc36d5fef532af41746f5a994d35184430764628f9259b6f4c2b0947db1':
                raise SystemExit('unexpected bundled libdram identity')
            discarded.append(relative.as_posix())
            continue
        if data.startswith((b'\x7fELF', b'!<arch>')) or relative.suffix in {'.o', '.a', '.elf', '.bin', '.ko'}:
            raise SystemExit(f'prebuilt target member: {entry.name}')
        destination = source / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        destination.chmod(entry.mode & 0o777)
manifest = {'status': 'source-reconstruction-candidate',
            'source_repository': 'https://github.com/szemzoa/sun8iw20_spl',
            'source_commit': 'aedc18e734ecc71262fb64f962f485a12e56981c',
            'source_archive_sha256': digest,
            'compiler_files': compiler_files,
            'runtime_sources': {str(path.relative_to(patch.parents[3])): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in sorted((patch.parents[3] / 'vendor/runtime/gcc-7.2.0-arm').glob('*.S'))},
            'compiler_profiles': {'main': 'Linaro GCC 7.2.1, vendor mk/config.mk -Os; default ARMv7-A Thumb cortex-a9',
                                  'legacy_chip_id': 'Linaro GCC 4.6.3 2012.02; -Os -mthumb -march=armv7-a -mtune=cortex-a9 -fno-builtin -ffreestanding -fno-stack-protector -fno-common -msoft-float'},
            'authored_patch_sha256': hashlib.sha256(patch.read_bytes()).hexdigest(),
            'discarded_prebuilt_members': discarded,
            'reference_sha256': hashlib.sha256(reference.read_bytes()).hexdigest(),
            'profile': 'sun8iw20p1 MMC, stock TWI/AXP1530/standby, no data cache',
            'limitations': ['Historical DRAM C spelling is not fully recovered; named assembly implements the verified original program',
                            'historical source commit 5224261 has not been recovered',
                            'compiler supplied locally; no compiler bootstrap claim',
                            'reference is comparison-only and never a build input'],
            'source_label_generation': 'vendor Git generator; discovery bounded at output directory because the exported archive has no Git metadata',
            'packing': 'vendor default-seed glibc TYPE_3 rand stream, 16-KiB alignment and additive checksum'}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
src=$out/source
GIT_CEILING_DIRECTORIES="$out" git -C "$src" apply "$repo/tools/build/patches/stock-boot0-reconstruction.patch"
# The archive and patch contain source only. Clean also guards against local reuse.
GIT_CEILING_DIRECTORIES="$out" make -C "$src" p=sun8iw20p1 CROSS_COMPILE="$cross" CHIP_ID_CC="${oldcross}gcc" clean > "$out/clean.log" 2>&1
python3 - "$src/drivers/dram/sun8iw20p1/libdram" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PY
"${cross}gcc" --version > "$out/compiler.txt"
"${cross}ld" --version > "$out/linker.txt"
"${oldcross}gcc" --version > "$out/legacy-compiler.txt"
# Compile the only target runtime routines boot0 needs; never link toolchain libgcc.a.
runtime=$out/runtime
mkdir "$runtime"
for unit in udivsi3 divsi3 dvmd_lnx; do
    "${cross}gcc" -c -g -O2 -fPIC "-DL_$unit" \
        "$repo/vendor/runtime/gcc-7.2.0-arm/lib1funcs.S" -o "$runtime/_$unit.o"
done
"${cross}ar" rcsD "$runtime/libgcc-source.a" \
    "$runtime/_udivsi3.o" "$runtime/_divsi3.o" "$runtime/_dvmd_lnx.o"
GIT_CEILING_DIRECTORIES="$out" make -C "$src" p=sun8iw20p1 CROSS_COMPILE="$cross" CHIP_ID_CC="${oldcross}gcc" PLATFORM_LIBGCC="$runtime/libgcc-source.a" -j"${JOBS:-4}" V=1 mmc > "$out/build.log" 2>&1
mkdir "$out/artifacts"
cp "$src/nboot/boot0_sdcard.elf" "$src/nboot/boot0_sdcard.bin" "$src/nboot/boot0_sdcard.map" "$out/artifacts/"
python3 "$repo/tools/build/pack-stock-boot0.py" "$out/artifacts/boot0_sdcard.bin" "$out/artifacts/boot0.bin"
python3 - "$reference" "$out" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import struct
reference, out = map(Path, sys.argv[1:])
stock = reference.read_bytes()
candidate = (out / 'artifacts/boot0.bin').read_bytes()
manifest = json.loads((out / 'manifest.json').read_text())
equal = candidate == stock
# Reporting predicates never relax the strict whole-file acceptance below.
fields = [(12, 16, 'additive_checksum'), (0x2f8, 0x308, 'source_commit_label')]
def field_for(offset):
    return next((name for start, end, name in fields if start <= offset < end), 'program_or_configuration')
different = [offset for offset, (a, b) in enumerate(zip(candidate, stock)) if a != b]
runs = []
for offset in different:
    kind = field_for(offset)
    if runs and offset == runs[-1]['offset'] + runs[-1]['length'] and kind == runs[-1]['field']:
        runs[-1]['length'] += 1
    else:
        runs.append({'offset': offset, 'length': 1, 'field': kind})
for run in runs:
    start, length = run['offset'], run['length']
    run['offset_hex'] = hex(start)
    if run['field'] != 'program_or_configuration':
        run['candidate_hex'] = candidate[start:start + length].hex()
        run['reference_hex'] = stock[start:start + length].hex()
label_start, label_end = 0x2f8, 0x308
outside_equal = len(candidate) == len(stock) and all(field_for(offset) != 'program_or_configuration' for offset in different)
def word_sum(data):
    return sum(value[0] for value in struct.iter_unpack('<I', data))
checksums = [struct.unpack_from('<I', data, 12)[0] for data in (candidate, stock)]
checksum_valid = [((word_sum(data) - checksum + 0x5f0a6c39) & 0xffffffff) == checksum
                  for data, checksum in zip((candidate, stock), checksums)]
labels = [data[label_start:label_end] for data in (candidate, stock)]
manifest['runtime_archive_sha256'] = hashlib.sha256((out / 'runtime/libgcc-source.a').read_bytes()).hexdigest()
manifest['difference_ledger'] = runs
manifest['all_bytes_outside_source_label_and_checksum_equal'] = outside_equal
manifest['identical_byte_positions'] = min(len(candidate), len(stock)) - len(different)
manifest['source_commit_label'] = {'offset': hex(label_start), 'field_length': label_end - label_start,
    'candidate_hex': labels[0].hex(), 'reference_hex': labels[1].hex(),
    'candidate_printable': labels[0].split(b'\0')[0].decode('ascii', errors='replace'),
    'reference_printable': labels[1].split(b'\0')[0].decode('ascii', errors='replace')}
manifest['checksum'] = {'candidate': hex(checksums[0]), 'reference': hex(checksums[1]),
    'candidate_valid': checksum_valid[0], 'reference_valid': checksum_valid[1],
    'difference_explained_by_source_label': outside_equal and
        ((checksums[0] - checksums[1]) & 0xffffffff) == ((word_sum(labels[0]) - word_sum(labels[1])) & 0xffffffff)}
manifest['generated_commit_header'] = (out / 'source/include/commit_info.h').read_text()
manifest.update({'status': 'byte-identical' if equal else 'comparison-failed',
                 'candidate_sha256': hashlib.sha256(candidate).hexdigest(),
                 'candidate_length': len(candidate), 'reference_length': len(stock),
                 'different_positions_in_common_length': sum(a != b for a, b in zip(candidate, stock)),
                 'extra_candidate_bytes': max(0, len(candidate) - len(stock)),
                 'missing_candidate_bytes': max(0, len(stock) - len(candidate))})
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
if not equal:
    raise SystemExit('boot0 source candidate differs from stock; artifacts and gap manifest retained')
PY
