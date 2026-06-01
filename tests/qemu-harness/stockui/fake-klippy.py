#!/opt/Python-3.7.11/bin/python3.7
# fake-klippy.py — qemu-only minimal Klipper API-server stand-in on /tmp/uds.
#
# firmwareExe connects to klippy's unix API socket (-a /tmp/uds) and polls printer
# state. This serves the 0x03-terminated JSON-RPC subset it calls and reports a
# "ready" printer with canned temps, so readyKlipper() succeeds without a real
# klippy/MCU. Pair with mcu-sim.py (which satisfies the separate serial gate).
#
# Methods firmwareExe uses (all standard upstream Klipper): objects/query,
# objects/list, gcode/script, gcode/subscribe_output, gcode/restart,
# gcode/firmware_restart, info.
import os, socket, json, time, threading

UDS = "/tmp/uds"
ETX = b"\x03"


def objs():
    return {
        "virtual_sdcard": {"is_active": False, "progress": 0.0,
                           "file_position": 0, "file_size": 0},
        "pause_resume": {"is_paused": False},
        "fan_generic fanM106": {"speed": 0.0},
        "fan_generic chamber_fan": {"speed": 0.0},
        "print_stats": {"filament_used": 0.0, "state": "standby"},
        "toolhead": {"homed_axes": ""},
        "gcode_move": {"gcode_position": [0, 0, 0, 0], "speed": 0.0,
                       "absolute_extrude": True},
        "webhooks": {"state": "ready", "state_message": "Printer is ready"},
        "filament_switch_sensor e0_sensor": {"filament_detected": True},
        "extruder": {"temperature": 25.0, "target": 0.0},
        "heater_bed": {"temperature": 25.0, "target": 0.0},
        "temperature_sensor weightValue": {"temperature": 0.0},
        "temperature_sensor tvocValue": {"temperature": 0.0},
        "gcode_button btn_power": {"state": "released"},
    }


def reply(req):
    m = req.get("method")
    rid = req.get("id")
    if m == "objects/query":
        res = {"eventtime": time.time(), "status": objs()}
    elif m == "objects/list":
        res = {"objects": list(objs().keys())}
    elif m == "info":
        res = {"state": "ready", "state_message": "Printer is ready",
               "klipper_path": "/opt/klipper", "config_file": "/opt/config/printer.cfg"}
    else:
        res = {}
    return {"id": rid, "result": res} if rid is not None else {"params": res}


def handle(conn):
    buf = b""
    while True:
        try:
            data = conn.recv(4096)
        except OSError:
            break
        if not data:
            break
        buf += data
        while ETX in buf:
            raw, buf = buf.split(ETX, 1)
            if not raw.strip():
                continue
            try:
                req = json.loads(raw.decode())
            except Exception:
                continue
            try:
                conn.sendall(json.dumps(reply(req)).encode() + ETX)
            except OSError:
                return


def main():
    try:
        os.remove(UDS)
    except OSError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(UDS)
    s.listen(5)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
