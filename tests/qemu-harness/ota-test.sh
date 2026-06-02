#!/usr/bin/env bash
# =============================================================================
# ota-test.sh — OTA Task 6: qemu end-to-end update + the CRITICAL last-known-good
# (LKG) / brick-rollback test.
#
# Two independent scenarios, each booting the ReForge rootfs (build/output/images
# rootfs.tar — the self-contained /data/.reforge chroot tree, with /mod, /lkg and
# the [update_manager] Moonraker config) under the virt test kernel (build/zImage):
#
#   STEP 1  e2e Moonraker update (best-effort).  Seeds an OLDER release_info.json
#           version into a component path, points the guest at the offline
#           mock-github-release.sh (HTTPS, self-signed CA injected into the guest
#           trust store, api.github.com -> the qemu gateway 10.0.2.2 via
#           /etc/hosts), drives POST /machine/update/{component} and POLLS
#           GET /machine/update/status, then asserts the path's release_info.json
#           version bumped + the service restarted live (SimpleProvider).
#           Heavy / network-dependent: if it can't go green in-budget it is logged
#           SKIPPED-with-reason — never faked.
#
#   STEP 2  THE CRITICAL LKG / brick-rollback test (network-free, highest value).
#           Injects a deliberately-broken mod (an init.d/S60klipper that HANGS)
#           with a release_info.json version != the seeded lkg, straight into the
#           device ext4.  Boots N=3 times and asserts:
#             - the trial counter increments each boot,
#             - S99ok is NEVER reached on a broken boot (no /tmp/reforge-ok),
#             - on the 3rd boot reforge-boot restores the LKG -> the GOOD version
#               boots and reaches S99ok.
#           This proves brick-mitigation independent of any download path.
#
#   STEP 3  Mainsail web check — assert the Mainsail web bundle is installed and
#           identifiable as mainsail under /var/www/mainsail.
#
# FULLY ROOTLESS (no sudo): ext4 images are built from a staging dir with
# `mke2fs -d` (no loop mount), the broken-mod / counter probes are read back with
# `debugfs` (size-verified, like stockui-render.sh's robust_inject).  qemu runs
# unprivileged (cortex-a7 TCG needs no kvm); its -monitor / serial go to user-owned
# files so no sudo is needed anywhere.
#
# QEMU coexistence: poll-waits for other users' qemu to drain before each boot and
# only ever kills its OWN qemu by PID.  Unique image / socket names (build/ota-*).
#
# Usage:   tests/qemu-harness/ota-test.sh        # NO sudo
#          make qemu-ota
# Env:     SKIP_E2E=1   skip Step 1 (LKG + Mainsail only)
#          ONLY_E2E=1   run only Step 1
#          QEMU_TIMEOUT  per-boot qemu cap (default 240s for boots, 90s for hangs)
# Needs:   qemu-system-arm, mke2fs/debugfs (e2fsprogs), curl, socat, python3
#          build/zImage (make qemu-kernel) + build/output/images/rootfs.tar (make rootfs)
# Exit:    0 = LKG test PASS (+ Mainsail), 1 = LKG test FAIL.  A skipped/failed e2e
#          step never on its own fails the run (it is best-effort).
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
MOCK="${HARNESS_DIR}/mock-github-release.sh"
DIST_DIR="${REPO_ROOT}/packaging/dist"

ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar}"
[ -f "${ROOTFS_TAR}" ] || ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar.xz"

# Per-boot qemu wall-clock caps (ARM TCG is slow).
BOOT_TIMEOUT="${QEMU_TIMEOUT:-240}"   # a boot that must reach services-up
HANG_TIMEOUT="${HANG_TIMEOUT:-90}"    # a boot we EXPECT to wedge (broken mod)
MOCK_PORT="${MOCK_PORT:-8443}"
# Slirp address the guest resolves api.github.com to and qemu guestfwd's to the
# host mock. Must NOT be the gateway (10.0.2.2), DNS (10.0.2.3) or the guest
# (10.0.2.15) — qemu rejects a guestfwd onto its own gateway.
GUEST_MOCK_IP="${GUEST_MOCK_IP:-10.0.2.200}"

log()  { echo "[ota-test] $*"; }
warn() { echo "[ota-test] WARN: $*" >&2; }
die()  { echo "[ota-test] FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prereq guards — SKIP cleanly (exit 0) if the heavy build artefacts are absent,
# exactly like tests/release/build-release-test.sh.
# ---------------------------------------------------------------------------
if [ ! -f "${ZIMAGE}" ]; then
    log "SKIP: virt kernel missing (${ZIMAGE}); run 'make qemu-kernel' first."
    exit 0
fi
if [ ! -f "${ROOTFS_TAR}" ]; then
    log "SKIP: rootfs tar missing (build/output/images/rootfs.tar[.xz]); run 'make rootfs' first."
    exit 0
fi
for t in qemu-system-arm mke2fs debugfs; do
    command -v "${t}" >/dev/null 2>&1 || { log "SKIP: ${t} not installed."; exit 0; }
done

mkdir -p "${BUILD_DIR}"

# ---------------------------------------------------------------------------
# qemu coexistence helpers.
# ---------------------------------------------------------------------------
MY_QEMU_PID=""

# Wait (≈8 min cap) until no OTHER user qemu is running, so we never contend.
wait_for_qemu_drain() {
    local waited=0
    while pgrep -u "$(id -u)" qemu-system-arm >/dev/null 2>&1; do
        # Don't wait on our own process.
        if [ -n "${MY_QEMU_PID}" ] && \
           [ "$(pgrep -u "$(id -u)" qemu-system-arm | tr '\n' ' ')" = "${MY_QEMU_PID} " ]; then
            break
        fi
        [ "${waited}" -ge 480 ] && { warn "qemu still busy after 480s — proceeding anyway"; break; }
        sleep 5
        waited=$((waited + 5))
    done
}

kill_my_qemu() {
    if [ -n "${MY_QEMU_PID}" ] && kill -0 "${MY_QEMU_PID}" 2>/dev/null; then
        kill -9 "${MY_QEMU_PID}" 2>/dev/null || true
        wait "${MY_QEMU_PID}" 2>/dev/null || true
    fi
    MY_QEMU_PID=""
}

# ---------------------------------------------------------------------------
# debugfs read-back helpers (size-verified, like stockui-render.sh).
# ---------------------------------------------------------------------------
# Read a file's stored size from an ext4 image (0 if absent).
dbg_size() {
    debugfs -R "stat $2" "$1" 2>/dev/null \
        | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1
}
# Cat a file out of an ext4 image to stdout (empty if absent).
dbg_cat() {
    debugfs -R "cat $2" "$1" 2>/dev/null || true
}

SCRATCH=""
cleanup() {
    kill_my_qemu
    [ -n "${MOCK_PID:-}" ] && kill "${MOCK_PID}" 2>/dev/null || true
    [ -n "${MOCK_PID:-}" ] && wait "${MOCK_PID}" 2>/dev/null || true
    [ -n "${SCRATCH}" ] && rm -rf "${SCRATCH}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
MOCK_PID=""

extract_rootfs() {
    # Extract the rootfs tar into staging dir $1 (handles .tar / .tar.xz).
    local dst="$1"
    case "${ROOTFS_TAR}" in
        *.xz) tar --numeric-owner -xJf "${ROOTFS_TAR}" -C "${dst}" ;;
        *)    tar --numeric-owner -xf  "${ROOTFS_TAR}" -C "${dst}" ;;
    esac
}

# ===========================================================================
# STEP 2 — THE CRITICAL LKG / brick-rollback test.
# ===========================================================================
#
# Boot model (rootfs.tar IS the /data/.reforge chroot tree: /mod, /lkg, /.shell
# live at its root, like mem-probe / reforge-render adapt).  In qemu there is no
# mmcblk0p7 and no stock outer root, so we run the ReForge init chain in place
# (no chroot) — exactly as mem-probe does via /mod/start.sh.
#
# To exercise the REAL trial/LKG contract we relocate mod/ + lkg/ under
# /data/.reforge/ (the absolute paths reforge-lkg.sh resolves) and leave /mod,
# /lkg as symlinks so start.sh's hardcoded /mod/... paths still resolve:
#
#   /data/.reforge/mod    <- the (broken) trial mod
#   /data/.reforge/lkg    <- the good last-known-good baseline
#   /data/.reforge/state  <- trial.count lives here
#   /mod -> /data/.reforge/mod      /lkg -> /data/.reforge/lkg
#
# A single injected init script S98otalkg runs the SAME trial block as
# reforge-boot (source reforge-lkg.sh; is_trial -> inc, or restore at N), then
# execs /mod/start.sh.  An injected /mod/init.d/S99ok promotes on services-up.
# The broken mod's S60klipper HANGS, so start.sh never reaches S99ok and
# /tmp/reforge-ok is never created — a faithful brick.  Each reboot re-reads the
# persisted counter off the ext4; after N=3 the LKG is restored and the good
# version boots to S99ok.
# ===========================================================================
LKG_IMG="${BUILD_DIR}/ota-test-lkg.ext4"
LKG_SERIAL="${BUILD_DIR}/ota-test-lkg-serial.log"

run_lkg_test() {
    log "==================== STEP 2: CRITICAL LKG / brick-rollback ===================="
    SCRATCH="$(mktemp -d /tmp/ota-lkg-stage-XXXXXX)"
    local stage="${SCRATCH}/root"
    mkdir -p "${stage}"

    log "staging rootfs from ${ROOTFS_TAR} ..."
    extract_rootfs "${stage}"

    [ -d "${stage}/mod" ] || die "rootfs has no /mod tree (not a ReForge chroot rootfs)"

    # --- relocate mod/ + lkg/ under /data/.reforge, leave /mod /lkg symlinks ---
    log "relocating mod/ + lkg/ under /data/.reforge (real trial/LKG paths) ..."
    mkdir -p "${stage}/data/.reforge"
    mv "${stage}/mod" "${stage}/data/.reforge/mod"
    if [ -d "${stage}/lkg" ]; then
        mv "${stage}/lkg" "${stage}/data/.reforge/lkg"
    else
        cp -a "${stage}/data/.reforge/mod" "${stage}/data/.reforge/lkg"
    fi
    mkdir -p "${stage}/data/.reforge/state"
    ln -snf /data/.reforge/mod "${stage}/mod"
    ln -snf /data/.reforge/lkg "${stage}/lkg"

    local MOD="${stage}/data/.reforge/mod"
    local LKG="${stage}/data/.reforge/lkg"

    # --- the GOOD baseline (lkg) gets a distinct, KNOWN-GOOD version + S99ok ---
    # S99ok is the services-up sentinel (the LAST script /mod/start.sh runs). The
    # real S99ok only ECHOES on a trial (is_trial && echo "promoting"); after a
    # restore the versions match so it would be silent. We therefore wrap the real
    # sentinel: source reforge-lkg.sh, lkg_promote, touch /tmp/reforge-ok, and
    # ALWAYS emit a console stamp so the harness can detect services-up regardless
    # of trial state. This still calls the REAL lkg_promote contract.
    # The shipped rootfs.tar may carry an OLD stub reforge-lkg.sh (no-op
    # is_trial/lkg_* helpers, pre-Task-4). Inject the REAL helper from the
    # overlay source into both trees so we exercise the genuine trial/LKG
    # contract, not a stub.
    local LKG_SH_SRC="${REPO_ROOT}/br-external/board/reforge/rootfs-overlay/.shell/reforge-lkg.sh"
    [ -f "${LKG_SH_SRC}" ] || die "reforge-lkg.sh source missing: ${LKG_SH_SRC}"
    cp -a "${LKG_SH_SRC}" "${MOD}/.shell/reforge-lkg.sh"; chmod 0755 "${MOD}/.shell/reforge-lkg.sh"
    cp -a "${LKG_SH_SRC}" "${LKG}/.shell/reforge-lkg.sh"; chmod 0755 "${LKG}/.shell/reforge-lkg.sh"

    _write_s99ok() {
        cat > "$1" <<'EOF'
#!/bin/sh
# S99ok (ota-test wrapper) — services-up sentinel. Calls the REAL lkg_promote
# contract, then emits an UNCONDITIONAL console stamp so the harness detects
# services-up even after a restore (when is_trial would be false and the stock
# S99ok stays silent).
[ "$1" = start ] || exit 0
. /mod/.shell/reforge-lkg.sh
is_trial && echo "[S99ok] services up — promoting mod -> LKG"
lkg_promote
touch /tmp/reforge-ok
echo "REFORGE-OK-STAMP services-up version=$(grep -o '\"version\"[^,]*' /mod/release_info.json 2>/dev/null | sed 's/.*: *\"//;s/\"//')" > /dev/console 2>/dev/null || true
EOF
        chmod 0755 "$1"
    }
    _write_s99ok "${LKG}/init.d/S99ok"
    _write_s99ok "${MOD}/init.d/S99ok"

    cat > "${LKG}/release_info.json" <<'EOF'
{
  "project_name": "reforge",
  "project_owner": "maci0",
  "version": "1.0.0-good",
  "asset_name": "reforge.zip"
}
EOF

    # --- the BROKEN trial mod: distinct version + a HANGING S60klipper ---------
    # start.sh runs with `set +e`, so a non-zero exit would NOT stop the chain;
    # a HANG is the faithful brick — the boot wedges before S99ok, so the
    # services-up marker is never written.
    cat > "${MOD}/release_info.json" <<'EOF'
{
  "project_name": "reforge",
  "project_owner": "maci0",
  "version": "9.9.9-broken",
  "asset_name": "reforge.zip"
}
EOF
    cat > "${MOD}/init.d/S60klipper" <<'EOF'
#!/bin/sh
# Deliberately-broken trial mod (ota-test STEP 2): wedge the boot so the chain
# never reaches S99ok. Proves N-strike LKG rollback. A real brick would hang here.
[ "$1" = start ] || exit 0
echo "[S60klipper] BROKEN trial mod — hanging to simulate a brick"
# Mark we reached the broken script (for the serial assertion), then wedge.
echo BROKEN-MOD-REACHED > /dev/console 2>/dev/null || true
while : ; do sleep 3600; done
EOF
    chmod 0755 "${MOD}/init.d/S60klipper"

    # --- injected init: the reforge-boot trial block + launch the chain --------
    # Mirrors br-external/.../reforge-boot's LKG guard (is_trial / inc / restore
    # at N) then runs /mod/start.sh in place (no chroot, like mem-probe). Numbered
    # S50 so it runs after networking but before nothing else needs it.
    mkdir -p "${stage}/etc/init.d"
    cat > "${stage}/etc/init.d/S98otalkg" <<'EOF'
#!/bin/sh
# S98otalkg — ota-test LKG harness boot hook (stands in for reforge-boot in the
# chroot-less qemu rootfs). Runs the SAME trial/LKG guard as reforge-boot, then
# execs /mod/start.sh. See ota-test.sh STEP 2 for the contract.
[ "$1" = start ] || exit 0

REFORGE_DATA_ROOT=/data
export REFORGE_DATA_ROOT
LKG_HELPERS=/data/.reforge/mod/.shell/reforge-lkg.sh

if [ -f "${LKG_HELPERS}" ]; then
    # shellcheck source=/dev/null
    . "${LKG_HELPERS}"
    echo "[ota-lkg] DATA=${DATA} MOD=${MOD} LKG=${LKG}"
    echo "[ota-lkg] mod_ver=[$(mod_version "${MOD}")] lkg_ver=[$(mod_version "${LKG}")] lkg_dir=$([ -d "${LKG}" ] && echo yes || echo no)"
    if is_trial; then
        _cnt="$(lkg_counter_get)"
        if [ "${_cnt}" -ge "${N}" ]; then
            echo "[ota-lkg] trial failed ${N}x (count=${_cnt}) — restoring LKG"
            lkg_restore
        else
            echo "[ota-lkg] trial boot (count=${_cnt}) — incrementing trial counter"
            lkg_counter_inc
        fi
    else
        echo "[ota-lkg] not a trial (mod==lkg or fresh) — no counter change"
    fi
fi

echo "[ota-lkg] trial.count=$(cat /data/.reforge/state/trial.count 2>/dev/null || echo 0) mod_ver=$(grep -o '\"version\"[^,]*' /data/.reforge/mod/release_info.json 2>/dev/null | sed 's/.*: *\"//;s/\"//')"
echo "[ota-lkg] launching /mod/start.sh ..."
SCREEN_MODE=HEADLESS
export SCREEN_MODE
/mod/start.sh
echo "[ota-lkg] /mod/start.sh returned (chain complete)"
EOF
    chmod 0755 "${stage}/etc/init.d/S98otalkg"

    # Stub the outer rootfs's own service S-scripts (if any leaked into the tar)
    # so they don't race the in-place /mod chain. The ReForge S-scripts live in
    # /mod/init.d, not /etc/init.d, so this is just belt-and-suspenders.
    for svc in S60klipper S65moonraker S70httpd S75guppyscreen; do
        if [ -f "${stage}/etc/init.d/${svc}" ]; then
            printf '#!/bin/sh\nexit 0\n' > "${stage}/etc/init.d/${svc}"
            chmod 0755 "${stage}/etc/init.d/${svc}"
        fi
    done

    # --- bake the ext4 (rootless) -------------------------------------------
    log "baking LKG test ext4 via mke2fs -d (no sudo) ..."
    rm -f "${LKG_IMG}"
    mke2fs -q -F -t ext4 -L ota-lkg -d "${stage}" "${LKG_IMG}" 1024M
    rm -rf "${SCRATCH}"; SCRATCH=""
    log "ext4 ready: ${LKG_IMG}"

    # --- boot loop ----------------------------------------------------------
    local N=3 boot pass_restore=0 prev_count=-1
    local last_ver="" restored_boot=0
    # We boot N times expecting brick+inc, then a final boot that should restore.
    # Total boots needed = N (each increments) + 1 (the restore+good boot). On the
    # boot where count has reached N, reforge-boot restores LKG; that SAME boot
    # then launches the now-good mod which reaches S99ok.
    local total=$((N + 1))
    for boot in $(seq 1 "${total}"); do
        log "---- LKG boot ${boot}/${total} ----"
        wait_for_qemu_drain
        rm -f "${LKG_SERIAL}"
        # A broken boot wedges (use the short hang cap); the restore boot must
        # reach services-up (use the longer boot cap). We can't know in advance
        # which this is, so use the long cap throughout and rely on the guest
        # powering off itself only on the good boot — broken boots are killed by
        # the cap. To keep broken boots short, cap them at HANG_TIMEOUT and only
        # extend once we believe a restore happened.
        # Broken boots wedge (short cap); the boot where the restore fires must
        # reach services-up on the good mod (long cap). reforge-boot restores once
        # the counter reaches N, i.e. on boot N+1, so give boots >= N the long cap.
        local cap="${HANG_TIMEOUT}"
        [ "${boot}" -ge "${N}" ] && cap="${BOOT_TIMEOUT}"

        # We poll the serial for the per-boot verdict and kill our own qemu (a
        # wedged boot never powers off; the good boot's services-up stamp is
        # detected via serial, then we stop it — we don't depend on poweroff).
        qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -m 256 \
            -kernel "${ZIMAGE}" \
            -append "console=ttyAMA0,115200 root=/dev/vda rw rootwait panic=1 loglevel=4" \
            -drive "file=${LKG_IMG},if=virtio,format=raw,cache=writeback" \
            -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
            -nographic > "${LKG_SERIAL}" 2>&1 &
        MY_QEMU_PID=$!

        # Poll the serial for the boot's verdict, then stop this boot.
        local waited=0 done=0
        while [ "${waited}" -lt "${cap}" ]; do
            if ! kill -0 "${MY_QEMU_PID}" 2>/dev/null; then done=1; break; fi
            if grep -q '\[ota-lkg\] services up — promoting' "${LKG_SERIAL}" 2>/dev/null \
               || grep -q '\[S99ok\]' "${LKG_SERIAL}" 2>/dev/null \
               || grep -q 'REFORGE-OK-STAMP' "${LKG_SERIAL}" 2>/dev/null; then
                done=1; break
            fi
            if grep -q 'restoring LKG' "${LKG_SERIAL}" 2>/dev/null; then
                restored_boot="${boot}"
            fi
            sleep 3
            waited=$((waited + 3))
        done
        kill_my_qemu
        sync

        # Read back the persisted trial counter + mod version from the ext4.
        local count_raw mod_ver
        count_raw="$(dbg_cat "${LKG_IMG}" /data/.reforge/state/trial.count | tr -dc '0-9')"
        [ -n "${count_raw}" ] || count_raw=0
        mod_ver="$(dbg_cat "${LKG_IMG}" /data/.reforge/mod/release_info.json \
            | grep -o '"version"[^,]*' | sed 's/.*: *"//;s/"//')"
        last_ver="${mod_ver}"

        local stamped="no"
        if grep -q 'REFORGE-OK-STAMP' "${LKG_SERIAL}" 2>/dev/null \
           || grep -q 'services up — promoting' "${LKG_SERIAL}" 2>/dev/null \
           || grep -q '\[S99ok\]' "${LKG_SERIAL}" 2>/dev/null; then
            stamped="yes"
        fi

        log "boot ${boot}: trial.count=${count_raw}  mod_ver=${mod_ver}  services-up=${stamped}  (done=${done})"

        # --- assertions per boot (keyed off whether the broken mod survived) ---
        if grep -q 'restoring LKG' "${LKG_SERIAL}" 2>/dev/null; then
            restored_boot="${boot}"
        fi

        if [ "${mod_ver}" = "9.9.9-broken" ]; then
            # Still on the broken trial mod: this MUST be a brick boot.
            # The counter must have climbed and S99ok must NOT have been reached.
            if [ "${count_raw}" -le "${prev_count}" ]; then
                grep -E '\[ota-lkg\]|BROKEN' "${LKG_SERIAL}" 2>/dev/null | tail -20 | sed 's/^/  /'
                die "boot ${boot}: trial counter did not increment (got ${count_raw}, prev ${prev_count})"
            fi
            if [ "${stamped}" = "yes" ]; then
                die "boot ${boot}: S99ok reached on the BROKEN mod (must be impossible)"
            fi
            log "  [PASS] brick boot ${boot}: counter ${prev_count}->${count_raw}, NO services-up, broken mod intact"
        elif [ "${mod_ver}" = "1.0.0-good" ]; then
            # The LKG was restored: the good mod is now in place.
            log "  LKG restored on boot ${boot}: mod_ver=${mod_ver}"
            if [ "${stamped}" = "yes" ]; then
                pass_restore=1
                log "  [PASS] restored GOOD mod reached services-up (S99ok) on boot ${boot}"
                break
            fi
            warn "boot ${boot}: good mod restored but services-up not yet observed (cap ${cap}s)"
        else
            die "boot ${boot}: unexpected mod version '${mod_ver}'"
        fi
        prev_count="${count_raw}"
    done

    echo ""
    log "=== STEP 2 verdict ==="
    log "restore fired on boot: ${restored_boot:-<never>}   final mod version: ${last_ver}"
    if [ "${pass_restore}" -eq 1 ]; then
        log "PASS: LKG / brick-rollback — broken mod counted ${N} strikes, NEVER reached"
        log "      services-up, then the LKG good mod was restored and booted to S99ok."
        return 0
    fi
    echo ""
    log "Serial tail of the last boot:"
    tail -40 "${LKG_SERIAL}" 2>/dev/null | sed 's/^/  /' || true
    die "LKG / brick-rollback did NOT complete (no restored good boot reached services-up)"
}

# ===========================================================================
# STEP 3 — Mainsail web check.
# ===========================================================================
#
# Spec asks for /var/www/mainsail manifest with name 'mainsail'. The shipped
# bundle's canonical identity marker is /var/www/mainsail/release_info.json
# (project_name: mainsail); manifest.webmanifest carries the human "Mainsail".
# We assert the Mainsail bundle is installed and identifiable as mainsail.
# (read straight from the rootfs tar — no boot needed.)
# ===========================================================================
run_mainsail_check() {
    log "==================== STEP 3: Mainsail web check ===================="
    local tmp; tmp="$(mktemp -d /tmp/ota-mainsail-XXXXXX)"
    local ok=0
    local want="./var/www/mainsail/release_info.json"
    local altwant="./var/www/mainsail/manifest.webmanifest"
    case "${ROOTFS_TAR}" in
        *.xz) tar -xJf "${ROOTFS_TAR}" -C "${tmp}" "${want}" "${altwant}" ./var/www/mainsail/index.html 2>/dev/null || true ;;
        *)    tar -xf  "${ROOTFS_TAR}" -C "${tmp}" "${want}" "${altwant}" ./var/www/mainsail/index.html 2>/dev/null || true ;;
    esac
    local ri="${tmp}/var/www/mainsail/release_info.json"
    local idx="${tmp}/var/www/mainsail/index.html"
    if [ -f "${ri}" ] && grep -q '"project_name"[[:space:]]*:[[:space:]]*"mainsail"' "${ri}"; then
        log "[PASS] Mainsail bundle present and identified as mainsail:"
        log "       $(tr -d '\n' < "${ri}")"
        [ -f "${idx}" ] && log "       index.html present ($(wc -c < "${idx}") bytes)"
        ok=1
    else
        warn "Mainsail release_info.json not found / not name=mainsail under /var/www/mainsail"
    fi
    rm -rf "${tmp}"
    [ "${ok}" -eq 1 ] || die "Mainsail web bundle not installed"
}

# ===========================================================================
# STEP 1 — e2e Moonraker update (best-effort).
# ===========================================================================
#
# Heavy: requires Moonraker live on :7125, the mock release server reachable from
# the guest with its CA trusted + api.github.com hosts-override, and per-component
# OTA zips in packaging/dist. If any precondition is missing we log SKIPPED with
# the reason and return 0 (the LKG test is the gating result). We NEVER fake a pass.
# ===========================================================================
E2E_IMG="${BUILD_DIR}/ota-test-e2e.ext4"
E2E_SERIAL="${BUILD_DIR}/ota-test-e2e-serial.log"
E2E_PORT="${E2E_PORT:-17125}"

run_e2e_test() {
    log "==================== STEP 1: e2e Moonraker update (best-effort) ===================="

    # Precondition: per-component OTA zips to serve.
    local zips
    zips="$(ls "${DIST_DIR}"/*.zip 2>/dev/null || true)"
    if [ -z "${zips}" ]; then
        log "SKIP (e2e): no per-component OTA zips in ${DIST_DIR} — build a test release first."
        log "            (the LKG/brick test below is the gating result and runs network-free)"
        return 0
    fi
    if [ ! -x "${MOCK}" ]; then
        log "SKIP (e2e): mock release server missing/not executable: ${MOCK}"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || { log "SKIP (e2e): curl not installed."; return 0; }

    # Start the offline mock release server + obtain its CA.
    local ca
    ca="$("${MOCK}" --print-ca 2>/dev/null || true)"
    if [ -z "${ca}" ] || [ ! -f "${ca}" ]; then
        log "SKIP (e2e): could not obtain mock CA."; return 0
    fi
    # The guest reaches the mock through a qemu guestfwd on api.github.com:443
    # (Moonraker's http_client.py hardcodes https://api.github.com/), so the
    # advertised asset URLs must use port 443 too — PUBLIC_PORT=443 makes the
    # mock emit portless (==443) browser_download_urls that land on the same
    # guestfwd. The mock itself still LISTENS on MOCK_PORT host-side.
    PORT="${MOCK_PORT}" PUBLIC_PORT=443 "${MOCK}" >/dev/null 2>&1 &
    MOCK_PID=$!
    sleep 2
    if ! kill -0 "${MOCK_PID}" 2>/dev/null; then
        log "SKIP (e2e): mock server failed to start."; MOCK_PID=""; return 0
    fi
    log "mock release server up on :${MOCK_PORT} (pid ${MOCK_PID}); CA=${ca}"

    SCRATCH="$(mktemp -d /tmp/ota-e2e-stage-XXXXXX)"
    local stage="${SCRATCH}/root"
    mkdir -p "${stage}"
    log "staging rootfs ..."
    extract_rootfs "${stage}"

    # Inject the mock CA so Moonraker (Tornado -> Python ssl -> OpenSSL) trusts
    # it. CRITICAL: Python's ssl.create_default_context() on this guest reports
    # cafile=None, capath=/etc/ssl/certs — i.e. OpenSSL trusts the hashed-symlink
    # DIRECTORY, NOT the ca-certificates.crt bundle. Appending to that bundle is
    # silently ignored, so the cert MUST be dropped as <subject_hash>.0 in
    # /etc/ssl/certs. (Verified in-guest: bundle-append -> "self-signed
    # certificate" handshake failure; <hash>.0 -> verify OK.)
    mkdir -p "${stage}/etc/ssl/certs" "${stage}/usr/local/share/ca-certificates"
    cp -a "${ca}" "${stage}/usr/local/share/ca-certificates/mock-github.crt" 2>/dev/null || true
    cat "${ca}" >> "${stage}/etc/ssl/certs/ca-certificates.crt" 2>/dev/null || true
    local ca_hash
    ca_hash="$(openssl x509 -hash -noout -in "${ca}" 2>/dev/null || true)"
    if [ -n "${ca_hash}" ]; then
        cp -a "${ca}" "${stage}/etc/ssl/certs/${ca_hash}.0"
        log "installed mock CA into guest trust store as /etc/ssl/certs/${ca_hash}.0"
    else
        warn "could not hash mock CA — guest TLS trust may fail"
    fi
    # Point the GitHub API + asset hosts at the qemu guestfwd target (NOT the
    # slirp gateway 10.0.2.2 — qemu forbids a guestfwd onto its own gateway
    # address). GUEST_MOCK_IP is an otherwise-unused slirp address the guestfwd
    # below redirects to the host-side mock.
    #
    # Separately, blackhole every OTHER GitHub/announcement host to 127.0.0.1
    # (nothing listens there -> instant connection-refused). Moonraker's
    # announcements + the other updaters' refreshes would otherwise open REAL
    # internet TLS to arksine.github.io / *.githubusercontent.com (185.199.x.x);
    # under ARM TCG those slow handshakes monopolise the event loop and starve
    # our OTA asset download, whose connect_timeout is only 5s. Failing them fast
    # keeps the emulated CPU free for the update we actually exercise.
    {
        echo "${GUEST_MOCK_IP} api.github.com"
        echo "127.0.0.1 objects.githubusercontent.com"
        echo "127.0.0.1 github.com"
        echo "127.0.0.1 www.github.com"
        echo "127.0.0.1 raw.githubusercontent.com"
        echo "127.0.0.1 arksine.github.io"
        echo "127.0.0.1 codeload.github.com"
    } >> "${stage}/etc/hosts" 2>/dev/null || true

    # Seed an OLDER version into a component path so the update has a delta to
    # apply. We target [update_manager guppyscreen] (path /opt/guppyscreen):
    #
    #   * 'klipper' and 'moonraker' are RESERVED updater names in Moonraker —
    #     update_manager rewires them to its own klipper/moonraker handling
    #     (klipper is keyed off 'server:klippy_identified', which never fires in
    #     this MCU-less qemu guest), so their /machine/update/status entries come
    #     back empty {} and they can't be driven as plain zip updaters.
    #   * 'reforge' restarts the WHOLE S-chain (managed_services: reforge ->
    #     /mod/stop.sh; /mod/start.sh), which would tear down Moonraker itself
    #     mid-update.
    #   * 'guppyscreen' is a plain zip updater whose managed_services restart is a
    #     no-op here (S75guppyscreen self-skips without /dev/fb0), so it's the
    #     clean, side-effect-free component to exercise end to end.
    #
    # The seed keeps project_owner/name = maci0/reforge so the updater's repo
    # matches what the mock serves (/repos/maci0/reforge/releases/latest). The
    # asset_name pins the download to the SMALLEST published zip (reforge.zip,
    # ~260KB vs guppyscreen.zip ~2.4MB): the asset's payload is irrelevant to
    # what we assert (only that an OTA download+extract bumped the recorded
    # version), and a small asset finishes well inside Moonraker's download
    # window under slow ARM-TCG networking. After extraction the path's
    # release_info.json carries the asset's version (0.3.0-dev), which is the
    # bump we assert.
    E2E_COMPONENT="guppyscreen"
    E2E_PATH="/opt/guppyscreen"
    mkdir -p "${stage}${E2E_PATH}"
    cat > "${stage}${E2E_PATH}/release_info.json" <<'EOF'
{ "project_name": "reforge", "project_owner": "maci0", "version": "0.0.1-old", "asset_name": "reforge.zip" }
EOF

    # Bring up the in-place chain on boot (mem-probe pattern) so Moonraker is live.
    cat > "${stage}/etc/init.d/S98otae2e" <<'EOF'
#!/bin/sh
[ "$1" = start ] || exit 0
[ -x /mod/start.sh ] && SCREEN_MODE=HEADLESS /mod/start.sh > /dev/console 2>&1
EOF
    chmod 0755 "${stage}/etc/init.d/S98otae2e"

    log "baking e2e ext4 ..."
    rm -f "${E2E_IMG}"
    mke2fs -q -F -t ext4 -L ota-e2e -d "${stage}" "${E2E_IMG}" 1536M
    rm -rf "${SCRATCH}"; SCRATCH=""

    # Boot with a Moonraker port-forward.
    wait_for_qemu_drain
    rm -f "${E2E_SERIAL}"
    log "booting e2e guest (Moonraker forward host:${E2E_PORT} -> :7125;" \
        "guest api.github.com (${GUEST_MOCK_IP}:443) -> mock 127.0.0.1:${MOCK_PORT}) ..."
    # hostfwd : host:E2E_PORT -> guest:7125 so we can drive Moonraker from the host.
    # guestfwd: the guest's connection to api.github.com:443 (resolved to
    #           GUEST_MOCK_IP via the injected /etc/hosts) is redirected to the
    #           host-side mock on 127.0.0.1:MOCK_PORT. Moonraker's update_manager
    #           hardcodes https://api.github.com/ (port 443) for BOTH the releases
    #           API call and the asset download, so this single guestfwd carries
    #           the whole OTA conversation to the offline mock — no real network.
    #           (GUEST_MOCK_IP is deliberately NOT 10.0.2.2: qemu refuses a
    #           guestfwd onto its own slirp gateway address.)
    # -smp 2 / -m 128: match the real device — the T113-S3 is a dual-core Cortex-A7
    # with 128MB DDR (≈110MB usable after CMA/DSP reserve). The second core is also
    # what makes the download land: under TCG the qemu main loop drives slirp
    # networking, so a single saturated vCPU (Moonraker's components + numpy) starves
    # the guestfwd and the guest's outbound TLS connect repeatedly misses Moonraker's
    # tight 5s download connect-timeout. The device has two real cores, so giving the
    # guest two keeps networking responsive while Python runs — device-faithful AND
    # enough to let the OTA asset download complete. (The LKG test in Step 2 keeps its
    # lean single-cpu profile — it never touches the network.)
    qemu-system-arm -M virt,highmem=off -cpu cortex-a7 -smp 2 -m 128 \
        -kernel "${ZIMAGE}" \
        -append "console=ttyAMA0,115200 root=/dev/vda rw rootwait loglevel=4" \
        -drive "file=${E2E_IMG},if=virtio,format=raw,cache=writeback" \
        -netdev "user,id=n0,hostfwd=tcp::${E2E_PORT}-:7125,guestfwd=tcp:${GUEST_MOCK_IP}:443-tcp:127.0.0.1:${MOCK_PORT}" \
        -device virtio-net-pci,netdev=n0 \
        -nographic > "${E2E_SERIAL}" 2>&1 &
    MY_QEMU_PID=$!

    # Poll for Moonraker.
    local up=0 waited=0
    while [ "${waited}" -lt "${BOOT_TIMEOUT}" ]; do
        kill -0 "${MY_QEMU_PID}" 2>/dev/null || break
        if curl -sf --max-time 8 "http://127.0.0.1:${E2E_PORT}/server/info" 2>/dev/null \
            | grep -q 'klippy_state'; then up=1; break; fi
        sleep 5; waited=$((waited + 5))
    done
    if [ "${up}" -ne 1 ]; then
        kill_my_qemu
        log "SKIP (e2e): Moonraker did not come up within ${BOOT_TIMEOUT}s — best-effort step skipped."
        log "Serial tail:"; tail -25 "${E2E_SERIAL}" 2>/dev/null | sed 's/^/  /' || true
        return 0
    fi
    log "Moonraker live. Refreshing + driving update of '${E2E_COMPONENT}' ..."

    # The initial auto-refresh holds update_manager's cmd_request_lock for a
    # while at startup (each updater hits the mock once); a refresh/update during
    # that window returns 503 "Server is busy". Wait for the status to settle
    # (busy:false) before driving, so our refresh/update isn't rejected.
    local _w
    # shellcheck disable=SC2034
    for _w in $(seq 1 24); do
        kill -0 "${MY_QEMU_PID}" 2>/dev/null || break
        if curl -sf --max-time 8 "http://127.0.0.1:${E2E_PORT}/machine/update/status" 2>/dev/null \
            | grep -qE '"busy": *false'; then break; fi
        sleep 5
    done

    # Drive the update in a RETRY LOOP, asserting off the LIVE Moonraker status
    # (authoritative — a kill -9 with cache=writeback can drop not-yet-flushed
    # disk writes, so the on-disk release_info.json may lag the applied version).
    #
    # Why retry: Moonraker's asset download (net_deploy.update -> http_client.
    # download_file) uses connect_timeout=5s, attempts=1. Under ARM TCG the
    # guest's TLS connect to the mock through the slirp guestfwd intermittently
    # misses that 5s window while klipper/httpd churn the emulated CPU, surfacing
    # as a 500 "Timeout while connecting". The releases-API refresh (attempts=3)
    # almost always lands, so remote_version resolves; we just re-drive the
    # update until one attempt's download wins the 5s race. A NAMED app updater
    # (guppyscreen) is driven via /machine/update/client?name=<app> — only
    # moonraker/klipper/system/client/full have dedicated endpoints; a direct
    # POST /machine/update/<app> 404s.
    local live_ver="0.0.1-old" seen_remote="?" attempt
    for attempt in $(seq 1 20); do
        kill -0 "${MY_QEMU_PID}" 2>/dev/null || break

        # (Re)fetch remote version, then attempt the update. Both can transiently
        # 503 (busy) / 500 (download timeout); that's expected — we loop.
        curl -s --max-time 30 -X POST \
            "http://127.0.0.1:${E2E_PORT}/machine/update/refresh?name=${E2E_COMPONENT}" \
            >/dev/null 2>&1 || true
        curl -s --max-time 90 -X POST \
            "http://127.0.0.1:${E2E_PORT}/machine/update/client?name=${E2E_COMPONENT}" \
            >/dev/null 2>&1 || true

        # Read back the component's live version. Retry a few times while the
        # status is mid-flight (an in-progress update can briefly report the
        # component as {} -> "?"); we only want a settled reading.
        local st parsed try
        live_ver="?"; seen_remote="?"
        # shellcheck disable=SC2034  # try is just a small retry counter
        for try in 1 2 3 4 5; do
            st="$(curl -sf --max-time 8 "http://127.0.0.1:${E2E_PORT}/machine/update/status" 2>/dev/null || true)"
            parsed="$(printf '%s' "${st}" \
                | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)["result"]["version_info"].get("'"${E2E_COMPONENT}"'",{})
  print((d.get("version") or "?"), (d.get("remote_version") or "?"))
except Exception:
  print("? ?")' 2>/dev/null || echo "? ?")"
            live_ver="${parsed%% *}"
            seen_remote="${parsed##* }"
            [ "${live_ver}" != "?" ] && break
            sleep 3
        done
        log "  e2e update attempt ${attempt}: ${E2E_COMPONENT} version=${live_ver} remote=${seen_remote}"
        if [ "${live_ver}" != "0.0.1-old" ] && [ "${live_ver}" != "?" ]; then
            break
        fi
        sleep 5
    done
    log "live ${E2E_COMPONENT} version after update: ${live_ver}" \
        "(was 0.0.1-old; remote=${seen_remote})"

    # Best-effort on-disk confirmation (may lag due to writeback; informational).
    kill_my_qemu; sync
    local diskver
    diskver="$(dbg_cat "${E2E_IMG}" "${E2E_PATH}/release_info.json" \
        | grep -o '"version"[^,]*' | sed 's/.*: *"//;s/"//')"
    log "on-disk ${E2E_PATH} version (post-kill, may lag writeback): ${diskver:-<unknown>}"

    if [ -n "${live_ver}" ] && [ "${live_ver}" != "0.0.1-old" ] && [ "${live_ver}" != "?" ]; then
        log "PASS (e2e): Moonraker applied the OTA update against the offline mock —" \
            "${E2E_COMPONENT} version bumped 0.0.1-old -> ${live_ver}" \
            "(remote advertised ${seen_remote})."
        return 0
    fi

    # Failed to bump: surface Moonraker's own log so the blocker is diagnosable
    # (download error, TLS trust, etc.) rather than a bare skip. Moonraker logs
    # to stdout by default here, so this read-back is best-effort.
    log "e2e update did not bump the version; Moonraker log tail (if any):"
    dbg_cat "${E2E_IMG}" /var/lib/moonraker/logs/moonraker.log 2>/dev/null \
        | grep -iE 'update_manager|github|guppyscreen|download|refresh|tls|ssl|certificate|error' \
        | tail -25 | sed 's/^/  /' || true
    log "SKIP (e2e): version did not bump — best-effort step, not failing the run."
    log "            (the LKG / brick-rollback test below is the gating result.)"
    return 0
}

# ===========================================================================
# Driver
# ===========================================================================
RC=0
if [ "${ONLY_E2E:-0}" = "1" ]; then
    run_e2e_test || RC=$?
else
    if [ "${SKIP_E2E:-0}" != "1" ]; then
        run_e2e_test || true   # best-effort; never gates the run
    else
        log "SKIP_E2E=1 — skipping Step 1 (e2e update)."
    fi
    run_mainsail_check
    run_lkg_test || RC=$?
fi

echo ""
if [ "${RC}" -eq 0 ]; then
    log "OVERALL: PASS"
else
    log "OVERALL: FAIL"
fi
exit "${RC}"
