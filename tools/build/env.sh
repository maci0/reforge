# shared build environment
# shellcheck shell=bash  # only ever sourced from build.sh (#!/bin/bash); uses BASH_SOURCE
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFORGE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REFORGE_ROOT
export BUILDROOT_GIT="$REFORGE_ROOT/vendor/buildroot"
export BR2_EXTERNAL_DIR="$REFORGE_ROOT/br-external"
export OUTPUT_DIR="$REFORGE_ROOT/build/output"
MULTICORE="-j$(nproc)"
export MULTICORE
