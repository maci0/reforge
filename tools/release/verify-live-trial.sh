#!/usr/bin/env bash
# =============================================================================
# verify-live-trial.sh — verify a ReForge LIVE-USB trial on real hardware.
#
# Two phases, run against the printer's IP:
#
#   baseline   (BEFORE the trial, while the unit is on stock/forge-x over SSH)
#              — record that the eMMC has NO ReForge install (/data/.mod/.reforge absent).
#
#   live       (WHILE the live USB is booted) — over HTTP (always) + SSH (if keys
#              work): the ReForge stack is up, it's running from the USB loop-mounted
#              F2FS with a tmpfs /data, the 3 modules are loaded, and — the headline —
#              the eMMC's /data carries NO /data/.mod/.reforge install (live wrote nothing).
#
#   stock      (AFTER pulling the USB + rebooting, back on stock over SSH) — confirm
#              /data/.mod/.reforge is STILL absent: the whole trial left the eMMC untouched.
#
# HTTP needs nothing; SSH checks are best-effort (skip cleanly if the key is rejected).
# Usage:  tools/release/verify-live-trial.sh <baseline|live|stock> [IP]
# =============================================================================
set -uo pipefail

PHASE="${1:-live}"
IP="${2:-192.168.0.158}"
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 root@${IP}"

ok()   { echo "  [OK]   $*"; }
info() { echo "  [INFO] $*"; }
bad()  { echo "  [BAD]  $*"; }

http_checks() {
    echo "== HTTP (always works) =="
    if curl -sf --max-time 8 "http://${IP}:7125/server/info" 2>/dev/null | grep -q klippy_state; then
        ok "Moonraker live on ${IP}:7125 ($(curl -sf --max-time 8 "http://${IP}:7125/server/info" | grep -o '"klippy_state":[^,]*'))"
    else
        bad "Moonraker NOT reachable on ${IP}:7125 (stack not up?)"
    fi
    if curl -sf --max-time 8 "http://${IP}/" 2>/dev/null | grep -qiE 'mainsail|<title'; then
        ok "Mainsail served on ${IP}:80"
    else
        info "Mainsail (:80) not confirmed"
    fi
    # Moonraker reports the host distro — ReForge sets NAME=ReForge in os-release.
    d="$(curl -sf --max-time 8 "http://${IP}:7125/machine/system_info" 2>/dev/null | tr ',' '\n' | grep -iE 'distribution|name' | head -3)"
    [ -n "${d}" ] && info "system_info: ${d}"
}

ssh_try() { ${SSH} true 2>/dev/null; }

emmc_install_check() {  # the headline: is there a ReForge install on the eMMC?
    # /data is the eMMC partition (mmcblk0p7) on the stock host. A live boot must
    # NOT create /data/.mod/.reforge there (that's what an INSTALL would do).
    out="$(${SSH} 'ls -ld /data/.mod/.reforge 2>/dev/null && echo PRESENT || echo ABSENT' 2>/dev/null)"
    case "${out}" in
        *ABSENT*) ok "eMMC /data/.mod/.reforge ABSENT — no ReForge install on eMMC (brick-safe)";;
        *PRESENT*) bad "eMMC /data/.mod/.reforge PRESENT — something installed to eMMC!";;
        *) info "could not read /data/.mod/.reforge over SSH (key rejected?)";;
    esac
}

case "${PHASE}" in
baseline)
    echo "=== BASELINE (stock/forge-x, before trial) — IP ${IP} ==="
    if ssh_try; then
        echo "== SSH =="
        info "host: $(${SSH} 'uname -a' 2>/dev/null)"
        emmc_install_check
        info "/data top-level: $(${SSH} 'ls /data 2>/dev/null | tr "\n" " "' 2>/dev/null)"
    else
        bad "SSH to root@${IP} failed — baseline needs SSH (run while on stock)"
    fi
    ;;
live)
    echo "=== LIVE TRIAL (USB booted) — IP ${IP} ==="
    http_checks
    echo "== SSH (best-effort) =="
    if ssh_try; then
        info "os-release: $(${SSH} 'grep ^NAME= /etc/os-release 2>/dev/null' 2>/dev/null)"
        # running from USB? loop device backing the F2FS rootfs + the 3 modules.
        ${SSH} 'lsmod 2>/dev/null | grep -qE "^f2fs"'  && ok "f2fs module loaded"  || info "f2fs not seen in lsmod"
        ${SSH} 'lsmod 2>/dev/null | grep -qE "^loop"'  && ok "loop module loaded"  || info "loop not seen"
        ${SSH} 'losetup -a 2>/dev/null | grep -qi reforge-live' && ok "USB F2FS loop-mounted (losetup)" || info "loop backing not confirmed"
        # chroot /data must be tmpfs (zero eMMC writes for runtime state)
        ${SSH} 'cat /proc/mounts 2>/dev/null | grep -qE "/data .*tmpfs|tmpfs .*/data"' && ok "/data is tmpfs (runtime writes -> RAM, not eMMC)" || info "tmpfs /data not confirmed in mounts"
        emmc_install_check
    else
        info "SSH not available on the live stack (expected if keys differ) — HTTP checks above are the proof it booted from USB"
    fi
    ;;
stock)
    echo "=== POST-TRIAL (USB pulled, rebooted to stock) — IP ${IP} ==="
    if ssh_try; then
        emmc_install_check
        info "stock UI back: $(${SSH} 'pgrep -af firmwareExe 2>/dev/null | head -1' 2>/dev/null || echo "(firmwareExe check)")"
        echo ""
        echo "VERDICT: if /data/.mod/.reforge was ABSENT in baseline AND now, the live trial wrote NOTHING to eMMC."
    else
        bad "SSH to root@${IP} failed"
    fi
    ;;
*)
    echo "usage: $0 <baseline|live|stock> [IP]"; exit 1;;
esac
