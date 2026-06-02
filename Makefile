BUILD := tools/build/build.sh
.PHONY: lint unit rootfs defconfig clean smoke repro integration smoke-guppy tgz live-usb validate-loopback \
        run-from-mod \
        qemu-kernel qemu-initramfs qemu-smoke qemu-all \
        qemu-stock-rootfs qemu-run qemu-update qemu-render qemu-stockui qemu-guppy qemu-live qemu-live-ota qemu-mem qemu-ota shots-reforge
# lint: shellcheck our own shell scripts (skips cleanly if shellcheck absent)
lint:              ; tools/lint/shellcheck.sh
# Single image: `make rootfs` builds the full ReForge stack (klipper + moonraker
# + mainsail + guppyscreen + zram). SCREEN_MODE gates the GUI at runtime.
rootfs:            ; $(BUILD) rootfs
defconfig:         ; $(BUILD) defconfig
clean:             ; $(BUILD) clean
smoke:             ; tests/smoke/smoke_rootfs.sh
repro:             ; tests/smoke/repro_check.sh
integration:       ; tests/smoke/chroot_integration.sh
# smoke-guppy: assert the GuppyScreen binary is present in the single image
smoke-guppy:       ; tests/smoke/smoke_guppy.sh
tgz:               ; packaging/build-tgz.sh
live-usb:          ; tools/release/build-live-usb.sh
validate-loopback: ; sudo tests/loopback-install-test.sh
# run-from-mod: structural test of the self-contained mod/ + run-in-place model
run-from-mod:      ; tests/release/run-from-mod-test.sh
# unit: host unit + fuzz tests for the .shell helpers (no qemu, no root)
unit:              ; tests/release/lkg-unit-test.sh && tests/release/vmtune-unit-test.sh

# --- P3 Task 4: qemu virt test kernel (vendor 5.4.61, ARCH_SUNXI=n, 800x480x32 fb) ---
# build zImage + initramfs + run smoke test
qemu-kernel:       ; tests/qemu-harness/build-test-kernel.sh kernel
qemu-initramfs:    ; tests/qemu-harness/build-test-kernel.sh initramfs
qemu-smoke:        ; tests/qemu-harness/build-test-kernel.sh smoke
qemu-all:          ; tests/qemu-harness/build-test-kernel.sh all

# --- P3 Task 5: extract stock rootfs (p6) from golden eMMC dump + run wrapper ---
# Extract mmcblk0p6 (~1.31 GB ext4) from tools/recovery/golden.img.gz.
# Fully rootless (sfdisk + dd + debugfs).  Output: tests/qemu-harness/build/stock-rootfs.ext4
qemu-stock-rootfs: ; tests/qemu-harness/extract-stock-rootfs.sh

# Generic qemu run helper: pass ROOT=<image-or-cpio> and optionally QEMU_ARGS=...
# Example: make qemu-run ROOT=tests/qemu-harness/build/stock-rootfs.ext4
# Example: make qemu-run ROOT=tests/qemu-harness/build/initramfs.cpio.gz --vnc
ROOT ?= tests/qemu-harness/build/initramfs.cpio.gz
qemu-run:          ; tests/qemu-harness/run-qemu.sh $(ROOT) $(QEMU_ARGS)

# --- P3 Task 6: qemu update-process test (install → ReForge boots) ---
# Needs sudo for loopback mount.  Timeout generous (qemu + python startup is slow).
qemu-update:       ; sudo tests/qemu-harness/update-process-test.sh

# --- P3 Task 7: GuppyScreen render test (800x480 fb, screendump non-blank) ---
# Boots ReForge with SCREEN_MODE=GUPPY under --vnc (virtio-gpu /dev/fb0) and
# asserts GuppyScreen draws a non-blank frame.  Fully rootless (mke2fs -d).
# Output: tests/qemu-harness/build/guppy-screenshot.ppm (gitignored)
qemu-render:       ; tests/qemu-harness/reforge-render-test.sh

# --- stock FlashForge UI render (firmwareExe, simulated MCU+klippy) ----------
# Boots the stock base under qemu with a simulated eboard MCU (/dev/ttyS1) and a
# klippy stand-in so firmwareExe leaves the "No detected eboard mcu." modal and
# reaches its home screen.  Fully ROOTLESS (no sudo): debugfs inject + GPT-offset
# slice + unprivileged qemu.  Output: build/stockui-home.ppm (gitignored).
qemu-stockui:      ; tests/qemu-harness/stockui-render.sh
qemu-live:         ; tests/qemu-harness/live-mode-test.sh
qemu-live-ota:     ; tests/qemu-harness/live-ota-test.sh
shots-reforge:     ; tests/qemu-harness/shots-reforge.sh

# --- full-stack "ready" rig: fake klippy so Moonraker reports klippy ready ----
# Swaps real klippy for a Moonraker-grade stand-in so the whole stack reaches
# "ready" with no MCU (Moonraker klippy_state:ready, GuppyScreen connects). Rig
# for Moonraker/OTA/API testing; the on-screen guppy capture is still blank (an
# LVGL-vs-virtio-gpu fb-flush limitation — see the script header). Rootless.
qemu-guppy:        ; tests/qemu-harness/guppy-render.sh

# --- memory probe: boot the full stack at -m 128, dump per-process Pss ---
# A/B runtime levers without rebuilding, e.g.:
#   make qemu-mem
#   make qemu-mem TWEAKS=oo
#   make qemu-mem TWEAKS=oo,arena1
ROOTFS_TAR ?=
qemu-mem:          ; TWEAKS="$(TWEAKS)" tests/qemu-harness/mem-probe.sh $(ROOTFS_TAR)

# --- OTA Task 6: qemu e2e Moonraker update + CRITICAL LKG/brick-rollback test ---
# Boots the ReForge rootfs under the virt kernel. Step 2 (network-free) proves
# brick-mitigation: a deliberately-broken mod is rolled back to last-known-good
# after N=3 failed boots. Step 1 (e2e Moonraker update) is best-effort. Fully
# rootless (mke2fs -d / debugfs), NO sudo.
qemu-ota:          ; tests/qemu-harness/ota-test.sh
