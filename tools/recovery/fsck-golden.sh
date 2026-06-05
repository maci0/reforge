#!/usr/bin/env bash
# =============================================================================
# fsck-golden.sh — make tools/recovery/golden.img.gz journal-clean.
#
# The current golden.img.gz was captured from a running device, so its ext
# partitions (p6 rootfs, p7 UDISK) are crash-inconsistent: pending journal,
# half-updated block/inode bitmaps. Any consumer that extracts a partition
# and tries to mount it under qemu hits "Unable to mount root fs" because
# the kernel refuses to play a journal replay before mount_root.
#
# Newer dump_golden.sh already does an inline fsck pass (slice → e2fsck -fy
# → splice back) at capture time so the .img.gz it produces is fsck-clean.
# This script is for retrofitting the SAME treatment to an already-captured
# golden.img.gz, then updating the canonical .sha256 alongside it.
#
# Pattern (rootless, no losetup):
#   1. gunzip golden.img.gz → scratch raw
#   2. for each ext partition (p6, p7):
#        a. dd-slice the partition out by byte offset (read sfdisk geometry)
#        b. e2fsck -fy (replay journal, fix bitmaps)
#        c. dd-splice the cleaned partition back at the same offset
#   3. gzip → golden.img.gz.new, atomic rename, regen .sha256, .size
#
# Disk cost: needs ~2 × 7.3 GiB of scratch space briefly.
#
# Usage:    tools/recovery/fsck-golden.sh
# Idempotent: running it again on an already-clean image is a no-op (e2fsck
# reports clean and the splice writes the same bytes back).
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GOLDEN_GZ="${REPO_ROOT}/tools/recovery/golden.img.gz"
SHA_FILE="${GOLDEN_GZ}.sha256"
SIZE_FILE="${REPO_ROOT}/tools/recovery/golden.size"

[ -f "${GOLDEN_GZ}" ] || { echo "FAIL: ${GOLDEN_GZ} missing" >&2; exit 1; }
for t in gunzip gzip sfdisk e2fsck dd sha256sum; do
    command -v "$t" >/dev/null || { echo "FAIL: $t not installed" >&2; exit 1; }
done

log() { echo "[fsck-golden] $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

RAW="${WORK}/golden-raw.img"

log "decompressing ${GOLDEN_GZ} -> ${RAW} (slow; ~7.3 GiB)"
t0=$(date +%s)
gunzip -c "${GOLDEN_GZ}" > "${RAW}"
log "  done in $(( $(date +%s) - t0 ))s; size: $(du -h "${RAW}" | cut -f1)"

# Read the geometry of every ext partition (p6 + p7) directly from the
# GPT via sfdisk. We use byte offsets so no losetup / sudo is needed.
log "reading GPT geometry ..."
sfdisk -d "${RAW}" 2>/dev/null | awk '/start=/' | sed 's/^[[:space:]]*//' > "${WORK}/parts.txt"
cat "${WORK}/parts.txt" | sed 's/^/  /'

# Loop and process each partition; only ext partitions are fsck'd
# (e2fsck on a non-ext partition exits with rc>=4, which we filter out).
clean_count=0
fixed_count=0
skipped_count=0
while read -r line; do
    # Expected sfdisk line: <DEV> : start=N, size=M, type=...
    start=$(echo "${line}" | sed -nE 's/.* start=[[:space:]]*([0-9]+).*/\1/p')
    size=$( echo "${line}" | sed -nE 's/.* size=[[:space:]]*([0-9]+).*/\1/p')
    [ -n "${start}" ] && [ -n "${size}" ] || continue

    PART_TMP="${WORK}/part-${start}.bin"
    dd if="${RAW}" of="${PART_TMP}" bs=512 skip="${start}" count="${size}" status=none

    # Sniff magic — only proceed if this looks like ext{2,3,4}.
    # ext superblock starts at byte 1024; magic 0xEF53 lives at offset 0x38.
    magic=$(dd if="${PART_TMP}" bs=1 skip=1080 count=2 status=none 2>/dev/null | xxd -p)
    if [ "${magic}" != "53ef" ]; then
        skipped_count=$(( skipped_count + 1 ))
        rm -f "${PART_TMP}"
        continue
    fi

    rc=0
    e2fsck -fy "${PART_TMP}" >"${WORK}/fsck.log" 2>&1 || rc=$?
    case "${rc}" in
        0)  log "  start=${start} size=${size}: already clean"
            clean_count=$(( clean_count + 1 ))
            ;;
        1|2)  fixed=$(grep -cE 'Fix|recovering|Inode|Clearing|Resize' "${WORK}/fsck.log" || true)
            log "  start=${start} size=${size}: e2fsck cleaned (rc=${rc}, ~${fixed} fixes)"
            fixed_count=$(( fixed_count + 1 ))
            ;;
        *)  log "  start=${start} size=${size}: e2fsck FAILED rc=${rc} — leaving original bytes"
            rm -f "${PART_TMP}"
            continue
            ;;
    esac

    # Splice back at the same offset. conv=notrunc preserves surrounding GPT
    # and other partitions; we don't conv=sparse here because we want every
    # cleaned byte written through.
    dd if="${PART_TMP}" of="${RAW}" bs=512 seek="${start}" count="${size}" \
       conv=notrunc status=none
    rm -f "${PART_TMP}"
done < "${WORK}/parts.txt"

log "summary: ${clean_count} already-clean, ${fixed_count} fixed, ${skipped_count} non-ext skipped"

if [ "${fixed_count}" -eq 0 ]; then
    log "all ext partitions were already clean; nothing to write"
    log "  (canonical ${GOLDEN_GZ} is unchanged)"
    exit 0
fi

# Recompress + atomic replace. Keep a one-shot backup so we can revert if a
# downstream consumer breaks; gitignore should already cover golden.img.gz.bak.
log "recompressing -> ${GOLDEN_GZ}.new"
t0=$(date +%s)
gzip -c "${RAW}" > "${GOLDEN_GZ}.new"
log "  done in $(( $(date +%s) - t0 ))s; size: $(du -h "${GOLDEN_GZ}.new" | cut -f1)"

cp -a "${GOLDEN_GZ}" "${GOLDEN_GZ}.bak"
mv "${GOLDEN_GZ}.new" "${GOLDEN_GZ}"
log "  saved previous as ${GOLDEN_GZ}.bak"

# Refresh the .sha256 + .size sidecars.
( cd "$(dirname "${GOLDEN_GZ}")" && sha256sum "$(basename "${GOLDEN_GZ}")" ) \
    > "${SHA_FILE}"
log "  ${SHA_FILE} updated"

if [ -f "${SIZE_FILE}" ]; then
    stat -c '%s' "${GOLDEN_GZ}" > "${SIZE_FILE}"
    log "  ${SIZE_FILE} updated"
fi

log "DONE. ${GOLDEN_GZ} is now journal-clean."
log "      sha256: $(cut -d' ' -f1 "${SHA_FILE}")"
