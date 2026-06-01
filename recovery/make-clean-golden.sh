#!/usr/bin/env bash
# =============================================================================
# make-clean-golden.sh  —  derive a PURE STOCK golden eMMC image (forge-x removed)
#                          from the existing captured golden dump.
#
# Works ENTIRELY OFFLINE on a loop-mounted copy of the dump.
# Never touches the live printer (no SSH, no /dev/mmcblk0).
#
# Usage:
#   sudo ./recovery/make-clean-golden.sh
#
# Outputs (all gitignored):
#   recovery/.work/golden-raw.img           7.3 GB scratch raw (deleted at end)
#   recovery/golden-stock-clean.img.gz      cleaned + recompressed golden
#   validation/qemu-harness/build/stock-clean-rootfs.ext4   cleaned p6 for qemu
#
# The original golden-kunos-*.img.gz is NEVER touched.
#
# What is removed — drawn verbatim from forge-x's uninstall.sh + S00init +
# boot/boot.sh (which together document EXACTLY what the installer places):
#
# On p6 (stock rootfs mmcblk0p6):
#   /etc/init.d/S00init          symlink → /opt/config/mod/.shell/S00init
#   /etc/init.d/S00fix           runtime state file (boot.sh)
#   /etc/init.d/S55boot          symlink → /opt/config/mod/.shell/S55boot
#   /etc/init.d/S60dropbear      symlink/copy (dropbear SSH daemon)
#   /etc/init.d/S98camera        symlink
#   /etc/init.d/S98zssh          symlink
#   /etc/init.d/S99root          symlink
#   /etc/init.d/K99root          symlink
#   /etc/init.d/S99moon          forge-x removes at install (harmless double-rm)
#   /etc/init.d/K99moon          ditto
#   /etc/init.d/S50sshd          dropbear (hard-remove mode)
#   /etc/init.d/S55date          dropbear helper (hard-remove mode)
#   /bin/dropbearmulti /bin/dropbear /bin/dropbearkey /bin/scp
#   /etc/dropbear/               dropbear host keys
#   /opt/config/mod/             mod source tree
#   /opt/config/mod_data/        mod runtime data (hard-remove mode)
#   /opt/bin /opt/etc /opt/home /opt/lib /opt/libexec /opt/root /opt/sbin
#   /opt/share /opt/tmp /opt/usr /opt/var   entware directories
#   /root/.profile /root/.zshrc  zsh setup (forge-x replaces/creates these)
#   /root/printer_data/          klipper printer_data symlink tree
#   /root/.oh-my-zsh/            bind-mount point (empty after unmount)
#   /opt/klipper/klippy/extras/* forge-x klipper plugin symlinks
#   /opt/klipper/klippy/**/*.bak klipper patch backups → restore originals
#   /usr/bin/audio /usr/bin/audio_midi.sh
#   /usr/lib/python3.7/site-packages/audio.py
#   /usr/lib/python3.7/site-packages/mido/
#   /opt/klipper/klippy/extras/gcode_shell_command.py
#   /usr/sbin/fake-hwclock        hwclock symlink in chroot mountpoint
#   /etc/motd                     emptied by forge-x; restore empty (noop)
#   /etc/hosts                    forge-x appends block entries; restore stock 2-line
#
# On p7 (/data  mmcblk0p7):
#   /data/.mod/                  entire forge-x chroot + swap + mod data
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
log()  { echo "[make-clean-golden] $*"; }
die()  { echo "[make-clean-golden] ERROR: $*" >&2; exit 1; }
warn() { echo "[make-clean-golden] WARN:  $*" >&2; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Must run as root (sudo). Loop-mount and e2fsck require root."
    fi
}

# ---------------------------------------------------------------------------
# paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK_DIR="$SCRIPT_DIR/.work"
GOLDEN_SRC="$(ls "$SCRIPT_DIR"/golden-kunos-*.img.gz 2>/dev/null | sort | head -1)"
GOLDEN_RAW="$WORK_DIR/golden-raw.img"
GOLDEN_CLEAN="$SCRIPT_DIR/golden-stock-clean.img.gz"
QEMU_ROOTFS="$REPO_ROOT/validation/qemu-harness/build/stock-clean-rootfs.ext4"

MNT_P6="$WORK_DIR/mnt-p6"
MNT_P7="$WORK_DIR/mnt-p7"

LOOP_DEV=""      # filled in by setup_loop
MOUNTED_P6=0
MOUNTED_P7=0

# ---------------------------------------------------------------------------
# cleanup trap  — unmounts and detaches loop on exit (even on error)
# ---------------------------------------------------------------------------
cleanup() {
    local rc=$?
    log "Cleanup (exit code=$rc)..."

    if [ "$MOUNTED_P7" -eq 1 ]; then
        log "Unmounting p7..."
        umount "$MNT_P7" 2>/dev/null || umount -l "$MNT_P7" 2>/dev/null || true
        MOUNTED_P7=0
    fi
    if [ "$MOUNTED_P6" -eq 1 ]; then
        log "Unmounting p6..."
        umount "$MNT_P6" 2>/dev/null || umount -l "$MNT_P6" 2>/dev/null || true
        MOUNTED_P6=0
    fi
    if [ -n "$LOOP_DEV" ]; then
        log "Detaching loop $LOOP_DEV..."
        losetup -d "$LOOP_DEV" 2>/dev/null || true
        LOOP_DEV=""
    fi

    # Leave GOLDEN_RAW in place only on error so the operator can inspect;
    # on clean success it will already have been deleted by the script body.
    if [ $rc -eq 0 ]; then
        log "Done (success)."
    else
        warn "Exiting with error. Scratch raw left at $GOLDEN_RAW (if it exists) for inspection."
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 0 — pre-flight
# ---------------------------------------------------------------------------
pre_flight() {
    log "=== Step 0: Pre-flight checks ==="
    check_root

    [ -n "$GOLDEN_SRC" ] || die "No golden-kunos-*.img.gz found in $SCRIPT_DIR"
    log "Source golden: $GOLDEN_SRC"

    command -v losetup  >/dev/null || die "losetup not found"
    command -v e2fsck   >/dev/null || die "e2fsck not found"
    command -v mount    >/dev/null || die "mount not found"
    command -v gzip     >/dev/null || die "gzip not found"

    # Need ~16 GB free: 7.3 GB raw + 7.3 GB recompressed + a little for p6 ext4
    local avail_kb
    avail_kb=$(df --output=avail "$SCRIPT_DIR" | tail -1)
    local avail_gb=$(( avail_kb / 1024 / 1024 ))
    log "Available disk: ~${avail_gb} GB"
    [ "$avail_gb" -ge 10 ] || die "Need >= 10 GB free, have ${avail_gb} GB"

    mkdir -p "$WORK_DIR" "$MNT_P6" "$MNT_P7"
    mkdir -p "$(dirname "$QEMU_ROOTFS")"

    log "Pre-flight OK."
}

# ---------------------------------------------------------------------------
# Step 1 — decompress golden → scratch raw
# ---------------------------------------------------------------------------
decompress_golden() {
    log "=== Step 1: Decompressing golden → $GOLDEN_RAW ==="
    if [ -f "$GOLDEN_RAW" ]; then
        log "Scratch raw already exists — skipping decompress (remove it to redo)."
    else
        log "Decompressing (this will take a few minutes for 7.3 GB)..."
        gzip -dc "$GOLDEN_SRC" > "$GOLDEN_RAW"
    fi
    local size
    size=$(stat --printf="%s" "$GOLDEN_RAW")
    log "Raw image size: $size bytes ($(( size / 1024 / 1024 / 1024 )) GB)"
}

# ---------------------------------------------------------------------------
# Step 2 — attach GPT image as loop device
# ---------------------------------------------------------------------------
setup_loop() {
    log "=== Step 2: Attaching loop device (GPT-aware) ==="
    LOOP_DEV=$(losetup -fP --show "$GOLDEN_RAW")
    log "Loop device: $LOOP_DEV"
    log "Partitions:"
    ls "${LOOP_DEV}"p* 2>/dev/null || lsblk "$LOOP_DEV"
}

# ---------------------------------------------------------------------------
# Step 3 — e2fsck + mount p6 and p7
# ---------------------------------------------------------------------------
mount_partitions() {
    log "=== Step 3: e2fsck + mount p6 and p7 ==="
    local p6="${LOOP_DEV}p6"
    local p7="${LOOP_DEV}p7"

    log "e2fsck -y $p6 (journal replay / fix)..."
    e2fsck -y "$p6" 2>&1 || true   # e2fsck exits non-zero even when it fixed things
    log "e2fsck -y $p7 ..."
    e2fsck -y "$p7" 2>&1 || true

    log "Mounting p6 → $MNT_P6 ..."
    mount -o rw "$p6" "$MNT_P6"
    MOUNTED_P6=1

    log "Mounting p7 → $MNT_P7 ..."
    mount -o rw "$p7" "$MNT_P7"
    MOUNTED_P7=1

    log "Mounts OK."
}

# ---------------------------------------------------------------------------
# Step 4 — remove forge-x
# Guided by forge-x uninstall.sh + S00init (what it ln -fs'd) + boot/boot.sh
# Hard-remove mode is applied (we want a clean stock golden, not --soft).
# ---------------------------------------------------------------------------
remove_forgex() {
    log "=== Step 4: Removing forge-x artifacts ==="
    local P6="$MNT_P6"
    local P7="$MNT_P7"

    # --- p7: remove the entire forge-x chroot + mod data ---
    log "  [p7] Removing /data/.mod/ ..."
    rm -rf "${P7}/.mod"

    # --- p6: init.d hooks (from uninstall.sh lines 104-112) ---
    log "  [p6] Removing init.d forge-x hooks ..."
    for svc in S00fix S00init S55boot S60dropbear S98camera S98zssh S99root K99root S99moon K99moon S50sshd S55date; do
        if [ -e "${P6}/etc/init.d/${svc}" ] || [ -L "${P6}/etc/init.d/${svc}" ]; then
            log "       rm /etc/init.d/${svc}"
            rm -f "${P6}/etc/init.d/${svc}"
        fi
    done

    # --- p6: zsh root config files (from uninstall.sh lines 117-118) ---
    log "  [p6] Removing forge-x zsh root configs ..."
    chattr -i "${P6}/root/.profile" 2>/dev/null || true
    chattr -i "${P6}/root/.zshrc"   2>/dev/null || true
    rm -rf "${P6}/root/.profile"
    rm -rf "${P6}/root/.zshrc"
    # oh-my-zsh dir is a mount-point / might be empty; remove if present
    [ -d "${P6}/root/.oh-my-zsh" ] && { chattr -R -i "${P6}/root/.oh-my-zsh" 2>/dev/null || true; rm -rf "${P6}/root/.oh-my-zsh"; } || true

    # --- p6: /etc/motd — forge-x fills it; restore to empty (stock) ---
    log "  [p6] Restoring /etc/motd to empty ..."
    printf "" > "${P6}/etc/motd"

    # --- p6: entware dirs (from uninstall.sh lines 121-132) ---
    log "  [p6] Removing entware directories under /opt/ ..."
    for d in bin etc home libexec root sbin share tmp usr var; do
        if [ -e "${P6}/opt/$d" ] || [ -L "${P6}/opt/$d" ]; then
            log "       rm -rf /opt/$d"
            chattr -R -i "${P6}/opt/$d" 2>/dev/null || true
            rm -rf "${P6}/opt/$d"
        fi
    done
    # /opt/lib: forge-x links /opt/lib/14.2.0 (runtime) — if /opt/lib exists
    # as a directory and only has 14.2.0 in it, remove it; otherwise remove just the symlink.
    if [ -L "${P6}/opt/lib" ]; then
        log "       rm /opt/lib (symlink)"
        rm -f "${P6}/opt/lib"
    elif [ -d "${P6}/opt/lib" ]; then
        rm -f "${P6}/opt/lib/14.2.0" 2>/dev/null || true
        # Only remove the dir if now empty (leave stock /opt/lib if non-empty)
        rmdir "${P6}/opt/lib" 2>/dev/null || true
    fi

    # --- p6: mod source + runtime data (uninstall.sh lines 149-151) ---
    # forge-x marks many of its files immutable (chattr +i) on the ext4 filesystem.
    # We must strip the immutable bit before rm -rf will work.
    log "  [p6] Stripping immutable attributes from /opt/config/mod/ ..."
    chattr -R -i "${P6}/opt/config/mod" 2>/dev/null || true
    log "  [p6] Removing /opt/config/mod/ and /opt/config/mod_data/ ..."
    rm -rf "${P6}/opt/config/mod"
    chattr -R -i "${P6}/opt/config/mod_data" 2>/dev/null || true
    rm -rf "${P6}/opt/config/mod_data"

    # --- p6: root/printer_data symlink tree (uninstall.sh line 150) ---
    log "  [p6] Removing /root/printer_data/ ..."
    chattr -R -i "${P6}/root/printer_data" 2>/dev/null || true
    rm -rf "${P6}/root/printer_data"

    # --- p6: dropbear binaries (hard remove — uninstall.sh lines 136-138) ---
    log "  [p6] Removing dropbear binaries ..."
    for f in "${P6}/bin/dropbearmulti" "${P6}/bin/dropbear" "${P6}/bin/dropbearkey" "${P6}/bin/scp"; do
        chattr -i "$f" 2>/dev/null || true
    done
    rm -f "${P6}/bin/dropbearmulti" "${P6}/bin/dropbear" "${P6}/bin/dropbearkey" "${P6}/bin/scp"
    chattr -R -i "${P6}/etc/dropbear" 2>/dev/null || true
    rm -rf "${P6}/etc/dropbear"

    # --- p6: audio utilities (hard remove — uninstall.sh lines 140-141) ---
    log "  [p6] Removing forge-x audio utilities ..."
    for f in \
        "${P6}/usr/bin/audio" \
        "${P6}/usr/bin/audio_midi.sh" \
        "${P6}/usr/lib/python3.7/site-packages/audio.py" \
        "${P6}/opt/klipper/klippy/extras/gcode_shell_command.py"; do
        chattr -i "$f" 2>/dev/null || true
    done
    rm -f "${P6}/usr/bin/audio"
    rm -f "${P6}/usr/bin/audio_midi.sh"
    rm -f "${P6}/usr/lib/python3.7/site-packages/audio.py"
    rm -f "${P6}/opt/klipper/klippy/extras/gcode_shell_command.py"
    chattr -R -i "${P6}/usr/lib/python3.7/site-packages/mido" 2>/dev/null || true
    rm -rf "${P6}/usr/lib/python3.7/site-packages/mido"

    # --- p6: klipper patches — restore .bak files, remove plugin symlinks ---
    # forge-x apply_klipper_patches: backs up originals as .bak, links patches;
    # revert_klipper_patches: restores .bak → original, removes plugin symlinks
    log "  [p6] Reverting klipper patches ..."
    local klipper_klippy="${P6}/opt/klipper/klippy"
    if [ -d "$klipper_klippy" ]; then
        # Restore patched files from .bak
        find "$klipper_klippy" -name "*.bak" | while read -r bak; do
            local orig="${bak%.bak}"
            log "       restore $(basename "$orig") from .bak"
            mv -f "$bak" "$orig"
        done
        # Remove klipper plugin symlinks added by forge-x (extras/ symlinks → forge-x source)
        find "$klipper_klippy/extras" -type l 2>/dev/null | while read -r lnk; do
            local target
            target=$(readlink "$lnk")
            # Only remove if it points into /opt/config/mod (forge-x) territory
            if echo "$target" | grep -q "opt/config/mod\|forge-x"; then
                log "       rm plugin symlink: $(basename "$lnk")"
                rm -f "$lnk"
            fi
        done
    fi

    # --- p6: /usr/sbin/fake-hwclock symlink (forge-x sets in chroot, may be on p6) ---
    if [ -L "${P6}/usr/sbin/fake-hwclock" ]; then
        local fhw_target
        fhw_target=$(readlink "${P6}/usr/sbin/fake-hwclock")
        if echo "$fhw_target" | grep -q "opt/config/mod"; then
            log "  [p6] Removing forge-x fake-hwclock symlink ..."
            rm -f "${P6}/usr/sbin/fake-hwclock"
        fi
    fi

    # --- p6: /etc/hosts — restore stock 2-line version ---
    # forge-x appends many 127.0.0.1 block entries; remove them all.
    log "  [p6] Restoring /etc/hosts to stock (removing forge-x block entries) ..."
    if [ -f "${P6}/etc/hosts" ]; then
        # Stock /etc/hosts is exactly:
        #   127.0.0.1       localhost
        #   127.0.1.1       kunos
        # Remove any line that maps 127.0.0.1 to something other than "localhost"
        # (forge-x uses "sed -i '2 i\127.0.0.1 <host>'" so extras are in middle/top)
        {
            grep -E "^127\.0\.0\.1[[:space:]]+localhost$" "${P6}/etc/hosts" || echo "127.0.0.1       localhost"
            grep -E "^127\.0\.1\.1[[:space:]]+kunos$" "${P6}/etc/hosts"     || echo "127.0.1.1       kunos"
        } > "${P6}/etc/hosts.stock"
        mv -f "${P6}/etc/hosts.stock" "${P6}/etc/hosts"
    fi

    # --- p6: THIS_IS_NOT_YOUR_ROOT_FILESYSTEM sentinel ---
    # This sentinel is mentioned as a sign forge-x is installed; it may live
    # inside /data/.mod/.forge-x (the chroot's root) on p7 — already removed above.
    # If it also appears on p6, remove it.
    if [ -f "${P6}/THIS_IS_NOT_YOUR_ROOT_FILESYSTEM" ]; then
        log "  [p6] Removing THIS_IS_NOT_YOUR_ROOT_FILESYSTEM sentinel ..."
        rm -f "${P6}/THIS_IS_NOT_YOUR_ROOT_FILESYSTEM"
    fi

    log "  forge-x removal complete."
}

# ---------------------------------------------------------------------------
# Step 5 — verify cleaned state
# ---------------------------------------------------------------------------
verify_clean() {
    log "=== Step 5: Verification ==="
    local P6="$MNT_P6"
    local P7="$MNT_P7"
    local PASS=0
    local FAIL=0

    check_gone() {
        local label="$1"; local path="$2"
        if [ -e "$path" ] || [ -L "$path" ]; then
            echo "  FAIL  $label: still present at $path"
            FAIL=$(( FAIL + 1 ))
        else
            echo "  PASS  $label: gone"
            PASS=$(( PASS + 1 ))
        fi
    }
    check_present() {
        local label="$1"; local path="$2"
        if [ -e "$path" ] || [ -L "$path" ]; then
            echo "  PASS  $label: present"
            PASS=$(( PASS + 1 ))
        else
            echo "  FAIL  $label: MISSING at $path"
            FAIL=$(( FAIL + 1 ))
        fi
    }
    check_no_forgex_symlink() {
        local label="$1"; local path="$2"
        if [ -L "$path" ]; then
            local tgt; tgt=$(readlink "$path")
            if echo "$tgt" | grep -q "opt/config/mod\|forge-x"; then
                echo "  FAIL  $label: forge-x symlink still present → $tgt"
                FAIL=$(( FAIL + 1 ))
            else
                echo "  PASS  $label: not a forge-x symlink"
                PASS=$(( PASS + 1 ))
            fi
        elif [ -f "$path" ]; then
            # Regular file (e.g. dropbear S60dropbear copy from --soft mode) — check content
            if grep -q "forge-x\|mod/.shell" "$path" 2>/dev/null; then
                echo "  FAIL  $label: forge-x content still present"
                FAIL=$(( FAIL + 1 ))
            else
                echo "  PASS  $label: present but not forge-x content"
                PASS=$(( PASS + 1 ))
            fi
        else
            echo "  PASS  $label: gone"
            PASS=$(( PASS + 1 ))
        fi
    }

    # p7 checks
    check_gone        "/data/.mod (forge-x chroot)"       "${P7}/.mod"

    # p6 checks — sentinel
    check_gone        "THIS_IS_NOT_YOUR_ROOT_FILESYSTEM"   "${P6}/THIS_IS_NOT_YOUR_ROOT_FILESYSTEM"

    # p6 checks — init.d hooks
    check_gone        "/etc/init.d/S00init"                "${P6}/etc/init.d/S00init"
    check_gone        "/etc/init.d/S00fix"                 "${P6}/etc/init.d/S00fix"
    check_gone        "/etc/init.d/S55boot"                "${P6}/etc/init.d/S55boot"
    check_no_forgex_symlink "/etc/init.d/S60dropbear"      "${P6}/etc/init.d/S60dropbear"
    check_gone        "/etc/init.d/S98camera"              "${P6}/etc/init.d/S98camera"
    check_gone        "/etc/init.d/S98zssh"                "${P6}/etc/init.d/S98zssh"
    check_gone        "/etc/init.d/S99root"                "${P6}/etc/init.d/S99root"
    check_gone        "/etc/init.d/K99root"                "${P6}/etc/init.d/K99root"

    # p6 checks — mod tree
    check_gone        "/opt/config/mod/"                   "${P6}/opt/config/mod"
    check_gone        "/opt/config/mod_data/"              "${P6}/opt/config/mod_data"

    # p6 checks — stock system still intact
    # firmwareExe can live at several paths depending on firmware version
    local fwexe_found=0
    for fwpath in \
        "${P6}/opt/PROGRAM/firmwareExe" \
        "${P6}/opt/PROGRAM/ffstartup-arm" \
        "${P6}/opt/PROGRAM/ffstartup"; do
        if [ -f "$fwpath" ] || [ -L "$fwpath" ]; then
            echo "  PASS  stock firmwareExe: present at $fwpath"
            PASS=$(( PASS + 1 ))
            fwexe_found=1
            break
        fi
    done
    if [ "$fwexe_found" -eq 0 ]; then
        echo "  FAIL  stock firmwareExe: not found in /opt/PROGRAM/"
        FAIL=$(( FAIL + 1 ))
    fi

    # p6 check — /etc/init.d has no remaining forge-x S00init (double-check by grep)
    if grep -rl "forge-x\|mod/.shell\|opt/config/mod" "${P6}/etc/init.d/" 2>/dev/null | grep -qv ".swp"; then
        echo "  FAIL  /etc/init.d/ still contains forge-x references:"
        grep -rl "forge-x\|mod/.shell\|opt/config/mod" "${P6}/etc/init.d/" 2>/dev/null | sed 's/^/       /'
        FAIL=$(( FAIL + 1 ))
    else
        echo "  PASS  /etc/init.d/: no forge-x references"
        PASS=$(( PASS + 1 ))
    fi

    # Hosts sanity
    local hostlines
    hostlines=$(wc -l < "${P6}/etc/hosts")
    if [ "$hostlines" -le 5 ]; then
        echo "  PASS  /etc/hosts: looks clean ($hostlines lines)"
        PASS=$(( PASS + 1 ))
    else
        echo "  WARN  /etc/hosts: $hostlines lines — may still contain block entries"
        # Not a hard fail — print them
        cat "${P6}/etc/hosts"
    fi

    echo ""
    echo "  Verification: PASS=$PASS  FAIL=$FAIL"
    if [ "$FAIL" -gt 0 ]; then
        die "Verification FAILED ($FAIL checks failed). See above."
    fi
    log "All checks PASSED."
}

# ---------------------------------------------------------------------------
# Step 6 — unmount, extract p6, recompress, cleanup scratch raw
# ---------------------------------------------------------------------------
finalize() {
    log "=== Step 6: Finalize — extract p6, recompress, cleanup ==="
    local P6="${LOOP_DEV}p6"

    # Extract cleaned p6 for qemu harness (done while still mounted)
    log "Extracting cleaned p6 → $QEMU_ROOTFS ..."
    # Copy the raw partition bytes directly from the loop partition
    # p6 is 1310720 * 1024 = 1.3 GB  (partition size in blocks from partitions-*.txt)
    dd if="${P6}" of="$QEMU_ROOTFS" bs=4M conv=fsync status=progress 2>&1
    log "p6 ext4 extracted: $(stat --printf='%s' "$QEMU_ROOTFS") bytes"

    # Unmount
    log "Unmounting p7 ..."
    umount "$MNT_P7"
    MOUNTED_P7=0
    log "Unmounting p6 ..."
    umount "$MNT_P6"
    MOUNTED_P6=0

    # Detach loop
    log "Detaching $LOOP_DEV ..."
    losetup -d "$LOOP_DEV"
    LOOP_DEV=""

    # Recompress the cleaned raw
    log "Recompressing → $GOLDEN_CLEAN (this will take several minutes) ..."
    gzip -9 -c "$GOLDEN_RAW" > "$GOLDEN_CLEAN"
    local csize
    csize=$(stat --printf="%s" "$GOLDEN_CLEAN")
    log "Cleaned golden size: $csize bytes ($(( csize / 1024 / 1024 )) MB compressed)"

    # Delete scratch raw
    log "Deleting scratch raw $GOLDEN_RAW ..."
    rm -f "$GOLDEN_RAW"

    log "Cleaned golden: $GOLDEN_CLEAN"
    log "Cleaned p6 for qemu: $QEMU_ROOTFS"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    log "=================================================="
    log "make-clean-golden.sh — forge-x removal from golden"
    log "Source: $GOLDEN_SRC"
    log "=================================================="

    pre_flight
    decompress_golden
    setup_loop
    mount_partitions
    remove_forgex
    verify_clean
    finalize

    log "=================================================="
    log "SUCCESS — clean stock golden produced."
    log "  Cleaned golden:  $GOLDEN_CLEAN"
    log "  Cleaned p6/qemu: $QEMU_ROOTFS"
    log "  Original golden: $GOLDEN_SRC  (UNTOUCHED)"
    log "=================================================="
}

main "$@"
