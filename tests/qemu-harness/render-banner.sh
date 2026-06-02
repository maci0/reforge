#!/usr/bin/env bash
# =============================================================================
# render-banner.sh — render the ReForge fire/ember boot banner to PNGs that match
# what the framebuffer console shows, for docs/screenshots/.
#
# Runs usr/bin/reforge-banner under a pty (so it colorizes), converts its 256-color
# ANSI to Pango markup, and rasterizes with pango-view in DejaVu Sans Mono on a dark
# console background. Produces the normal splash and the LIVE-mode splash.
#
# Rootless. Needs: pango-view (pango), script (util-linux), python3, a mono TTF.
# Usage: tests/qemu-harness/render-banner.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BANNER="${REPO_ROOT}/br-external/board/reforge/rootfs-overlay/usr/bin/reforge-banner"
RENDER="$(dirname "${BASH_SOURCE[0]}")/render-screen.py"
OUTDIR="${REPO_ROOT}/docs/screenshots"

command -v script  >/dev/null || { echo "SKIP: script not installed (util-linux)"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 not installed"; exit 0; }
python3 -c 'import PIL' 2>/dev/null || { echo "SKIP: python3 Pillow not installed"; exit 0; }
[ -f "${BANNER}" ] || { echo "ERROR: banner missing: ${BANNER}" >&2; exit 1; }

render() {  # <live 0|1> <out.png>
    local live="$1" out="$2" raw
    raw="$(mktemp)"
    # pty so the banner sees a tty and colorizes (script writes the session to $raw);
    # TERM=xterm-256color enables color. Rasterize centered on the real 800x480 panel.
    script -qfc "TERM=xterm-256color REFORGE_LIVE=${live} sh '${BANNER}'" "${raw}" >/dev/null 2>&1 || true
    python3 "${RENDER}" "${raw}" "${out}" center
    rm -f "${raw}"
}

mkdir -p "${OUTDIR}"
echo "[render-banner] rendering boot splashes ..."
render 0 "${OUTDIR}/reforge-bootsplash.png"
render 1 "${OUTDIR}/reforge-bootsplash-live.png"
echo "[render-banner] done."
