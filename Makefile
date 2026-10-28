BUILD := tools/build/build.sh
.PHONY: lint unit rootfs defconfig clean clean-artifacts kernel kernel-virt kernel-mainline smoke repro integration smoke-guppy tgz live-usb validate-loopback \
        run-from-mod \
        bsp-kernel-rebuild bsp-kernel-stock \
        qemu-kernel qemu-initramfs qemu-smoke qemu-all \
        qemu-stock-rootfs qemu-run qemu-update qemu-render qemu-stockui qemu-stockui-real qemu-guppy qemu-helix qemu-dinit qemu-live qemu-live-ota qemu-pid1-pivot qemu-stock-preinit qemu-mem qemu-ota shots-reforge vmtune-bench
# lint: shellcheck our own shell scripts (skips cleanly if shellcheck absent)
lint:              ; tools/lint/shellcheck.sh
# Single image: `make rootfs` builds the full ReForge stack (klipper + moonraker
# + mainsail + guppyscreen + zram). SCREEN_MODE gates the GUI at runtime.
rootfs:            ; $(BUILD) rootfs
defconfig:         ; $(BUILD) defconfig
clean:             ; $(BUILD) clean
# clean-artifacts: reclaim regenerable disk WITHOUT a full buildroot rebuild.
# Drops the qemu test images (.ext4/.img/.raw/.ppm — each re-baked by its harness
# in seconds) but KEEPS screenshots (*.png) + serial logs, the stale helixscreen
# package build tree (binary already installed in target/; buildroot re-extracts
# on demand), and the host ccache. Prints reclaimed size.
clean-artifacts:
	@before=$$(du -sb tests/qemu-harness/build build/output/build/helixscreen-* 2>/dev/null | awk '{s+=$$1} END{print s}'); \
	rm -f tests/qemu-harness/build/*.ext4 tests/qemu-harness/build/*.img \
	      tests/qemu-harness/build/*.raw tests/qemu-harness/build/*.raw.frame \
	      tests/qemu-harness/build/*.ppm 2>/dev/null; \
	rm -rf build/output/build/helixscreen-*/ 2>/dev/null; \
	echo "clean-artifacts: reclaimed ~$$(( before/1024/1024 )) MB (qemu images + stale helixscreen build); kept *.png + *serial.log"
# kernel / kernel-virt: build ONLY the Linux kernel via Buildroot (same vendor
# Tina source). `kernel` = the device stock config; `kernel-virt` = the qemu
# `-M virt` test config (ARCH_SUNXI off + virtio/drm/fb). Output: build/output/
# images/zImage. The standalone tools/build/build-bsp-kernel*.sh + build-test-
# kernel.sh stay the canonical references.
kernel:            ; $(BUILD) kernel
kernel-virt:       ; $(BUILD) kernel-virt
# Mainline 7.x board kernel for the T113 (allnoconfig + board fragment); size proxy, never
# flashed. Output: build/kernel-mainline/vmlinux. docs/research/kernel/2026-10-27-mainline-board-kernel.md
kernel-mainline:   ; tools/build/build-mainline-kernel.sh
smoke:             ; tests/smoke/smoke_rootfs.sh
repro:             ; tests/smoke/repro_check.sh
integration:       ; tests/smoke/chroot_integration.sh
# smoke-guppy: assert the GuppyScreen binary is present in the single image
smoke-guppy:       ; tests/smoke/smoke_guppy.sh
tgz:               ; packaging/build-tgz.sh
live-usb:          ; tools/release/build-live-usb.sh

# --- BSP kernel rebuild + diff against the on-device kernel ----------------
# Pure host-side: rebuild stock 5.4.61 from the pinned BSP submodule + the
# captured /proc/config.gz + the pinned GCC 9.5.0 toolchain. Compare against
# the kernel extracted from the golden eMMC dump. Output:
#   build/bsp-kernel-rebuild/artifacts/{Image.ours,Image.stock,vmlinux.ours,...}
# Findings: docs/research/2026-06-04-bsp-kernel-rebuild-findings.md
# Plan:     docs/plans/2026-06-04-bsp-kernel-rebuild-and-diff.md
bsp-kernel-rebuild: ; tools/build/build-bsp-kernel.sh

# --- byte-identical-attempt build (Linaro 5.3.1 + stock build path + patches) -
# Same kernel but compiled with the EXACT toolchain stock FF used and from the
# EXACT source path stock baked into __FILE__ strings. Applies the
# byte-identical-reproduction patches on top of the pinned BSP submodule and
# reverts them on exit (submodule stays clean).
# Output:  build/bsp-kernel-rebuild-stock/artifacts/Image.ours-linaro
# Findings: docs/research/2026-06-04-byte-identical-kernel-reproduction.md
# Prerequisite (run once):
#   FETCH_LINARO=1 ./vendor/fetch.sh
#   sudo mkdir -p /home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel
#   sudo chown -R $$USER /home/linux
#   sudo mount --bind $$(pwd)/vendor/kernels/tina-bsp-kernel \
#       /home/linux/work/hard_t113_s3/t113/T113/T113-Linux-Auto-v1.1/kernel/linux-5.4
bsp-kernel-stock:   ; tools/build/build-bsp-kernel-stock.sh
validate-loopback: ; sudo tests/loopback-install-test.sh
# run-from-mod: structural test of the self-contained mod/ + run-in-place model
run-from-mod:      ; tests/release/run-from-mod-test.sh
# unit: host unit + fuzz tests for the .shell helpers + the ff-update checker (no qemu, no root)
unit:              ; tests/release/lkg-unit-test.sh && tests/release/vmtune-unit-test.sh && tests/release/netup-unit-test.sh && tests/release/cloudblock-unit-test.sh && tests/release/dinit-services-test.sh && python3 tools/ota/test_check_ff_update.py && python3 tests/release/test_boot_eboard.py && python3 tests/release/test_moonraker_conf.py && python3 tests/release/test_banner.py && python3 tests/release/test_mcu_firmware.py && python3 tests/release/test_stock_boot_extract.py && python3 tests/release/test_stock_uboot.py && python3 tests/release/test_stock_kernel.py && python3 tests/release/test_stock_module.py && python3 tests/release/test_stock_kernel_compare.py && python3 tests/release/test_stock_build_id.py && python3 tests/release/test_stock_kernel_build_id_patch.py && python3 tests/release/test_stock_kernel_wrappers.py && python3 tests/release/test_stock_board_data.py && python3 tests/release/test_board_dts_selection.py && python3 tests/release/test_stock_optee.py && python3 tests/release/test_stock_boot0_packer.py && python3 tests/release/test_stock_boot0_runtime.py && python3 tests/release/test_stock_toc1_packer.py && tests/release/klipper-packages-test.sh

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
qemu-stockui-real: ; tests/qemu-harness/stockui-realklippy-test.sh
qemu-live:         ; tests/qemu-harness/live-mode-test.sh
qemu-live-ota:     ; tests/qemu-harness/live-ota-test.sh
# qemu-pid1-pivot: validate the reforge-init PID-1 + pivot_root flow
# (docs/boot.md §2 Option A, docs/research/2026-06-05-replacing-pid1.md §A1).
# Runs three sub-cases: happy / skip-cmdline / no-install.
qemu-pid1-pivot:   ; tests/qemu-harness/pid1-pivot-test.sh happy && \
                     tests/qemu-harness/pid1-pivot-test.sh skip-cmdline && \
                     tests/qemu-harness/pid1-pivot-test.sh no-install
# qemu-stock-preinit: prove docs/boot.md §2 row #6 is real — the stock
# /etc/inittab calls /etc/preinit as the FIRST sysinit entry. Test drops a
# tiny marker script at /etc/preinit on a stock-shaped eMMC, boots, asserts
# the marker hits the serial console BEFORE rcS markers.
qemu-stock-preinit: ; tests/qemu-harness/stock-preinit-test.sh
shots-reforge:     ; tests/qemu-harness/shots-reforge.sh
vmtune-bench:      ; tests/qemu-harness/vmtune-bench.sh

# --- full-stack "ready" rig: fake klippy so Moonraker reports klippy ready ----
# Swaps real klippy for a Moonraker-grade stand-in so the whole stack reaches
# "ready" with no MCU (Moonraker klippy_state:ready, GuppyScreen connects). Rig
# for Moonraker/OTA/API testing; the on-screen guppy capture is still blank (an
# LVGL-vs-virtio-gpu fb-flush limitation — see the script header). Rootless.
qemu-guppy:        ; tests/qemu-harness/guppy-render.sh
qemu-helix:        ; tests/qemu-harness/helix-render.sh
qemu-dinit:        ; tests/qemu-harness/dinit-boot-test.sh

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

# qemu-zipdetect: validate the 0002 reserved-updater ZIP-detect patch against the
# REAL built armv7 Moonraker, run on the target Python via qemu-user (no boot, no
# root). Skips cleanly if qemu-arm or the built target is absent.
qemu-zipdetect:    ; tests/qemu-harness/moonraker-zip-detect-test.sh

# qemu-klipper-ota: full qemu-system end-to-end of the RESERVED 'klipper' updater
# (0002). GATE = klipper configures as a ZIP updater (impossible pre-patch);
# version-bump download is best-effort. Skips cleanly if qemu/gvproxy/kernel absent.
qemu-klipper-ota:  ; tests/qemu-harness/ota-klipper-e2e-test.sh
