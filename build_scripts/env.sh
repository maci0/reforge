# shared build environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REFORGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export BUILDROOT_GIT="$REFORGE_ROOT/buildroot"
export BR2_EXTERNAL_DIR="$REFORGE_ROOT/br-external"
export OUTPUT_DIR="$REFORGE_ROOT/output"
export MULTICORE="-j$(nproc)"
