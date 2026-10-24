#!/usr/bin/env bash
# =============================================================================
# shots-reforge.sh — capture REAL ReForge framebuffer-console screenshots from
# qemu (not rasterized approximations): the boot splash (normal + LIVE) and the
# boot console, exactly as the 800x480 fbcon paints them (16-color VGA/CP437).
#
# Boots the virt test kernel with virtio-gpu (/dev/fb0 -> fbcon -> tty0), runs a
# tiny init that paints the banner / drives the boot chain on tty0, and grabs the
# screen via the qemu monitor `screendump`. The current overlay reforge-banner is
# injected into the image so captures reflect the working tree, not a stale build.
# Fully ROOTLESS: mke2fs -d, unprivileged qemu.
#
# Usage:  tests/qemu-harness/shots-reforge.sh
# Needs:  qemu-system-arm, mke2fs (e2fsprogs), python3 (Pillow), build/zImage,
#         build/output/images/rootfs.tar[.xz]
# Out:    docs/screenshots/reforge-bootsplash.{png,gif}, -bootsplash-live.png, -boot-console.png
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/tests/qemu-harness"
BUILD_DIR="${HARNESS_DIR}/build"
ZIMAGE="${BUILD_DIR}/zImage"
BANNER="${REPO_ROOT}/br-external/board/reforge/rootfs-overlay/usr/bin/reforge-banner"
OUTDIR="${REPO_ROOT}/docs/screenshots"

log() { echo "[shots-reforge] $*"; }
die() { echo "[shots-reforge] ERROR: $*" >&2; exit 1; }
skip() { echo "[shots-reforge] SKIP: $*"; exit 0; }

ROOTFS_TAR="${ROOTFS_TAR:-${REPO_ROOT}/build/output/images/rootfs.tar}"
[ -f "${ROOTFS_TAR}" ] || ROOTFS_TAR="${REPO_ROOT}/build/output/images/rootfs.tar.xz"
[ -f "${ZIMAGE}" ]     || skip "no ${ZIMAGE} (make qemu-kernel)"
[ -f "${ROOTFS_TAR}" ] || skip "no rootfs.tar (make rootfs)"
command -v qemu-system-arm >/dev/null || die "qemu-system-arm not installed"
command -v mke2fs >/dev/null || die "mke2fs not installed"
python3 -c 'import PIL' 2>/dev/null || skip "python3 Pillow not installed"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
STAGE="${WORK}/root"; mkdir -p "${STAGE}"
log "staging rootfs + injecting the working-tree banner ..."
case "${ROOTFS_TAR}" in
    *.xz) tar --numeric-owner -xJf "${ROOTFS_TAR}" -C "${STAGE}" ;;
    *)    tar --numeric-owner -xf  "${ROOTFS_TAR}" -C "${STAGE}" ;;
esac
install -m 0755 "${BANNER}" "${STAGE}/usr/bin/reforge-banner"

# Three capture inits, each painting on the framebuffer console (tty0).
mkdir -p "${STAGE}/sbin"
paint_head='mount -t proc proc /proc 2>/dev/null; mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null    # ephemeral: no live-marker bleed across boots
TTY=/dev/tty0; [ -c "$TTY" ] || TTY=/dev/console
exec > "$TTY" 2>&1'

cat > "${STAGE}/sbin/shot-splash" <<EOF
#!/bin/sh
${paint_head}
printf '\033[2J\033[H'    # clear the kernel boot text for a clean splash
TERM=linux REFORGE_LIVE=0 /usr/bin/reforge-banner --animate
while true; do sleep 3600; done
EOF
cat > "${STAGE}/sbin/shot-splash-live" <<EOF
#!/bin/sh
${paint_head}
printf '\033[2J\033[H'
: > /run/reforge-live 2>/dev/null || true
TERM=linux REFORGE_LIVE=1 /usr/bin/reforge-banner --animate
while true; do sleep 3600; done
EOF
cat > "${STAGE}/sbin/shot-console" <<EOF
#!/bin/sh
${paint_head}
printf '\033[2J\033[H'
TERM=linux /usr/bin/reforge-banner
echo
# Stub the chroot data layout the real device has (reforge-boot chroots into
# /data/.mod/.reforge with /mod bind-mounted at /data/.mod/.mod/.reforge/mod), so S99ok's
# mod->LKG promotion finds its source and the chain runs as a normal install boot.
mkdir -p /data/.mod/.mod/.reforge/mod /data/.mod/.mod/.reforge/state
mount --bind /mod /data/.mod/.mod/.reforge/mod 2>/dev/null
# Drive the real userspace chain so the console shows cloud-block -> zram -> ...
[ -x /mod/start.sh ] && SCREEN_MODE=HEADLESS /mod/start.sh
echo; echo "Welcome to ReForge"; echo "reforge login: "
while true; do sleep 3600; done
EOF
chmod 0755 "${STAGE}/sbin/shot-splash" "${STAGE}/sbin/shot-splash-live" "${STAGE}/sbin/shot-console"

IMG="${BUILD_DIR}/shots-reforge.ext4"
rm -f "${IMG}"; mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -d "${STAGE}" "${IMG}" 1280M

# Use the stdio monitor: no local socket server or socat is needed.
python3 - "${ZIMAGE}" "${IMG}" "${BUILD_DIR}" "${OUTDIR}" <<'PY_CAPTURE'
from pathlib import Path
import subprocess
import sys
import time
from PIL import Image

kernel, image, build, out = map(Path, sys.argv[1:])
out.mkdir(parents=True, exist_ok=True)
ppm = build / "shots-reforge.ppm"


def capture(init, settle, name, animated=False):
    log = build / "shots-reforge-qemu.log"
    serial = build / "shots-reforge-ser.log"
    print(f"[shots-reforge] boot {init}", flush=True)
    with log.open("wb") as errors:
        proc = subprocess.Popen([
            "qemu-system-arm", "-M", "virt,highmem=off", "-cpu", "cortex-a7",
            "-smp", "2", "-m", "256", "-kernel", str(kernel),
            "-append", f"console=tty0 console=ttyAMA0,115200 root=/dev/vda rw rootwait loglevel=3 init={init}",
            "-device", "virtio-gpu-pci,xres=800,yres=480", "-display", "none",
            "-monitor", "stdio", "-serial", f"file:{serial}",
            "-drive", f"file={image},if=virtio,format=raw,cache=writeback", "-nic", "none",
        ], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=errors)
        try:
            def frame():
                ppm.unlink(missing_ok=True)
                proc.stdin.write(f"screendump {ppm}\n".encode())
                proc.stdin.flush()
                for _ in range(200):
                    if proc.poll() is not None:
                        raise RuntimeError(log.read_text())
                    try:
                        with Image.open(ppm) as shot:
                            return shot.convert("RGB")
                    except OSError:
                        time.sleep(0.01)
                raise RuntimeError("QEMU screendump timed out; see " + str(log))

            started = time.monotonic()
            frames = []
            if animated:
                # The wordmark uses yellow; kernel boot text does not. Start the
                # recording once it appears, regardless of host boot speed.
                while time.monotonic() - started < settle:
                    shot = frame()
                    yellow = sum(count for count, (r, g, b)
                                 in shot.crop((100, 190, 700, 290)).getcolors(60000)
                                 if r > 100 and g > 100 and b < 90)
                    if yellow > 200:
                        # Let the remaining logo/footer lines finish painting.
                        time.sleep(0.15)
                        frames.append(frame())
                        break
                    time.sleep(0.05)
                if not frames:
                    raise RuntimeError("Splash never appeared; see " + str(serial))
                for _ in range(27):
                    time.sleep(0.06)
                    frames.append(frame())
                # Reuse the first frame palette so the logo stays stable.
                palette = frames[0].quantize(colors=16, dither=Image.Dither.NONE)
                frames = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in frames]
                frames[0].save(out / "reforge-bootsplash.gif", save_all=True,
                               append_images=frames[1:], duration=70, loop=0)
            time.sleep(max(0, settle - (time.monotonic() - started)))
            frame().save(out / name)
            print(f"[shots-reforge] wrote {name}", flush=True)
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


capture("/sbin/shot-splash", 14, "reforge-bootsplash.png", animated=True)
capture("/sbin/shot-splash-live", 14, "reforge-bootsplash-live.png")
capture("/sbin/shot-console", 75, "reforge-boot-console.png")
PY_CAPTURE
log "done."
