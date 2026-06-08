#!/bin/bash
# golden.sh — slice the stock rootfs (p6) out of the golden eMMC dump, the way
# stockui-render / stockui-realklippy each open-coded it. Cached: the 7.3 GB
# decompress + slice happens once.
#
#   golden_p6_ext4 <out_ext4>   # cached clean stock rootfs ext4 (returns 1 if no golden)

GOLDEN="${GOLDEN:-${REPO_ROOT}/tools/recovery/golden.img.gz}"

golden_p6_ext4() {
    local out="$1"
    local clean="${BUILD_DIR}/stock-clean-rootfs.ext4" raw="${BUILD_DIR}/golden-raw.img"
    if [ ! -f "${clean}" ]; then
        [ -f "${GOLDEN}" ] || return 1
        if [ ! -f "${raw}" ] || [ "$(stat -c%s "${raw}" 2>/dev/null || echo 0)" != 7818182656 ]; then
            log "decompressing golden -> raw (~7.3 GB, once) ..."
            gzip -dc "${GOLDEN}" > "${raw}"
        fi
        local s z
        read -r s z < <(sfdisk -d "${raw}" 2>/dev/null \
            | awk -F'[ ,]+' '/img6 *:/{for(i=1;i<=NF;i++){if($i=="start=")a=$(i+1);if($i=="size=")b=$(i+1)} print a,b}')
        [ -n "${s:-}" ] && [ -n "${z:-}" ] || return 1
        log "slicing stock p6 -> ${clean}"
        dd if="${raw}" of="${clean}" bs=512 skip="${s}" count="${z}" status=none
    fi
    cp -f "${clean}" "${out}"
    e2fsck -fy "${out}" >/dev/null 2>&1 || true
    tune2fs -e continue "${out}" >/dev/null 2>&1
}
