#!/usr/bin/env bash
# =============================================================================
# moonraker-zip-detect-test.sh — validate 0002-zip-updater-for-reserved-apps.patch
# against the REAL built armv7 Moonraker, executed on the target Python via
# qemu-user (qemu-arm). No full-system boot, no root.
#
# Why this exists: the reserved 'klipper'/'moonraker' update_manager updaters get
# their type from AppType.detect(), NOT from config. Upstream detect() returns
# only GIT_REPO/PYTHON/NONE, so a zip-deployed klipper/moonraker is typed NONE
# and is not OTA-updatable (and emits "Unparsed config option" warnings). Our
# 0002 patch makes a directory carrying release_info.json detect as ZIP. This
# test runs that exact patched code on the target Python and asserts:
#     detect(<dir with release_info.json>) == ZIP   (the fix)
#     detect(<dir with .git>)              == GIT_REPO  (upstream, unchanged)
#     detect(<bare dir>)                   == NONE       (upstream, unchanged)
#
# Runs the actual ARM .so/.py shipped in the image, so it also proves the patch
# survived the build (buildroot applied it) — not just that the .patch is valid.
#
# Usage:   tests/qemu-harness/moonraker-zip-detect-test.sh
#          make qemu-zipdetect
# Skips (exit 0) if qemu-arm/-static or the built target Moonraker is absent.
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET="${REPO_ROOT}/build/output/target"
MR="${TARGET}/opt/moonraker"
COMMON="${MR}/moonraker/components/update_manager/common.py"

skip() { echo "SKIP: $*"; exit 0; }

QEMU_ARM="$(command -v qemu-arm-static || command -v qemu-arm || true)"
[ -n "${QEMU_ARM}" ] || skip "qemu-arm(-static) not installed"
[ -d "${MR}" ] || skip "built target Moonraker not found (${MR}); run 'make rootfs'"
[ -x "${TARGET}/usr/bin/python3.14" ] || skip "target python3.14 not found; run 'make rootfs'"

# Guard: the build must have actually applied 0002 (else the test is meaningless).
if ! grep -q "return AppType.ZIP" "${COMMON}"; then
    echo "FAIL: built Moonraker is missing the 0002 ZIP-detect patch (${COMMON})"
    exit 1
fi

HARNESS="$(mktemp -t mr-zipdetect-XXXX.py)"
trap 'rm -f "${HARNESS}"' EXIT
cat > "${HARNESS}" <<'PY'
import sys, os, tempfile
MR = sys.argv[1]
sys.path.insert(0, MR)
from moonraker.components.update_manager import common as C
from moonraker.components.update_manager.common import AppType

# Hunk 2: 'repo' must be an override, or reserved klipper/moonraker can't read it
# (NetDeploy requires repo; BASE_CONFIG has none) -> their zip updaters fail.
overrides_ok = "repo" in C.OPTION_OVERRIDES
print(f"  OPTION_OVERRIDES has 'repo' = {overrides_ok} [{'ok' if overrides_ok else 'FAIL'}]")

def mkdir_with(setup=None):
    d = tempfile.mkdtemp()
    if setup:
        setup(d)
    return d

zip_dir = mkdir_with(lambda d: open(
    os.path.join(d, "release_info.json"), "w").write(
    '{"project_name":"klipper","project_owner":"maci0",'
    '"version":"v1.0.0","asset_name":"klipper.zip"}'))
git_dir = mkdir_with(lambda d: os.mkdir(os.path.join(d, ".git")))
bare_dir = mkdir_with()

cases = [
    ("release_info.json dir", AppType.detect(zip_dir), AppType.ZIP),
    (".git dir", AppType.detect(git_dir), AppType.GIT_REPO),
    ("bare dir", AppType.detect(bare_dir), AppType.NONE),
]
ok = overrides_ok
for label, got, want in cases:
    flag = "ok" if got is want else "FAIL"
    if got is not want:
        ok = False
    print(f"  detect({label:22s}) = {str(got):9s} want {str(want):9s} [{flag}]")
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY

echo "Running patched AppType.detect() on target Python via $(basename "${QEMU_ARM}") ..."
"${QEMU_ARM}" -L "${TARGET}" -E PYTHONHOME="${TARGET}/usr" \
    "${TARGET}/usr/bin/python3.14" "${HARNESS}" "${MR}"
rc=$?
[ "${rc}" -eq 0 ] && echo "moonraker-zip-detect-test: PASS" || echo "moonraker-zip-detect-test: FAIL"
exit "${rc}"
