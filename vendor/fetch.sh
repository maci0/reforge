#!/usr/bin/env bash
# Fetch all vendored third-party trees into vendor/ reproducibly.
#
#   - Submodules (buildroot, tina-bsp-kernel): cloned/checked out at the pinned commit.
#   - Toolchain (gcc crosstool): downloaded as a tarball, verified against the sha256
#     in pins.lock, and extracted.
#
# Pins live in ../pins.lock (the single source of truth). Run from anywhere:
#   ./vendor/fetch.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PINS="$REPO_ROOT/pins.lock"
log() { echo "[vendor] $*"; }
die() { echo "[vendor] ERROR: $*" >&2; exit 1; }

# --- 1. Submodules (buildroot + BSP kernel) ----------------------------------
log "Initializing submodules at their pinned commits ..."
git -C "$REPO_ROOT" submodule update --init --recursive \
    vendor/buildroot vendor/kernels/tina-bsp-kernel
log "  buildroot          -> $(git -C "$REPO_ROOT/vendor/buildroot" describe --tags --always 2>/dev/null || echo '?')"
log "  tina-bsp-kernel    -> $(git -C "$REPO_ROOT/vendor/kernels/tina-bsp-kernel" rev-parse --short HEAD 2>/dev/null || echo '?') (5.4.61)"

# --- 2. Toolchain (pinned tarball, verified by sha256) -----------------------
TC_DIR="$REPO_ROOT/vendor/toolchains/gcc-9.5.0-nolibc"
if [ -x "$TC_DIR/arm-linux-gnueabi/bin/arm-linux-gnueabi-gcc" ]; then
    log "Toolchain already present: $TC_DIR"
else
    # pins.lock row: gcc-crosstool tarball 9.5.0 <sha256> <url>
    read -r _name _kind _ver TC_SHA TC_URL < <(grep '^gcc-crosstool[[:space:]]' "$PINS") \
        || die "no gcc-crosstool row in $PINS"
    TARBALL="$REPO_ROOT/vendor/toolchains/gcc-crosstool-${_ver}.tar.xz"
    log "Downloading toolchain ${_ver} ..."
    log "  $TC_URL"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 -o "$TARBALL" "$TC_URL"
    else
        wget -O "$TARBALL" "$TC_URL"
    fi
    log "Verifying sha256 against pin ..."
    GOT="$(sha256sum "$TARBALL" | awk '{print $1}')"
    if [ "$GOT" != "$TC_SHA" ]; then
        die "sha256 mismatch for toolchain:
       pinned: $TC_SHA
       got:    $GOT
     The mirror may have repackaged the artifact. Obtain the exact pinned tarball,
     or update pins.lock if you have verified the new artifact is correct."
    fi
    log "  ok ($GOT)"
    log "Extracting -> vendor/toolchains/ ..."
    tar -xJf "$TARBALL" -C "$REPO_ROOT/vendor/toolchains/"
    [ -x "$TC_DIR/arm-linux-gnueabi/bin/arm-linux-gnueabi-gcc" ] \
        || die "extracted, but $TC_DIR/arm-linux-gnueabi/bin/arm-linux-gnueabi-gcc missing"
    rm -f "$TARBALL"
    log "  toolchain ready: $TC_DIR"
fi

# --- 3. Linaro 5.3.1 toolchain (OPTIONAL, byte-identical-reproduction build) -
# Fetched only when explicitly requested via FETCH_LINARO=1; the ReForge
# shipping image uses GCC 9.5.0 above. The Linaro toolchain is the EXACT
# compiler stock FlashForge used (`(Linaro GCC 5.3-2016.05) 5.3.1 20160412`)
# per the embedded Linux version banner; the byte-identical-attempt build
# at tools/build/build-bsp-kernel-stock.sh needs it.
LINARO_DIR="$REPO_ROOT/vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi"
if [ "${FETCH_LINARO:-0}" = "1" ]; then
    if [ -x "$LINARO_DIR/bin/arm-linux-gnueabi-gcc" ]; then
        log "Linaro 5.3.1 already present: $LINARO_DIR"
    else
        read -r _name _kind _ver LR_SHA LR_URL < <(grep '^gcc-linaro-5.3.1[[:space:]]' "$PINS") \
            || die "no gcc-linaro-5.3.1 row in $PINS"
        LR_TARBALL="$REPO_ROOT/vendor/toolchains/gcc-linaro-5.3.1.tar.xz"
        log "Downloading Linaro toolchain ${_ver} ..."
        log "  $LR_URL"
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 3 -o "$LR_TARBALL" "$LR_URL"
        else
            wget -O "$LR_TARBALL" "$LR_URL"
        fi
        log "Verifying sha256 against pin ..."
        GOT="$(sha256sum "$LR_TARBALL" | awk '{print $1}')"
        if [ "$GOT" != "$LR_SHA" ]; then
            die "sha256 mismatch for Linaro toolchain:
       pinned: $LR_SHA
       got:    $GOT"
        fi
        log "  ok ($GOT)"
        log "Extracting -> vendor/toolchains/ ..."
        tar -xJf "$LR_TARBALL" -C "$REPO_ROOT/vendor/toolchains/"
        [ -x "$LINARO_DIR/bin/arm-linux-gnueabi-gcc" ] \
            || die "extracted, but $LINARO_DIR/bin/arm-linux-gnueabi-gcc missing"
        rm -f "$LR_TARBALL"
        log "  Linaro toolchain ready: $LINARO_DIR"
    fi
else
    log "Skipping Linaro 5.3.1 toolchain (set FETCH_LINARO=1 to download). "
    log "  Only needed for tools/build/build-bsp-kernel-stock.sh (byte-identical build)."
fi

log "Done. Vendored trees are at their pinned versions."
