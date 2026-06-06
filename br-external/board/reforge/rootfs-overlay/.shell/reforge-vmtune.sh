#!/bin/sh
# reforge-vmtune.sh — apply the zram-as-primary-swap VM tuning (the runtime-settable
# "bucket a" sysctls). Sourced by S35zram right after swapon, so swap setup and swap
# tuning live together. Every value is documented per-knob, with the measured
# rationale, in docs/research/memory/2026-06-02-stock-kernel-runtime-tuning.md.
#
# None of these have a fixed RAM cost; they bias reclaim toward the cheap
# compressed-RAM swap and make kswapd reclaim ahead of demand (the audit measured a
# direct-reclaim/throttle storm on the 110 MB box). The measure-first knobs that DO
# cost reserved RAM (min_free_kbytes, extra_free_kbytes) are deliberately NOT set
# here — see the audit's §2.
#
# VM_SYS_ROOT overrides /proc/sys/vm for host unit tests; it is NEVER set in
# production, so production always writes the real knobs.

VM_SYS_ROOT="${VM_SYS_ROOT:-/proc/sys/vm}"

# vm_set <knob> <value> — best-effort write to a /proc/sys/vm knob. No-op if the
# knob is absent or unwritable (e.g. a kernel that lacks it); never fails the caller.
vm_set() {
    [ -w "${VM_SYS_ROOT}/$1" ] || return 0
    printf '%s\n' "$2" > "${VM_SYS_ROOT}/$1" 2>/dev/null || true
    return 0
}

# reforge_vmtune — apply the tuned values. ZRAM_SWAPPINESS (from zram.conf) overrides
# the swappiness target if set.
reforge_vmtune() {
    vm_set page-cluster           0                          # zram is RAM: no swap read-ahead
    vm_set swappiness             "${ZRAM_SWAPPINESS:-100}"  # prefer compressed-RAM swap over eMMC file re-reads
    vm_set vfs_cache_pressure     50                         # keep cheap in-RAM dentry/inode cache a bit longer
    vm_set watermark_scale_factor 40                         # wider kswapd band -> reclaim ahead of demand
    vm_set dirty_ratio            10                         # cap dirty pages (~11 MB) so eMMC writeback stays small
    vm_set dirty_background_ratio 5                          # start background writeback early; drain steadily
}
