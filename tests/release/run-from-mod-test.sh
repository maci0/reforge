#!/usr/bin/env bash
# tests/release/run-from-mod-test.sh
#
# Task 3 focused test: prove the run-from-mod model.
#
# The reforge-authored init lives in a self-contained /mod and is executed IN
# PLACE by /mod/start.sh (which runs /mod/init.d/S* in sorted order). There is
# NO /etc/init.d mirror. This test verifies that contract WITHOUT needing root
# or a real chroot:
#
#   1. Syntax-check reforge-boot, and the start.sh/stop.sh emitted by post-build.
#   2. Build a scratch "chroot root" with a sentinel /mod/init.d/S50test that
#      writes a marker, run start.sh against it, and assert:
#        - the sentinel ran (marker present)  => init ran from mod/
#        - start.sh symlinked /etc/reforge -> /mod/etc/reforge
#        - NO /etc/init.d mirror of the S-scripts was created
#   3. Assert reforge-boot's final exec targets /mod/start.sh (not /etc/init.d/rcS).
#   4. Assert stop.sh runs the chain in REVERSE order.
#
# No qemu, no sudo. Exit 0 = PASS, 1 = FAIL.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD_DIR="${REPO_ROOT}/br-external/board/reforge"
BOOT="${BOARD_DIR}/rootfs-overlay/.shell/reforge-boot"
POSTBUILD="${BOARD_DIR}/post-build.sh"

FAILS=0
pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILS=$((FAILS + 1)); }

# ---------------------------------------------------------------------------
# 1. Syntax checks
# ---------------------------------------------------------------------------
sh -n "${BOOT}"      && pass "reforge-boot: sh -n clean"      || fail "reforge-boot: sh -n"
sh -n "${POSTBUILD}" && pass "post-build.sh: sh -n clean"     || fail "post-build.sh: sh -n"

# ---------------------------------------------------------------------------
# 3. reforge-boot execs /mod/start.sh, not /etc/init.d/rcS
# ---------------------------------------------------------------------------
if grep -qE 'exec chroot .* /mod/start\.sh' "${BOOT}"; then
    pass "reforge-boot final exec runs /mod/start.sh"
else
    fail "reforge-boot does not exec /mod/start.sh"
fi
if grep -qE 'exec chroot .* /etc/init\.d/rcS' "${BOOT}"; then
    fail "reforge-boot still execs /etc/init.d/rcS (mirror path not removed)"
else
    pass "reforge-boot no longer execs /etc/init.d/rcS"
fi

# ---------------------------------------------------------------------------
# Assemble a scratch chroot root by running post-build against a fake TARGET_DIR
# pre-staged the way buildroot stages the overlay + packages.
# ---------------------------------------------------------------------------
SCRATCH="$(mktemp -d /tmp/reforge-runmod-XXXXXX)"
trap 'rm -rf "${SCRATCH}"' EXIT
TARGET="${SCRATCH}/target"
mkdir -p "${TARGET}/etc/init.d" "${TARGET}/etc/reforge" \
         "${TARGET}/opt/reforge/zram" "${TARGET}/usr/bin"

# Stage the real overlay init scripts + configs + modules as buildroot would.
cp -a "${BOARD_DIR}/rootfs-overlay/etc/init.d/." "${TARGET}/etc/init.d/"
cp -a "${BOARD_DIR}/rootfs-overlay/etc/reforge/." "${TARGET}/etc/reforge/"
cp -a "${BOARD_DIR}/rootfs-overlay/usr/bin/reforge-banner" "${TARGET}/usr/bin/"
# moonraker.conf is installed by moonraker.mk into /etc/reforge — stage a stub.
printf '[server]\nhost: 0.0.0.0\n' > "${TARGET}/etc/reforge/moonraker.conf"
for m in zram.ko zsmalloc.ko swapon_prio; do
    if [ -f "${REPO_ROOT}/modules/zram-bsp/dist/${m}" ]; then
        cp -a "${REPO_ROOT}/modules/zram-bsp/dist/${m}" "${TARGET}/opt/reforge/zram/${m}"
    else
        : > "${TARGET}/opt/reforge/zram/${m}"
    fi
done

sh "${POSTBUILD}" "${TARGET}" >/dev/null

# ---------------------------------------------------------------------------
# Structural assertions on the assembled mod/
# ---------------------------------------------------------------------------
MOD="${TARGET}/mod"
[ -d "${MOD}" ] && pass "post-build created mod/" || fail "mod/ not created"
[ -x "${MOD}/start.sh" ] && pass "mod/start.sh present+exec" || fail "mod/start.sh missing"
[ -x "${MOD}/stop.sh" ]  && pass "mod/stop.sh present+exec"  || fail "mod/stop.sh missing"
for s in S00cloudblock S35zram S60klipper S65moonraker S70httpd S75guppyscreen; do
    [ -x "${MOD}/init.d/${s}" ] || fail "mod/init.d/${s} missing"
done
[ -x "${MOD}/init.d/S60klipper" ] && pass "mod/init.d/S* relocated"
# No /etc/init.d mirror of the reforge S-scripts after post-build.
if ls "${TARGET}/etc/init.d/"S[0-9]* >/dev/null 2>&1; then
    fail "post-build left an /etc/init.d S-script mirror"
else
    pass "no /etc/init.d S-script mirror (run-in-place)"
fi
# Base rootfs is NOT inside mod/
[ -e "${MOD}/bin/busybox" ] && fail "base rootfs leaked into mod/" \
    || pass "mod/ holds no base rootfs (self-contained)"
# Configs + modules relocated into mod/
[ -f "${MOD}/etc/reforge/printer.cfg" ] && pass "configs in mod/" || fail "mod/etc/reforge/printer.cfg missing"
[ -f "${MOD}/modules/zram.ko" ] && pass "modules in mod/" || fail "mod/modules/zram.ko missing"
# release_info.json (4 keys) + version from packaging/VERSION
VER="$(cat "${REPO_ROOT}/packaging/VERSION")"
if grep -q "\"version\": \"${VER}\"" "${MOD}/release_info.json" \
   && grep -q '"project_owner": "maci0"' "${MOD}/release_info.json" \
   && grep -q '"project_name": "reforge"' "${MOD}/release_info.json" \
   && grep -q '"asset_name"' "${MOD}/release_info.json"; then
    pass "release_info.json has 4 keys + correct version (${VER})"
else
    fail "release_info.json malformed / wrong version"
fi
# LKG seed
[ -f "${TARGET}/lkg/release_info.json" ] && pass "lkg seeded (cp -a mod lkg)" || fail "lkg not seeded"

# S35zram must look for modules in /mod/modules now
grep -q 'MODULES_DIR=/mod/modules' "${MOD}/init.d/S35zram" \
    && pass "S35zram MODULES_DIR=/mod/modules" || fail "S35zram still points at /opt/reforge/zram"
# S60klipper / S65moonraker still reference /etc/reforge configs (resolved via symlink)
grep -q '/etc/reforge/printer.cfg' "${MOD}/init.d/S60klipper" \
    && pass "S60klipper reads /etc/reforge/printer.cfg" || fail "S60klipper config path changed"
grep -q '/etc/reforge/moonraker.conf' "${MOD}/init.d/S65moonraker" \
    && pass "S65moonraker reads /etc/reforge/moonraker.conf" || fail "S65moonraker config path changed"

# ---------------------------------------------------------------------------
# 2. Run start.sh against a sentinel-augmented mod tree in a fake chroot root.
#    We can't `chroot`, so emulate the in-chroot view: copy mod/ into a fresh
#    root whose / is the scratch dir, drop a sentinel S50test, and run start.sh
#    with cwd at that root and absolute /mod paths rewritten via a bind-style
#    copy. Simplest faithful emulation: build a tiny rootlet where /mod resolves.
# ---------------------------------------------------------------------------
FAKEROOT="${SCRATCH}/fakeroot"
mkdir -p "${FAKEROOT}/mod" "${FAKEROOT}/etc"
cp -a "${MOD}/." "${FAKEROOT}/mod/"
# Replace the real S-scripts with no-op stubs (they touch /sys, insmod, daemons)
# so the test focuses on the run-from-mod *chain*, plus one sentinel.
for s in "${FAKEROOT}"/mod/init.d/S*; do
    cat > "$s" <<'STUB'
#!/bin/sh
echo "ran $(basename "$0") $1"
exit 0
STUB
    chmod +x "$s"
done
cat > "${FAKEROOT}/mod/init.d/S50test" <<STUB
#!/bin/sh
[ "\$1" = start ] && echo started > "${FAKEROOT}/marker"
echo "ran S50test \$1"
exit 0
STUB
chmod +x "${FAKEROOT}/mod/init.d/S50test"

# Run start.sh with absolute /mod and /etc rewritten to the fakeroot. start.sh
# hardcodes MOD=/mod and /etc/reforge; rewrite those to fakeroot-relative paths
# in a throwaway copy so we exercise the REAL logic without being root.
sed -e "s#^MOD=/mod#MOD=${FAKEROOT}/mod#" \
    -e "s#/etc/reforge#${FAKEROOT}/etc/reforge#g" \
    "${FAKEROOT}/mod/start.sh" > "${SCRATCH}/start-test.sh"
# stub services dir already copied. Run it (GUPPY off => S75 skipped, fine).
sh "${SCRATCH}/start-test.sh" > "${SCRATCH}/start.out" 2>&1 || true

if [ -f "${FAKEROOT}/marker" ]; then
    pass "start.sh ran the sentinel S50test (init ran from mod/)"
else
    fail "sentinel S50test did NOT run via start.sh"; cat "${SCRATCH}/start.out"
fi
# /etc/reforge symlink created by start.sh
if [ -L "${FAKEROOT}/etc/reforge" ]; then
    pass "start.sh created /etc/reforge -> /mod/etc/reforge symlink"
else
    fail "start.sh did not create /etc/reforge symlink"
fi
# No /etc/init.d mirror created at runtime
if [ -e "${FAKEROOT}/etc/init.d" ]; then
    fail "start.sh created an /etc/init.d mirror"
else
    pass "start.sh created NO /etc/init.d mirror"
fi
# Ordering: S00 before S60 before S70 in the run log
if awk '/ran S00cloudblock start/{a=NR} /ran S60klipper start/{b=NR} /ran S70httpd start/{c=NR} END{exit !(a<b && b<c)}' "${SCRATCH}/start.out"; then
    pass "start.sh ran S-scripts in sorted order"
else
    fail "start.sh did not run S-scripts in sorted order"; cat "${SCRATCH}/start.out"
fi

# stop.sh reverse order: S70 before S60 before S00
sed -e "s#^MOD=/mod#MOD=${FAKEROOT}/mod#" \
    "${FAKEROOT}/mod/stop.sh" > "${SCRATCH}/stop-test.sh"
sh "${SCRATCH}/stop-test.sh" > "${SCRATCH}/stop.out" 2>&1 || true
if awk '/ran S70httpd stop/{c=NR} /ran S60klipper stop/{b=NR} /ran S00cloudblock stop/{a=NR} END{exit !(c<b && b<a)}' "${SCRATCH}/stop.out"; then
    pass "stop.sh ran S-scripts in REVERSE order"
else
    fail "stop.sh did not run in reverse order"; cat "${SCRATCH}/stop.out"
fi

# ---------------------------------------------------------------------------
# Trial / LKG cycle (Task 4): with a mod whose version differs from the seeded
# lkg, a trial boot increments the counter; after a simulated S99ok promote the
# counter resets and the boot is no longer a trial.  Exercises reforge-lkg.sh in
# the run-from-mod tree assembled above.  (Full brick/restore is the Task 6 qemu
# test; here we only confirm the counter wiring end-to-end.)
# ---------------------------------------------------------------------------
LKG_SH="${MOD}/.shell/reforge-lkg.sh"
[ -f "${LKG_SH}" ] && pass "mod/.shell/reforge-lkg.sh present (non-stub)" \
    || fail "mod/.shell/reforge-lkg.sh missing"
if grep -q 'STUB' "${LKG_SH}"; then
    fail "reforge-lkg.sh is still the stub"
else
    pass "reforge-lkg.sh is the real trial/LKG implementation"
fi
[ -x "${MOD}/init.d/S99ok" ] && pass "mod/init.d/S99ok present (sentinel)" \
    || fail "mod/init.d/S99ok missing"

# Build a scratch DATA root with mod(2.0.0) + lkg(1.0.0) to drive the helpers.
TRIAL_DATA="${SCRATCH}/trialdata"
mkdir -p "${TRIAL_DATA}/.mod/.reforge/mod" "${TRIAL_DATA}/.mod/.reforge/lkg"
printf '{\n  "version": "2.0.0"\n}\n' > "${TRIAL_DATA}/.mod/.reforge/mod/release_info.json"
printf '{\n  "version": "1.0.0"\n}\n' > "${TRIAL_DATA}/.mod/.reforge/lkg/release_info.json"

run_trial() { REFORGE_DATA_ROOT="${TRIAL_DATA}" sh -c ". '${LKG_SH}'; $1"; }

# Trial detected + counter increments (mirrors reforge-boot's pre-exec step).
run_trial 'is_trial && lkg_counter_inc'
T1="$(run_trial 'lkg_counter_get')"
[ "${T1}" = "1" ] && pass "trial boot incremented counter (mod!=lkg)" \
    || fail "trial counter = '${T1}' (expected 1)"

# Simulated S99ok promote: versions equalize, counter resets, no longer a trial.
run_trial 'lkg_promote'
T2="$(run_trial 'lkg_counter_get')"
[ "${T2}" = "0" ] && pass "S99ok promote reset trial counter" \
    || fail "post-promote counter = '${T2}' (expected 0)"
if run_trial 'is_trial'; then
    fail "still a trial after promote"
else
    pass "no longer a trial after promote (mod==lkg)"
fi

echo ""
if [ "${FAILS}" -eq 0 ]; then
    echo "PASS: run-from-mod model verified"
    exit 0
else
    echo "FAIL: ${FAILS} assertion(s) failed"
    exit 1
fi
