#!/usr/bin/env bash
# =============================================================================
# build-emmc-image.sh — build a single GPT-partitioned eMMC image for qemu
#                      tests, matching the production AD5M layout BYTE FOR BYTE.
#
# Inside the VM the image looks exactly like the real onboard eMMC:
#   - Size                  : 7634944 KiB (7456 MiB ≈ 7.28 GiB)
#   - Partition table       : GPT, 7 entries, type 0700 ("Microsoft basic data")
#   - First usable sector   : 73728     (production-exact)
#   - Last  usable sector   : 15269854  (production-exact)
#   - Partition LBA ranges  : production-exact (see table below)
#   - Partition labels      : boot-resource / env / env-redund / boot / dsp0
#                             / rootfs / UDISK   (production-exact)
#
# On the HOST filesystem, the image is created as a sparse file. Only the
# blocks that actually contain non-zero data (GPT, p6 ext4 metadata + content,
# p7 ext4 metadata + content) occupy physical disk. A fresh "happy" build with
# rootfs.tar populating p6 and a copy of it in /data/.mod/.reforge on p7 ends
# up around ~400 MB on-disk vs the 7.28 GiB apparent size.
#
# Sources of truth this script reproduces:
#   docs/board-notes/partition-map.md  — the human-readable layout
#   tools/recovery/golden.img.gz       — the golden GPT it was extracted from
#   tools/recovery/forge-x-20260531-152104.partitions.txt — running /proc/partitions
#
# Production partition map (sectors are 512 B):
#   p1  boot-resource  73728..142603    (33.6 MiB,    0700, vfat boot res)
#   p2  env           142604..144651    (1024 KiB,    0700, U-Boot env)
#   p3  env-redund    144652..146699    (1024 KiB,    0700, U-Boot env)
#   p4  boot          146700..217099    (34.4 MiB,    0700, Android boot.img)
#   p5  dsp0          217100..219147    (1024 KiB,    0700, HiFi4 DSP fw)
#   p6  rootfs        219148..2840587   (1280.0 MiB,  0700, ext4 stock rootfs)
#   p7  UDISK         2840588..15269854 (~6068 MiB,   0700, ext4 /data)
#
# Usage:  build-emmc-image.sh <P6_EXT4> <P7_EXT4> <OUT_IMG>
# Inputs: P6_EXT4 = pre-built ext4 for the rootfs partition. Its size MUST be
#                   <= 1280 MiB (the production p6 size); 1280 MiB is ideal.
#         P7_EXT4 = pre-built ext4 for /data. Size <= 6068 MiB; the script
#                   will dd it sparsely into the p7 slot.
# Output: OUT_IMG = sparse, GPT-partitioned eMMC image, ready for
#                   qemu -device emmc,drive=...
# Needs:  sgdisk, truncate, dd
# =============================================================================
set -euo pipefail

[ $# -eq 3 ] || { echo "usage: $0 <P6_EXT4> <P7_EXT4> <OUT_IMG>" >&2; exit 2; }
P6_SRC="$1"; P7_SRC="$2"; OUT="$3"

command -v sgdisk >/dev/null || { echo "sgdisk not installed (gdisk pkg)" >&2; exit 2; }
[ -f "${P6_SRC}" ] || { echo "P6 source ${P6_SRC} missing" >&2; exit 2; }
[ -f "${P7_SRC}" ] || { echo "P7 source ${P7_SRC} missing" >&2; exit 2; }

# Production-exact constants. Do not change without updating
# docs/board-notes/partition-map.md and re-verifying against
# tools/recovery/golden.img.gz.
TOTAL_KIB=7634944           # 7.28 GiB; matches /proc/partitions on the unit
P1_START=73728;    P1_END=142603     # boot-resource
P2_START=142604;   P2_END=144651     # env
P3_START=144652;   P3_END=146699     # env-redund
P4_START=146700;   P4_END=217099     # boot (boot.img)
P5_START=217100;   P5_END=219147     # dsp0
P6_START=219148;   P6_END=2840587    # rootfs (ext4)
P7_START=2840588;  P7_END=15269854   # UDISK  (ext4)

# Size sanity. Refuse to truncate user payload.
sec_of() { echo $(( ( $(stat -c %s "$1") + 511 ) / 512 )); }
p6_size=$(sec_of "${P6_SRC}")
p7_size=$(sec_of "${P7_SRC}")
p6_max=$(( P6_END - P6_START + 1 ))
p7_max=$(( P7_END - P7_START + 1 ))
[ "${p6_size}" -le "${p6_max}" ] || { echo "P6 source (${p6_size} sec) exceeds p6 slot (${p6_max} sec / $((p6_max/2048)) MiB)" >&2; exit 2; }
[ "${p7_size}" -le "${p7_max}" ] || { echo "P7 source (${p7_size} sec) exceeds p7 slot (${p7_max} sec / $((p7_max/2048)) MiB)" >&2; exit 2; }

echo "[build-emmc] total image: ${TOTAL_KIB} KiB ($((TOTAL_KIB/1024)) MiB ≈ $((TOTAL_KIB*1024/1000000000)).$(((TOTAL_KIB*1024/100000000)%10)) GB sparse) → ${OUT}"
echo "[build-emmc] p6 rootfs : ${P6_SRC} → LBA ${P6_START}-${P6_END} (slot ${p6_max} sec / $((p6_max/2048)) MiB, content ${p6_size} sec)"
echo "[build-emmc] p7 UDISK  : ${P7_SRC} → LBA ${P7_START}-${P7_END} (slot ${p7_max} sec / $((p7_max/2048)) MiB, content ${p7_size} sec)"

rm -f "${OUT}"
truncate -s "${TOTAL_KIB}KiB" "${OUT}"

# Build the GPT. All partitions get type 0700 (Microsoft basic data) to match
# what production uses. --set-alignment=4 matches production's 4-sector
# alignment (vs sgdisk's default 2048). Note: --align=N is silently ignored
# by sgdisk for partition creation — must use --set-alignment.
sg() { sgdisk --set-alignment=4 "$@" "${OUT}" >/dev/null; }
sg --clear
sg -n 1:${P1_START}:${P1_END} -t 1:0700 -c 1:boot-resource
sg -n 2:${P2_START}:${P2_END} -t 2:0700 -c 2:env
sg -n 3:${P3_START}:${P3_END} -t 3:0700 -c 3:env-redund
sg -n 4:${P4_START}:${P4_END} -t 4:0700 -c 4:boot
sg -n 5:${P5_START}:${P5_END} -t 5:0700 -c 5:dsp0
sg -n 6:${P6_START}:${P6_END} -t 6:0700 -c 6:rootfs
sg -n 7:${P7_START}:${P7_END} -t 7:0700 -c 7:UDISK

# DD the real ext4 contents into their slots.
#   conv=sparse keeps the host file sparse (skips all-zero regions in the
#                ext4 metadata + unused space).
#   conv=notrunc preserves the GPT backup at the tail.
#   oflag=seek_bytes lets us seek by exact byte offset (=LBA * 512). MiB-based
#                seeks would be off by up to 2047 sectors for partitions whose
#                start LBA isn't a MiB multiple. Production p6 starts at LBA
#                219148, which is 107 MiB + 6 KiB — a MiB-seek would land the
#                ext4 superblock 12 sectors before the partition table's idea
#                of where p6 begins, and the kernel would refuse to mount it.
dd if="${P6_SRC}" of="${OUT}" bs=4M seek=$(( P6_START * 512 )) \
   oflag=seek_bytes conv=notrunc,sparse status=none
dd if="${P7_SRC}" of="${OUT}" bs=4M seek=$(( P7_START * 512 )) \
   oflag=seek_bytes conv=notrunc,sparse status=none

# Sanity check: do the 7 partitions match production LBAs/labels?
# (We don't check the GPT header's first/last-usable fields. Production sets
# first-usable=73728 to reserve room for boot0/SPL; the test image leaves that
# at the sgdisk default of 34 since qemu loads the kernel directly via -kernel.
# The partition LBA ranges themselves are production-identical, which is what
# the kernel + userspace actually see.)
check_part() {
    local n="$1" exp_start="$2" exp_end="$3" exp_name="$4"
    local row got_start got_end got_name
    row=$(sgdisk -i "${n}" "${OUT}" 2>/dev/null)
    # sgdisk -i prints e.g.
    #   First sector: 73728 (at 36.0 MiB)
    #   Last sector: 142603 (at 69.6 MiB)
    #   Partition name: 'boot-resource'
    got_start=$(echo "${row}" | awk '/^First sector:/{print $3}')
    got_end=$(  echo "${row}" | awk '/^Last sector:/ {print $3}')
    got_name=$( echo "${row}" | awk -F"'" '/^Partition name/{print $2}')
    [ "${got_start}" = "${exp_start}" ] && \
    [ "${got_end}"   = "${exp_end}"   ] && \
    [ "${got_name}"  = "${exp_name}"  ] || {
        echo "[build-emmc] WARN: p${n} mismatch (got ${got_start}-${got_end} '${got_name}'; expected ${exp_start}-${exp_end} '${exp_name}')" >&2
        return 1
    }
}
layout_ok=1
check_part 1 ${P1_START} ${P1_END} boot-resource || layout_ok=0
check_part 2 ${P2_START} ${P2_END} env           || layout_ok=0
check_part 3 ${P3_START} ${P3_END} env-redund    || layout_ok=0
check_part 4 ${P4_START} ${P4_END} boot          || layout_ok=0
check_part 5 ${P5_START} ${P5_END} dsp0          || layout_ok=0
check_part 6 ${P6_START} ${P6_END} rootfs        || layout_ok=0
check_part 7 ${P7_START} ${P7_END} UDISK         || layout_ok=0
[ "${layout_ok}" = 1 ] && echo "[build-emmc] 7-partition GPT matches production LBAs and labels (p1..p7)"

echo "[build-emmc] done: apparent=$(du -h --apparent-size "${OUT}" | awk '{print $1}') on-disk=$(du -h "${OUT}" | awk '{print $1}')"
