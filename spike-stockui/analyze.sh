#!/usr/bin/env bash
# =============================================================================
# ReForge P3 Task 8: spike-stockui/analyze.sh
#
# Static analysis of firmwareExe — extracts:
#   - ELF metadata (file type, NEEDED libs, interpreter)
#   - klippy API socket path + protocol
#   - klippy JSON-RPC method strings (objects/query, gcode/*, etc.)
#   - FlashForge custom klippy objects/modules (the gap)
#   - Qt embedded display backend + environment requirements
#   - Launch arguments and environment variables
#
# Output: prints findings to stdout (pipe to REPORT.md or review interactively)
#
# Usage:
#   spike-stockui/analyze.sh
#   spike-stockui/analyze.sh 2>&1 | tee analyze-output.txt
#
# Requires: file, readelf, strings (binutils)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTED="${SCRIPT_DIR}/extracted"
FW_EXE="${EXTRACTED}/firmwareExe"

die() { echo "ERROR: $*" >&2; exit 1; }
h1()  { echo ""; echo "##############################################################################"; echo "## $*"; echo "##############################################################################"; }
h2()  { echo ""; echo "--- $* ---"; }

[ -f "${FW_EXE}" ] || die "firmwareExe not found at ${FW_EXE} — run extract.sh first."

echo "============================================================"
echo " firmwareExe Static Analysis"
echo " Source: ${FW_EXE}"
echo " Date  : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "============================================================"

# ---------------------------------------------------------------------------
h1 "1. ELF METADATA"
# ---------------------------------------------------------------------------
h2 "File type"
file "${FW_EXE}"

h2 "ELF header (arch/ABI)"
readelf -h "${FW_EXE}" 2>/dev/null | grep -E '(Class|Data|Version|OS/ABI|Machine|Flags)'

h2 "Dynamic interpreter"
readelf -l "${FW_EXE}" 2>/dev/null | grep -E 'interpreter|INTERP' | head -5

h2 "NEEDED shared libraries"
readelf -d "${FW_EXE}" 2>/dev/null | grep NEEDED | awk '{print $5}' | tr -d '[]' | sort | while read -r lib; do
    echo "  ${lib}"
done

# ---------------------------------------------------------------------------
h1 "2. KLIPPY API SOCKET + PROTOCOL"
# ---------------------------------------------------------------------------
h2 "Socket path candidates (/tmp/* , uds)"
strings "${FW_EXE}" | grep -E '(/tmp/[a-zA-Z0-9_]+|\.sock|uds)' | grep -v '(Bash\|curl\|http\|rtmp\|pid\|lock\|wpa)' | sort -u

h2 "Klipper startup detection"
strings "${FW_EXE}" | grep -iE '(klipper.*start|start.*klipper|start\.sh|readyKlipper|checkKlipper|pthreadCheck)' | grep -v '_ZN\|_ZTV\|_ZTI\|_ZTS' | sort -u

h2 "JSON-RPC methods used"
strings "${FW_EXE}" | grep -E '"method"' | sort -u

h2 "Full objects/query payload (the canonical klippy objects firmwareExe needs)"
strings "${FW_EXE}" | grep '"objects/query"' | head -5

h2 "gcode/script calls"
strings "${FW_EXE}" | grep '"gcode/script"' | head -10

h2 "Other API calls"
strings "${FW_EXE}" | grep -iE '(gcode/subscribe_output|gcode/restart|gcode/firmware_restart)' | sort -u

# ---------------------------------------------------------------------------
h1 "3. KLIPPY OBJECTS REQUIRED (from objects/query payload)"
# ---------------------------------------------------------------------------
h2 "Objects in the canonical status query"
strings "${FW_EXE}" | grep '"objects/query"' | python3 -c "
import sys, json, re
for line in sys.stdin:
    m = re.search(r'\"objects\":\s*(\{[^}]+\})', line)
    if m:
        try:
            objs = json.loads(m.group(1))
            for name, fields in sorted(objs.items()):
                print(f'  [{name}]  fields={fields}')
        except Exception as e:
            print(f'  parse error: {e}')
            print(f'  raw: {line[:200]}')
" 2>/dev/null

h2 "Config sections referenced in gcode/startup patterns"
strings "${FW_EXE}" | grep -E '^\[(temperature_sensor|fan_generic|filament_switch_sensor|gcode_button|heater_bed|extruder|toolhead|pause_resume|print_stats|virtual_sdcard|webhooks)' | sort -u

# ---------------------------------------------------------------------------
h1 "4. FLASHFORGE CUSTOM OBJECTS (the gap vs upstream klippy)"
# ---------------------------------------------------------------------------
h2 "weightValue references"
strings "${FW_EXE}" | grep -iE '(weightValue|weight.?sensor|load.?cell)' | grep -v '_ZN\|_ZT' | sort -u

h2 "tvocValue references"
strings "${FW_EXE}" | grep -iE '(tvocValue|tvoc)' | grep -v '_ZN\|_ZT\|\.png\|\.gif\|background' | sort -u

h2 "gcode_button btn_power references"
strings "${FW_EXE}" | grep -iE '(btn_power|gcode_button.btn)' | sort -u

h2 "QUERY_BUTTON check_level_pin references"
strings "${FW_EXE}" | grep -iE '(check_level_pin|QUERY_BUTTON)' | sort -u

h2 "Custom config sections (from printer.cfg includes)"
strings "${FW_EXE}" | grep -E '^\[(fan_generic (pcb_fan|internal_fan|external_fan|level_pin|fanM106|chamber_fan)|filament_switch_sensor e[01]_sensor)' | sort -u

h2 "SET_FAN_SPEED gcode commands (verify fan names)"
strings "${FW_EXE}" | grep -E '^SET_FAN_SPEED' | sort -u

h2 "Serial port references (eboard)"
strings "${FW_EXE}" | grep -E '(/dev/tty|bootserial|eboard)' | grep -v '_ZN\|_ZT' | sort -u

# ---------------------------------------------------------------------------
h1 "5. QT EMBEDDED DISPLAY REQUIREMENTS"
# ---------------------------------------------------------------------------
h2 "Qt display backend (from env.cfg)"
cat "${SCRIPT_DIR}/extracted/env.cfg" 2>/dev/null | grep -E '(QWS|QT|TSLIB|LD_PRELOAD|LD_LIBRARY)' | grep -v '^#' | head -30

h2 "Launch arguments (from ffstartup.cfg AppArgs)"
cat "${SCRIPT_DIR}/extracted/ffstartup.cfg" 2>/dev/null | grep -E '(AppArgs|AppName|EnvFile)'

h2 "Required devices"
echo "  /dev/fb0         — framebuffer (LinuxFB backend, 480×800 portrait)"
echo "  /dev/input/event0 — touchscreen (tslib calibration via TSLIB_TSDEVICE)"
echo ""
echo "  NOTE: env.cfg declares QT_QPA_PLATFORM=linuxfb:tty=/dev/fb0:size=480x800"
echo "  (device is 480 wide x 800 tall portrait, rotated by hardware)"
echo "  Our qemu virtio-gpu fb is 800x480 landscape — rotation mismatch."
echo "  QWS_DISPLAY=transformed:rot0:LinuxFB:... suggests no rotation applied,"
echo "  meaning the app was designed for a 480x800 physical screen."
echo "  If qemu fb is 800x480 the UI may render upside-down / clipped."

# ---------------------------------------------------------------------------
h1 "6. ADDITIONAL DEPENDENCIES"
# ---------------------------------------------------------------------------
h2 "NIM SDK (Netease IM — cloud chat SDK)"
strings "${FW_EXE}" | grep -iE '(nim_client|nim_subscribe|AppClient|appclient url)' | grep -v '_ZN\|_ZT' | sort -u | head -10
echo "  (libnim.so, libnim_chatroom.so = Netease IM cloud SDK for live camera/chat)"

h2 "RTMP / FFmpeg camera streaming"
strings "${FW_EXE}" | grep -E '(rtmp://|libav|ffmpeg|mjpg|:8080)' | grep -v '_ZN\|_ZT' | sort -u | head -10

h2 "SSL/Crypto (OpenSSL 1.0.x)"
readelf -d "${FW_EXE}" 2>/dev/null | grep NEEDED | grep -E '(ssl|crypto)' | awk '{print $5}' | tr -d '[]'
echo "  (requires OpenSSL 1.0.x — incompatible with modern 1.1/3.x default builds)"

# ---------------------------------------------------------------------------
h1 "7. KLIPPY SOCKET DISCOVERY MECHANISM"
# ---------------------------------------------------------------------------
h2 "Socket existence check"
strings "${FW_EXE}" | grep -E '/bin/ls /tmp/' | sort -u
echo "  firmwareExe does: /bin/ls /tmp/printer (probe) then connects to /tmp/uds"
echo "  The socket at /tmp/uds is created by klippy.py -a /tmp/uds"
echo "  (confirmed from stock start.sh: python3.7 klippy.py printer.cfg -l ... -a /tmp/uds)"

# ---------------------------------------------------------------------------
h1 "8. SYMBOL TABLE SUMMARY (key classes)"
# ---------------------------------------------------------------------------
h2 "Key C++ classes in symbol table"
nm "${FW_EXE}" 2>/dev/null | grep -iE '(MainWindow|SerialObject|AppClient|KlipperThread|WeightAdjust|PrintObject|CloudClient|PolarClient|FlashClient)' | grep ' T \| t ' | awk '{print $3}' | c++filt 2>/dev/null | grep '::' | sed 's/::.*//' | sort -u | head -20

echo ""
echo "============================================================"
echo " Analysis complete."
echo "============================================================"
