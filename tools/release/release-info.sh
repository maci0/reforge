#!/usr/bin/env bash
# release-info.sh — DRY helper for the OTA release builder.
#
# emit_release_info <project_name> <version> <asset_name>
#   Prints a release_info.json with EXACTLY four keys. Moonraker's net_deploy
#   reads <component-path>/release_info.json on-device; a missing project_owner
#   marks the install invalid, so the owner is hardcoded to "maci0".
#
# Sourceable: `. tools/release/release-info.sh` then call emit_release_info.
emit_release_info() {
    printf '{\n  "project_name": "%s",\n  "project_owner": "maci0",\n  "version": "%s",\n  "asset_name": "%s"\n}\n' \
        "$1" "$2" "$3"
}
