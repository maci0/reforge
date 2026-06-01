#!/bin/sh
# reforge-lkg.sh — boot trial / last-known-good (LKG) helpers.
#
# POSIX sh / BusyBox compatible.  Source-able with NO side effects: defining the
# helpers must not create directories, write files, or read state.  Callers
# invoke the functions explicitly.
#
# ----------------------------------------------------------------------------
# DUAL-CONTEXT PATHS  (read before changing the paths below)
# ----------------------------------------------------------------------------
# This file is sourced from TWO different filesystem roots and must resolve the
# SAME on-disk directories in both:
#
#   1. reforge-boot — runs on the STOCK side, OUTSIDE the chroot.  There the
#      ReForge tree is at /data/.reforge/{mod,lkg,state}.
#
#   2. S99ok — runs INSIDE the chroot whose root IS /data/.reforge.  reforge-boot
#      bind-mounts the printer's /data into the chroot at <chroot>/data, so the
#      same files are reachable inside the chroot both as /mod (chroot-internal)
#      AND as /data/.reforge/mod (via that bind-mount).
#
# Therefore the absolute path /data/.reforge/{mod,lkg,state} names the exact same
# inodes in BOTH contexts, and the counter written by reforge-boot is read back
# by S99ok and vice-versa.  We default DATA=/data and build every path from
# /data/.reforge/... so the resolution is identical on both sides.
#
# REFORGE_DATA_ROOT overrides DATA for host unit tests (scratch dir, no chroot);
# it is NEVER set in production, so production always uses /data/.reforge/...
# ----------------------------------------------------------------------------

DATA="${REFORGE_DATA_ROOT:-/data}"
STATE="${DATA}/.reforge/state"
CNT="${STATE}/trial.count"
LKG="${DATA}/.reforge/lkg"
MOD="${DATA}/.reforge/mod"
N=3

# Atomic write: stage to a temp file in the SAME dir, then rename over the
# target.  rename(2) is atomic, so a power-cut never leaves a half-written
# counter — readers see either the old value or the new one, never garbage.
_atomic_write() {
    _aw_tmp="$1.tmp.$$"
    printf '%s' "$2" > "$_aw_tmp" && mv "$_aw_tmp" "$1"
}

lkg_counter_get() {
    [ -f "$CNT" ] && cat "$CNT" 2>/dev/null || echo 0
}

lkg_counter_inc() {
    mkdir -p "$STATE"
    _atomic_write "$CNT" "$(( $(lkg_counter_get) + 1 ))"
}

lkg_counter_reset() {
    mkdir -p "$STATE"
    _atomic_write "$CNT" 0
}

# Read the "version" value from <dir>/release_info.json (no JSON parser on the
# device — grep/sed the one line).  Empty string if the file/key is absent.
mod_version() {
    grep -o '"version"[^,]*' "$1/release_info.json" 2>/dev/null \
        | sed 's/.*: *"//;s/"//'
}

# Is the current boot a TRIAL of a freshly-updated mod?
#   - A MISSING lkg means a fresh device / first boot (no baseline to compare
#     against) => NOT a trial.  This guard MUST come first so a fresh boot never
#     phantom-trials and starts incrementing the counter against nothing.
#   - Otherwise: a trial iff mod's version differs from lkg's version.
is_trial() {
    [ -d "$LKG" ] || return 1
    [ "$(mod_version "$MOD")" != "$(mod_version "$LKG")" ]
}

# Promote the current mod to last-known-good (reached services-up).  Build the
# new lkg out of place (lkg.new), then swap it in, so an interrupted promote
# never leaves a partial lkg.  Reset the trial counter.
lkg_promote() {
    rm -rf "$LKG.new"
    cp -a "$MOD" "$LKG.new" && rm -rf "$LKG" && mv "$LKG.new" "$LKG"
    lkg_counter_reset
}

# Restore the last-known-good mod (the trial failed N times).  Keep the bad mod
# aside as mod.bad for post-mortem, then copy lkg back into place.  Reset the
# counter so the restored-good boot starts clean.
lkg_restore() {
    rm -rf "$MOD.bad"
    mv "$MOD" "$MOD.bad" 2>/dev/null
    cp -a "$LKG" "$MOD"
    lkg_counter_reset
}
