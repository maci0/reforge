#!/bin/bash
# inject.sh — robust offline file injection into an ext4 image via debugfs.
# debugfs `write` can silently truncate the tail; this writes + verifies the
# size and retries. Was copy-pasted into ~6 harnesses; now one copy.
#
#   robust_inject <ext4-img> <src-file> <dst-path-in-img>

robust_inject() {
    local img="$1" src="$2" dst="$3" want got
    want=$(wc -c < "${src}")
    for _ in 1 2 3 4 5; do
        debugfs -w -R "rm ${dst}" "${img}" >/dev/null 2>&1 || true
        debugfs -w -R "write ${src} ${dst}" "${img}" >/dev/null 2>&1 || true
        got=$(debugfs -R "stat ${dst}" "${img}" 2>/dev/null | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1)
        [ "${got}" = "${want}" ] && return 0
    done
    die "robust_inject: ${dst} truncated (want ${want}, got ${got:-0})"
}

# inject_chmod <ext4-img> <dst-path> <octal-mode>
inject_chmod() { debugfs -w -R "sif $2 mode 01${3}" "$1" >/dev/null 2>&1; }
