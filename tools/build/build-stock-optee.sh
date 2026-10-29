#!/usr/bin/env bash
# Build the incomplete T113 OP-TEE reconstruction from source. Never flash.
set -euo pipefail
if (( $# < 2 || $# > 3 )); then
    echo "usage: $0 SOURCE_TAR OUTPUT_DIR [STOCK_OPTEE_COMPARISON_REFERENCE]" >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/../.." && pwd)
archive=$(realpath "$1")
out=$(realpath -m "$2")
reference=${3:-}
[[ -z "$reference" ]] || reference=$(realpath "$reference")
[[ ! -e "$out" ]] || { echo "Output directory must be new: $out" >&2; exit 1; }
python3 - "$archive" "$reference" <<'PYPREFLIGHT'
from pathlib import Path
import hashlib
import sys
for filename, expected, label in (
    (sys.argv[1], '1662d74cd682ebfe1d52b3ced8a61c2d490a12a011b9c4255a73bd6b460e1b58', 'OP-TEE source archive'),
    (sys.argv[2], '7ccd7a54ae2142f68d6bac60e3e2b36ccbfa2ec677aa6ce84342cc6f1b821c99', 'Original OP-TEE comparison reference'),
):
    if filename and hashlib.sha256(Path(filename).read_bytes()).hexdigest() != expected:
        raise SystemExit(label + ' SHA-256 mismatch')
PYPREFLIGHT
cross="$repo/vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-"
[[ -x "${cross}gcc" ]] || { echo 'Install the pinned Linaro 5.3.1 toolchain first.' >&2; exit 1; }
python3 -c 'from Crypto.PublicKey import RSA' || exit 1
python3 - "$archive" "$out" <<'PY'
from pathlib import Path
import hashlib
import json
import sys
import tarfile
archive, out = map(Path, sys.argv[1:])
expected = '1662d74cd682ebfe1d52b3ced8a61c2d490a12a011b9c4255a73bd6b460e1b58'
revision = 'a2fa5018cb595a9cd9ab62e82c7485ca57a62084'
root = 'optee_os-' + revision
with archive.open('rb') as stream:
    actual = hashlib.file_digest(stream, 'sha256').hexdigest()
if actual != expected:
    raise SystemExit('OP-TEE source archive SHA-256 mismatch')
with tarfile.open(archive) as source:
    members = source.getmembers()
    if not members or any(m.name != root and not m.name.startswith(root + '/')
                          for m in members):
        raise SystemExit('Unexpected OP-TEE source archive root')
    if any(m.isfile() and Path(m.name).suffix in {'.o', '.a', '.ko', '.bin', '.elf'}
           for m in members):
        raise SystemExit('Prebuilt target member in source archive')
    out.mkdir(parents=True)
    source.extractall(out, filter='data')
(out / root).rename(out / 'source-tree')
(out / 'inputs.json').write_text(json.dumps({
    'source_url': 'https://codeload.github.com/OP-TEE/optee_os/tar.gz/' + revision,
    'source_revision': revision,
    'source_archive_sha256': actual,
    'source_date_epoch': 1571399438,
    'implementation_version': '3.7.0-reforge-reconstruction',
    'profile': 'sun8iw20p1',
    'status': 'incomplete research reconstruction; not stock-equivalent',
    'stock_reference_used_as_source': False,
    'target_objects_imported': False,
    'source_git_discovery': 'bounded at output directory; source archive has no Git metadata',
}, indent=2) + '\n')
PY
patchdir="$repo/vendor/optee/stock-patches"
patches=("$patchdir/0001-upstream-sm4.patch" "$patchdir/0002-upstream-sm3.patch"
         "$patchdir/0003-t113-reconstruction.patch"
         "$patchdir/0004-source-header-console-reset.patch"
         "$patchdir/0005-source-hash-installer.patch"
         "$patchdir/0006-source-smc-config.patch"
         "$patchdir/0007-source-hardware-policy.patch"
         "$patchdir/0008-source-standby-wrapper.patch"
         "$patchdir/0009-source-mmu-table-split.patch"
         "$patchdir/0010-source-late-reset-hook.patch"
         "$patchdir/0011-source-secondary-boot.patch"
         "$patchdir/0012-source-psci-identification.patch"
         "$patchdir/0013-source-cpu-control.patch")
for source_patch in "${patches[@]}"; do
    patch --batch --forward --fuzz=0 -s -p1 -d "$out/source-tree" < "$source_patch"
done
sha256sum "${patches[@]}" > "$out/source-patches.sha256"
# Compile the entire SRAM payload before embedding; the stock reference is comparison-only.
CROSS_COMPILE="$cross" "$repo/tools/build/build-stock-optee-standby.sh" "$out/standby-build" \
    > "$out/standby-build.log"
cp "$out/standby-build/standby.bin" "$out/source-tree/core/arch/arm/plat-sun8iw20p1/standby.bin"
cp "$repo/vendor/optee/standby-host-src/reset-late.S" "$out/source-tree/core/arch/arm/plat-sun8iw20p1/reset_late.S"
cp "$repo/vendor/optee/standby-host-src/psci-identification.c" "$out/source-tree/core/arch/arm/plat-sun8iw20p1/psci_identification.c"
cp "$repo/vendor/optee/standby-host-src/cpu-control.S" "$out/source-tree/core/arch/arm/plat-sun8iw20p1/cpu_control.S"
sha256sum "$repo/vendor/optee/standby-host-src/reset-late.S" \
    "$repo/vendor/optee/standby-host-src/psci-identification.c" \
    "$repo/vendor/optee/standby-host-src/cpu-control.S" > "$out/host-sources.sha256"

{
    "${cross}gcc" --version
    "${cross}ld" --version
    sha256sum "${cross}gcc" "${cross}ld" "$("${cross}gcc" -print-prog-name=cc1)"
} > "$out/toolchain.txt"
export SOURCE_DATE_EPOCH=1571399438 LC_ALL=C TZ=UTC
# Do not let an exported source tree inherit an unrelated parent repository revision.
if ! GIT_CEILING_DIRECTORIES="$out" make -C "$out/source-tree" PLATFORM=sun8iw20p1 "O=$out/build" \
    "CROSS_COMPILE=$cross" TEE_IMPL_VERSION=3.7.0-reforge-reconstruction \
    -j"${BUILD_JOBS:-8}" > "$out/build.log" 2>&1; then
    tail -35 "$out/build.log" >&2
    exit 1
fi
mkdir "$out/artifacts"
cp "$out/build/core/tee.bin" "$out/build/core/tee.elf" "$out/build/core/tee.map" "$out/artifacts/"
cp "$out/build/core/tee-pager.bin" "$out/artifacts/optee.bin"
cp "$out/build/conf.mk" "$out/artifacts/profile.mk"
# Reference bytes are never inputs to source compilation.
python3 - "$out" "$reference" <<'PY'
from pathlib import Path
import hashlib
import json
import struct
import sys
out = Path(sys.argv[1])
candidate = out / 'artifacts/optee.bin'
data = candidate.read_bytes()
if (len(data) < 8192 or data[:12] != bytes.fromhex('fd0300ea') + b'optee\0\0\0'
        or data[28:44] != b'3.7\0\0\0\0\0CHKv1.0\0'
        or struct.unpack_from('<I', data, 44)[0] != 0x41b00000
        or data[244:252] != b'AW_PUBK!'
        or data[3072:3088] != b'BootInfo' + struct.pack('<II', 1, 0)):
    raise SystemExit('Source-generated Allwinner header does not match its ABI')
exponent, exponent_bytes, modulus, modulus_size = struct.unpack_from('<IIII', data, 252)
if (exponent_bytes != 4 or max(exponent + 4, modulus + 256, modulus_size + 4) > len(data)
        or struct.unpack_from('<I', data, exponent)[0] != 65537
        or struct.unpack_from('<I', data, modulus_size)[0] != 256):
    raise SystemExit('Source-generated public-key offsets or RSA inputs are invalid')
payload = (out / 'standby-build/standby.bin').read_bytes()
wrapper_start, wrapper_bytes = 0x4000, 0x4000
if data[wrapper_start:wrapper_start + len(payload)] != payload:
    raise SystemExit('Source-built standby payload was not linked at the observed aligned position')
report = {
    'artifact': str(candidate), 'size': len(data),
    'sha256': hashlib.sha256(data).hexdigest(),
    'source_build_complete': True,
    'stock_equivalence_established': False,
    'status': 'research-only; source standby embedded, service integration/layout/original inputs incomplete',
    'carrier': 'raw source-linked Allwinner image; standard tee.bin retained separately',
    'header': {'format': 'Allwinner 4092-byte header, reset code at offset 8192',
               'public_key_offsets': {'exponent': exponent, 'modulus': modulus,
                                      'modulus_size': modulus_size}},
    'standby': {'source_built': True, 'payload_bytes': len(payload),
                'payload_sha256': hashlib.sha256(payload).hexdigest(),
                'wrapper_offset': wrapper_start, 'wrapper_bytes': wrapper_bytes,
                'service_integration_complete': False, 'comparison': None},
    'comparison': None,
}
if sys.argv[2]:
    reference = Path(sys.argv[2])
    original = reference.read_bytes()
    original_sha = hashlib.sha256(original).hexdigest()
    if original_sha != '7ccd7a54ae2142f68d6bac60e3e2b36ccbfa2ec677aa6ce84342cc6f1b821c99':
        raise SystemExit('Unexpected original OP-TEE comparison reference SHA-256')
    differences = [i for i, (a, b) in enumerate(zip(original, data)) if a != b]
    equal = original == data
    report['comparison'] = {
        'reference': str(reference), 'reference_sha256': original_sha,
        'reference_size': len(original), 'full_file_equal': equal,
        'byte_differences_in_shared_extent': len(differences),
        'first_differing_offset': differences[0] if differences else
            min(len(original), len(data)) if len(original) != len(data) else None,
        'candidate_length_difference': len(data) - len(original),
        'permitted_exceptions': [],
    }
    report['stock_equivalence_established'] = equal
    wrapper = data[wrapper_start:wrapper_start + wrapper_bytes]
    stock_wrapper = original[wrapper_start:wrapper_start + wrapper_bytes]
    report['standby']['comparison'] = {
        'whole_wrapper_equal': wrapper == stock_wrapper,
        'byte_differences': sum(a != b for a, b in zip(wrapper, stock_wrapper)),
        'alignment_tail_equal': wrapper[len(payload):] == stock_wrapper[len(payload):],
        'permitted_exceptions': [],
    }

(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
if report['comparison'] is not None and not report['stock_equivalence_established']:
    raise SystemExit(1)
PY
