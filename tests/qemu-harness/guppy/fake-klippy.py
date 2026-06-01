#!/usr/bin/env python3
# fake-klippy.py — qemu-only Klipper API-server stand-in for the FULL ReForge
# stack (Moonraker + GuppyScreen), serving /tmp/klippy_uds.
#
# Unlike the stock-UI fake (which only has to satisfy firmwareExe's tiny direct
# query), Moonraker drives a real klippy handshake before it reports the printer
# "ready" to GuppyScreen:
#   info -> list_endpoints -> objects/list (needs virtual_sdcard/display_status/
#   pause_resume) -> gcode/subscribe_output -> objects/subscribe -> objects/query
#   (configfile) -> register_remote_method ...  then server:klippy_ready.
# This answers all of those with a canned READY printer + a rich object set, so
# Moonraker -> GuppyScreen paints its home screen with no real klippy/MCU.
#
# Framing: Klipper's API server delimits JSON messages with 0x03 (ETX).
import os, socket, json, time, threading

UDS = os.environ.get("KLIPPY_UDS", "/tmp/klippy_uds")
ETX = b"\x03"

# Endpoints Moonraker probes (klippy_apis.py). list_endpoints must advertise them.
ENDPOINTS = [
    "info", "emergency_stop", "list_endpoints", "gcode/subscribe_output",
    "gcode/script", "objects/subscribe", "objects/query", "objects/list",
    "register_remote_method", "gcode/help", "gcode/restart",
    "gcode/firmware_restart", "query_endstops/status", "pause_resume/pause",
    "pause_resume/resume", "pause_resume/cancel",
]

# Master object table. objects/query + objects/subscribe filter this to the
# requested names/fields; objects/list advertises the keys.
def objects():
    return {
        "webhooks": {"state": "ready", "state_message": "Printer is ready"},
        "configfile": {
            "config": {"virtual_sdcard": {"path": "/data"}},
            "settings": {"virtual_sdcard": {"path": "/data"}},
            "warnings": [], "save_config_pending": False,
            "save_config_pending_items": {},
        },
        "virtual_sdcard": {"is_active": False, "progress": 0.0,
                           "file_position": 0, "file_size": 0,
                           "file_path": None, "file_name": None},
        "display_status": {"progress": 0.0, "message": None},
        "pause_resume": {"is_paused": False},
        "idle_timeout": {"state": "Idle", "printing_time": 0.0},
        "print_stats": {"filename": "", "total_duration": 0.0,
                        "print_duration": 0.0, "filament_used": 0.0,
                        "state": "standby", "message": "",
                        "info": {"total_layer": None, "current_layer": None}},
        "toolhead": {
            "homed_axes": "", "axis_minimum": [0.0, 0.0, 0.0, 0.0],
            "axis_maximum": [220.0, 220.0, 220.0, 0.0],
            "position": [0.0, 0.0, 0.0, 0.0], "print_time": 0.0,
            "estimated_print_time": 0.0, "extruder": "extruder",
            "max_velocity": 500.0, "max_accel": 5000.0,
            "max_accel_to_decel": 2500.0, "square_corner_velocity": 5.0,
            "stalls": 0},
        "gcode_move": {"speed_factor": 1.0, "speed": 1500.0,
                       "extrude_factor": 1.0, "absolute_coordinates": True,
                       "absolute_extrude": True,
                       "homing_origin": [0.0, 0.0, 0.0, 0.0],
                       "position": [0.0, 0.0, 0.0, 0.0],
                       "gcode_position": [0.0, 0.0, 0.0, 0.0]},
        "extruder": {"temperature": 25.0, "target": 0.0, "power": 0.0,
                     "can_extrude": False, "pressure_advance": 0.0,
                     "smooth_time": 0.04},
        "heater_bed": {"temperature": 25.0, "target": 0.0, "power": 0.0},
        "fan": {"speed": 0.0, "rpm": None},
        "fan_generic fanM106": {"speed": 0.0, "rpm": None},
        "fan_generic chamber_fan": {"speed": 0.0, "rpm": None},
        "heaters": {"available_heaters": ["extruder", "heater_bed"],
                    "available_sensors": ["extruder", "heater_bed",
                                          "temperature_sensor weightValue",
                                          "temperature_sensor tvocValue"],
                    "available_monitors": []},
        "temperature_sensor weightValue": {"temperature": 0.0,
                                           "measured_min_temp": 0.0,
                                           "measured_max_temp": 0.0},
        "temperature_sensor tvocValue": {"temperature": 0.0,
                                         "measured_min_temp": 0.0,
                                         "measured_max_temp": 0.0},
        "filament_switch_sensor e0_sensor": {"filament_detected": True,
                                             "enabled": True},
        "gcode_button btn_power": {"state": "released"},
        "motion_report": {"live_position": [0.0, 0.0, 0.0, 0.0],
                          "live_velocity": 0.0, "live_extruder_velocity": 0.0},
        "system_stats": {"sysload": 0.0, "cputime": 0.0, "memavail": 65536},
    }


def info_result():
    return {
        "state": "ready", "state_message": "Printer is ready",
        "hostname": "reforge", "klipper_path": "/opt/klipper",
        "python_path": "/usr/bin/python3",
        "config_file": "/etc/reforge/printer.cfg",
        "software_version": "reforge-sim",
        "cpu_info": "4 core ARMv7", "error_detected": False,
    }


def status_for(params):
    # params.objects: {name: [fields] | None}. Return only requested names,
    # filtered to requested fields when a field list is given.
    want = (params or {}).get("objects", {}) or {}
    allobj = objects()
    out = {}
    for name, fields in want.items():
        if name not in allobj:
            out[name] = {}
            continue
        if fields:
            out[name] = {f: allobj[name][f] for f in fields if f in allobj[name]}
        else:
            out[name] = allobj[name]
    return {"eventtime": time.time(), "status": out}


def reply(req):
    m = req.get("method")
    rid = req.get("id")
    p = req.get("params", {})
    if m == "info":
        res = info_result()
    elif m == "list_endpoints":
        res = {"endpoints": ENDPOINTS}
    elif m == "objects/list":
        res = {"objects": list(objects().keys())}
    elif m in ("objects/query", "objects/subscribe"):
        res = status_for(p)
    else:
        # gcode/subscribe_output, register_remote_method, gcode/script,
        # emergency_stop, gcode/help, ... — ack with an empty result.
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
