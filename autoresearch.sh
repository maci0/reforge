#!/usr/bin/env bash
# =============================================================================
# autoresearch.sh — benchmark wrapper for the toolchain/optimization memory loop.
#
# Started 2026-06-04.  Goal: drive sum(Pss) of the ReForge stack at -m 128 on the
# qemu virt platform DOWN, and MemAvailable UP, with no swap interference.
#
# Each invocation:
#   1. picks the variant from argv[1] (default: baseline)
#   2. runs tests/qemu-harness/mem-probe.sh against the rootfs.tar with NOSWAP=1
#      and any per-variant TWEAKS / ROOTFS overrides
#   3. parses the harness output for MemAvailable + sum(tracked Pss) + per-PID Pss
#   4. emits the result as JSON on stdout (for log_experiment) AND appends a row
#      to autoresearch.jsonl directly
#
# Variants (PHASE 1 = runtime tweaks, no rebuild; PHASE 2 = compile-time, rebuild):
#
# IMPORTANT: the production init scripts already preload jemalloc with tight tuning
# (narenas:1, dirty/muzzy_decay_ms:0).  So old-school "arena1" / "jemalloc" /
# "jemalloc-tight" tweaks are ALREADY THE BASELINE — not meaningful variants.
# The phase-1 set below explores levers ON TOP OF that already-optimized baseline.
#
# PHASE 1 — runtime levers (no rebuild, ~3 min/iter):
#   baseline             current rootfs.tar (gcc14.3, LTO, -Os, Thumb-2, jemalloc-tight)
#   oo                   TWEAKS=oo                 klippy + moonraker with python -OO
#   klippy-oo            TWEAKS=klippy-oo          only klippy with python -OO
#   no-jemalloc          TWEAKS=no-jemalloc        strip jemalloc LD_PRELOAD (regression
#                                                   check: how big a win was jemalloc?)
#   tcache-off           TWEAKS=jemalloc-conf + JEMALLOC_CONF=narenas:1,tcache:false,
#                                                   dirty_decay_ms:0,muzzy_decay_ms:0
#   moonraker-min        TWEAKS=moonraker-min      drop [history]/[announcements]/etc.
#   stack-best           best stacked combination of the above winners
#
# PHASE 2 — compile-time variants (full rebuild ~30–60 min/iter):
#   gcc15-base           BR2_GCC_VERSION_15_X=y
#   gcc15-funcsec        gcc15 + -ffunction-sections -fdata-sections -Wl,--gc-sections
#                                                   in BR2_TARGET_OPTIMIZATION
#   gcc15-pycomp         gcc15 + post-build compileall -OO + strip .py files
#   gcc15-best           gcc15 + winning phase-1 stack baked in
#
# Env:
#   ROOTFS_TAR      override the rootfs (used for build-variant iters)
#   MEM=128         RAM cap (matches AD5M Pro silicon)
#   SETTLE=25       seconds of post-stack settle before the snapshot
#   ITER=N          iteration id stamped into the JSONL row
#   LABEL=text      free-form label override for the JSONL row
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${REPO_ROOT}/tests/qemu-harness/mem-probe.sh"
JSONL="${REPO_ROOT}/autoresearch.jsonl"

VARIANT="${1:-baseline}"
ITER="${ITER:-X}"
LABEL="${LABEL:-${VARIANT}}"
ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar}"
MEM="${MEM:-128}"
SETTLE="${SETTLE:-25}"

# Per-variant TWEAKS / MALLOC_CONF wiring.  These are RUNTIME tweaks applied by
# mem-probe.sh in-place on the rootfs staging tree, so they need no rebuild.
TWEAKS=""
JEMALLOC_CONF=""
case "$VARIANT" in
    baseline)                ;;
    oo)                      TWEAKS="oo" ;;
    klippy-oo)               TWEAKS="klippy-oo" ;;
    no-jemalloc)             TWEAKS="no-jemalloc" ;;
    tcache-off)              TWEAKS="jemalloc-conf"
                             JEMALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0" ;;
    moonraker-min)           TWEAKS="moonraker-min" ;;
    stack-tcache-mrmin)      TWEAKS="jemalloc-conf,moonraker-min"
                             JEMALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0" ;;
    tcache-off-thp-never)    TWEAKS="jemalloc-conf"
                             JEMALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0,metadata_thp:never" ;;
    stack-best)              # caller sets TWEAKS / JEMALLOC_CONF via env
                             TWEAKS="${TWEAKS:-}"; JEMALLOC_CONF="${JEMALLOC_CONF:-}" ;;
    gcc15-*)                 # build variant — caller MUST set ROOTFS_TAR to the right tarball
                             [ "${ROOTFS_TAR}" = "${REPO_ROOT}/build/output/images/rootfs.tar" ] && {
                                 echo "[autoresearch] ERROR: ${VARIANT} needs ROOTFS_TAR=<path-to-variant-tar>" >&2
                                 exit 2
                             } ;;
    *)                       echo "[autoresearch] unknown variant: ${VARIANT}" >&2; exit 2 ;;
esac

[ -f "${ROOTFS_TAR}" ] || { echo "[autoresearch] missing rootfs: ${ROOTFS_TAR}" >&2; exit 2; }
[ -x "${PROBE}" ]      || { echo "[autoresearch] missing probe: ${PROBE}" >&2; exit 2; }

START_TS=$(date -Is)
START_EPOCH=$(date +%s)

# Run the probe.  All output goes to a per-iter log so we can attach it later.
LOG="${REPO_ROOT}/autoresearch-logs"
mkdir -p "${LOG}"
OUT="${LOG}/iter-${ITER}-${VARIANT}.log"

echo "[autoresearch] iter=${ITER} variant=${VARIANT} rootfs=$(basename "${ROOTFS_TAR}") tweaks='${TWEAKS}' jemalloc_conf='${JEMALLOC_CONF}'" >&2
NOSWAP=1 MEM="${MEM}" SETTLE="${SETTLE}" TWEAKS="${TWEAKS}" JEMALLOC_CONF="${JEMALLOC_CONF}" \
    "${PROBE}" "${ROOTFS_TAR}" "iter${ITER}-${VARIANT}" >"${OUT}" 2>&1 || {
        END_EPOCH=$(date +%s)
        echo "[autoresearch] probe FAILED — see ${OUT}" >&2
        printf '{"ts":"%s","iter":"%s","variant":"%s","label":"%s","status":"fail","duration_s":%d,"log":"%s"}\n' \
            "$START_TS" "$ITER" "$VARIANT" "$LABEL" "$((END_EPOCH-START_EPOCH))" "${OUT}" >> "$JSONL"
        exit 1
    }
END_EPOCH=$(date +%s)

# Parse the probe output.  Looking for:
#   MemAvailable:     xxxx kB
#   sum(tracked Pss)=xxxxx kB
#   per-PID  Pss=xxxx Rss=xxxx ... CMD=...
# Parse stage — disable `-e` because empty grep matches (e.g. no guppyscreen
# process) are EXPECTED, not failures.
set +e
extract_kb_with_label() { grep -m1 "^$1" "${OUT}" 2>/dev/null | awk '{print $2}'; }
mem_avail=$(extract_kb_with_label "MemAvailable")
mem_total=$(extract_kb_with_label "MemTotal")
mem_free=$(extract_kb_with_label "MemFree")
cached=$(extract_kb_with_label "Cached")
pss_sum=$(grep -m1 "sum(tracked Pss)=" "${OUT}" 2>/dev/null | sed -E 's/.*sum\(tracked Pss\)=([0-9]+).*/\1/')
# per-process Pss (kB) — we'll log each as a key in the json row
collect_proc() {
    local name="$1"
    grep -E "^PID [0-9]+ Pss=[0-9]+.*CMD=.*${name}" "${OUT}" 2>/dev/null | head -1 | \
        sed -E 's/.*Pss=([0-9]+).*/\1/'
}
pss_klippy=$(collect_proc 'klippy')
pss_moonraker=$(collect_proc 'moonraker')
pss_guppy=$(collect_proc 'guppyscreen')
pss_httpd=$(collect_proc 'httpd')
set -e

# Probe boot must have completed (i.e. the MEMPROBE-BEGIN sentinel landed). If not,
# something OOM-killed or hung before the snapshot — mark fail so iters that fail
# the no-swap-128MiB gate don't pollute the rankings.
# mem-probe.sh strips the MEMPROBE-BEGIN/END markers from its human-readable
# summary, so look for the SUMMARY line as the unambiguous success sentinel.
if ! grep -q '^SUMMARY  MemAvailable=' "${OUT}"; then
    status=fail
    pss_sum="${pss_sum:-0}"
    mem_avail="${mem_avail:-0}"
else
    status=ok
fi

printf '{"ts":"%s","iter":"%s","variant":"%s","label":"%s","status":"%s","duration_s":%d,"mem_total_kb":%s,"mem_avail_kb":%s,"mem_free_kb":%s,"cached_kb":%s,"pss_sum_kb":%s,"pss_klippy_kb":%s,"pss_moonraker_kb":%s,"pss_guppyscreen_kb":%s,"pss_httpd_kb":%s,"log":"%s"}\n' \
    "$START_TS" "$ITER" "$VARIANT" "$LABEL" "$status" "$((END_EPOCH-START_EPOCH))" \
    "${mem_total:-0}" "${mem_avail:-0}" "${mem_free:-0}" "${cached:-0}" \
    "${pss_sum:-0}" "${pss_klippy:-0}" "${pss_moonraker:-0}" "${pss_guppy:-0}" "${pss_httpd:-0}" \
    "${OUT}" | tee -a "${JSONL}"
