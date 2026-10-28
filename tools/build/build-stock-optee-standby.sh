#!/usr/bin/env bash
# Source-only SRAM reconstruction. Optional reference is read only after linking.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo "usage: $0 OUTPUT_DIR [REFERENCE_BIN]" >&2; exit 2; }
OUT=$(realpath -m "$1")
[ ! -e "$OUT" ] || { echo "OUTPUT_DIR must be a fresh path" >&2; exit 2; }
case "$OUT/" in "$ROOT/vendor/optee/standby-src/"*) echo "OUTPUT_DIR must be outside the source tree" >&2; exit 2;; esac
REFERENCE=${2:-}
if [ -n "$REFERENCE" ]; then REFERENCE=$(realpath "$REFERENCE"); fi
CROSS=${CROSS_COMPILE:-"$ROOT/vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-"}
mkdir -p "$OUT/source" "$OUT/objects"
cp -a "$ROOT/vendor/optee/standby-src/." "$OUT/source/"
cd "$OUT/objects"
FLAGS=(-O2 -marm -march=armv7-a -mtune=cortex-a9 -ffreestanding -fno-builtin
       -fno-unwind-tables -ffunction-sections -fno-section-anchors)
OBJECTS=()
for name in parameters dram-state memory clock-data pmic-setup pmic pmic-data twi; do
    "${CROSS}gcc" -c "${FLAGS[@]}" "../source/$name.c" -o "$name.o"
    OBJECTS+=("$name.o")
done
for name in entry dram clock delay power pmic-group descriptor regulator twi-transfer stack spin; do
    "${CROSS}gcc" -c -marm -march=armv7-a "../source/$name.S" -o "$name.o"
    OBJECTS+=("$name.o")
done
cp ../source/runtime/lib1funcs.S lib1funcs.S
patch --batch --fuzz=0 -p1 -i ../source/runtime/standby-div0.patch >/dev/null
"${CROSS}gcc" -c -marm -march=armv7-a -D__ASSEMBLY__ -D__UBOOT__ -D__LINUX_ARM_ARCH__=7 \
    -I../source/runtime/abi lib1funcs.S -o runtime.o
OBJECTS+=(runtime.o)
"${CROSS}ld" -T ../source/standby.lds "${OBJECTS[@]}" -o ../standby.elf
[ -z "$("${CROSS}nm" -u ../standby.elf)" ] || { echo 'Unresolved standby symbols' >&2; exit 1; }
"${CROSS}objcopy" -O binary -j .parameters -j .text -j .data ../standby.elf ../standby.bin
python3 - "$OUT" "$REFERENCE" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
out = Path(sys.argv[1])
built = (out / 'standby.bin').read_bytes()
report = {'size': len(built), 'sha256': hashlib.sha256(built).hexdigest()}
if sys.argv[2]:
    reference = Path(sys.argv[2]).read_bytes()
    differences = [i for i, pair in enumerate(zip(built, reference)) if pair[0] != pair[1]]
    report.update(reference_sha256=hashlib.sha256(reference).hexdigest(),
                  size_delta=len(built) - len(reference),
                  differing_positions_in_shared_extent=len(differences), identical=built == reference,
                  first_differences=[{'offset': i, 'built': built[i], 'reference': reference[i]}
                                     for i in differences[:64]])
(out / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
if sys.argv[2] and not report['identical']:
    sys.exit(1)
PY
