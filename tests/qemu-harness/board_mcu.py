#!/usr/bin/env python3
# Klipper-protocol stand-in for the Adventurer 5M's two N32G455 boards.
#
# The main board is /dev/ttyS5 and speaks Klipper immediately. The toolhead
# (eboard) is /dev/ttyS1: its bootloader prints "Ready." until the host sends
# "A", answers 0x06, then speaks Klipper at the same node. Both advertise the
# STM32-style pin names in printer.base.cfg, stream room-temperature ADC and
# thermocouple samples, and answer TMC2209 UART reads so the stock config can
# reach "ready". This is the wire protocol those boards present to Klippy. It
# does not step motors or heat a bed.
#
# Python 3.7 (the guest interpreter). No third-party modules.

from __future__ import print_function

import json
import os
import select
import sys
import time
import tty
import zlib

MESSAGE_MIN = 5
MESSAGE_MAX = 64
MESSAGE_HEADER = 2
MESSAGE_TRAILER = 3
MESSAGE_DEST = 0x10
MESSAGE_SEQ_MASK = 0x0F
MESSAGE_SYNC = 0x7E
CLOCK_FREQ = 144000000
ADC_MAX = 4095
# Generic 3950, 4.7k pullup, ~25 C: R / (R + pullup).
ROOM_FRACTION = 100000.0 / (100000.0 + 4700.0)

# Command and response ids. 0 and 1 are Klipper's fixed identify pair.
# Formats match the forge-x Klippy build (lookup_command strings and the
# parameter names create_command parses out of config lines).
COMMANDS = [
    ("identify offset=%u count=%c", 1),
    ("get_uptime", 4),
    ("get_clock", 5),
    ("get_config", 7),
    ("allocate_oids count=%c", 8),
    ("finalize_config crc=%u", 6),
    ("emergency_stop", 3),
    ("reset", 13),
    ("config_reset", 14),
    ("clear_shutdown", 2),
    ("config_trsync oid=%c", 15),
    ("trsync_start oid=%c report_clock=%u report_ticks=%u expire_reason=%c", 16),
    ("trsync_set_timeout oid=%c clock=%u", 17),
    ("trsync_trigger oid=%c reason=%c", 18),
    ("stepper_stop_on_trigger oid=%c trsync_oid=%c", 19),
    ("config_endstop oid=%c pin=%u pull_up=%c", 20),
    ("endstop_home oid=%c clock=%u sample_ticks=%u sample_count=%c rest_ticks=%u pin_value=%c trsync_oid=%c trigger_reason=%c", 21),
    ("endstop_query_state oid=%c", 22),
    ("config_digital_out oid=%c pin=%u value=%c default_value=%c max_duration=%u", 23),
    ("update_digital_out oid=%c value=%c", 24),
    ("set_digital_out pin=%u value=%c", 25),
    ("queue_digital_out oid=%c clock=%u on_ticks=%u", 26),
    ("set_digital_out_pwm_cycle oid=%c cycle_ticks=%u", 27),
    ("config_pwm_out oid=%c pin=%u cycle_ticks=%u value=%hu default_value=%hu max_duration=%u", 28),
    ("queue_pwm_out oid=%c clock=%u value=%hu", 29),
    ("config_analog_in oid=%c pin=%u", 30),
    ("query_analog_in oid=%c clock=%u sample_ticks=%u sample_count=%c rest_ticks=%u min_value=%hu max_value=%hu range_check_count=%c", 31),
    ("config_stepper oid=%c step_pin=%u dir_pin=%u invert_step=%c step_pulse_ticks=%u", 32),
    ("reset_step_clock oid=%c clock=%u", 33),
    ("queue_step oid=%c interval=%u count=%hu add=%hi", 34),
    ("set_next_step_dir oid=%c dir=%c", 35),
    ("stepper_get_position oid=%c", 36),
    ("config_spi_without_cs oid=%c", 37),
    ("config_spi oid=%c pin=%u cs_active_high=%c", 38),
    ("spi_set_software_bus oid=%c miso_pin=%u mosi_pin=%u sclk_pin=%u mode=%u rate=%u", 39),
    ("spi_set_bus oid=%c spi_bus=%u mode=%u rate=%u", 40),
    ("config_spi_shutdown oid=%c spi_oid=%c shutdown_msg=%*s", 41),
    ("spi_send oid=%c data=%*s", 42),
    ("spi_transfer oid=%c data=%*s", 43),
    ("config_adxl345 oid=%c spi_oid=%c", 44),
    ("query_adxl345 oid=%c clock=%u rest_ticks=%u", 45),
    ("query_adxl345_status oid=%c", 46),
    ("config_thermocouple oid=%c spi_oid=%c thermocouple_type=%u", 47),
    ("query_thermocouple oid=%c clock=%u rest_ticks=%u min_value=%u max_value=%u max_invalid_count=%u", 48),
    ("config_tmcuart oid=%c rx_pin=%u pull_up=%c tx_pin=%u bit_time=%u", 49),
    ("tmcuart_send oid=%c write=%*s read=%c", 50),
    ("config_buttons oid=%c button_count=%c", 51),
    ("buttons_add oid=%c pos=%c pin=%u pull_up=%c", 52),
    ("buttons_query oid=%c clock=%u rest_ticks=%u retransmit_count=%c invert=%c", 53),
    ("buttons_ack oid=%c count=%c", 54),
]
RESPONSES = [
    ("identify_response offset=%u data=%.*s", 0),
    ("uptime high=%u clock=%u", 60),
    ("clock clock=%u", 61),
    ("config is_config=%c crc=%u is_shutdown=%c move_count=%hu", 62),
    ("endstop_state oid=%c homing=%c next_clock=%u pin_value=%c", 63),
    ("trsync_state oid=%c can_trigger=%c trigger_reason=%c clock=%u", 64),
    ("stepper_position oid=%c pos=%i", 65),
    ("analog_in_state oid=%c next_clock=%u value=%hu", 66),
    ("thermocouple_result oid=%c next_clock=%u value=%u fault=%c", 67),
    ("spi_transfer_response oid=%c response=%*s", 68),
    ("tmcuart_response oid=%c read=%*s", 69),
    ("adxl345_status oid=%c clock=%u query_ticks=%u next_sequence=%hu buffered=%c fifo=%c limit_count=%hu", 70),
    ("adxl345_data oid=%c sequence=%hu data=%*s", 71),
    ("buttons_state oid=%c ack_count=%c state=%*s", 72),
    ("shutdown clock=%u static_string_id=%hu", 73),
    ("is_shutdown static_string_id=%hu", 74),
    ("stats count=%u sum=%u sumsq=%u", 75),
]


def crc16_ccitt(buf):
    crc = 0xFFFF
    for data in bytearray(buf):
        data ^= crc & 0xFF
        data ^= (data & 0x0F) << 4
        crc = (((data << 8) | (crc >> 8)) ^ (data >> 4) ^ (data << 3)) & 0xFFFF
    return crc


def encode_vlq(out, v):
    if v >= 0x0C000000 or v < -0x04000000:
        out.append(((v >> 28) & 0x7F) | 0x80)
    if v >= 0x00180000 or v < -0x00080000:
        out.append(((v >> 21) & 0x7F) | 0x80)
    if v >= 0x00003000 or v < -0x00001000:
        out.append(((v >> 14) & 0x7F) | 0x80)
    if v >= 0x00000060 or v < -0x00000020:
        out.append(((v >> 7) & 0x7F) | 0x80)
    out.append(v & 0x7F)


def parse_vlq(buf, pos):
    c = buf[pos]
    pos += 1
    v = c & 0x7F
    if (c & 0x60) == 0x60:
        v |= -0x20
    while c & 0x80:
        c = buf[pos]
        pos += 1
        v = (v << 7) | (c & 0x7F)
    return int(v & 0xFFFFFFFF), pos


def parse_bytes(buf, pos):
    length = buf[pos]
    pos += 1
    data = bytes(buf[pos:pos + length])
    return data, pos + length


def frame(seq, payload):
    msglen = MESSAGE_MIN + len(payload)
    if msglen > MESSAGE_MAX:
        raise ValueError("frame too long")
    buf = bytearray(msglen)
    buf[0] = msglen
    buf[1] = (seq & MESSAGE_SEQ_MASK) | MESSAGE_DEST
    buf[MESSAGE_HEADER:MESSAGE_HEADER + len(payload)] = payload
    crc = crc16_ccitt(buf[:msglen - MESSAGE_TRAILER])
    buf[msglen - 3] = (crc >> 8) & 0xFF
    buf[msglen - 2] = crc & 0xFF
    buf[msglen - 1] = MESSAGE_SYNC
    return bytes(buf)


def pin_enum():
    pins = {}
    n = 0
    for port in "ABCDEFG":
        for i in range(16):
            pins["P%s%d" % (port, i)] = n
            n += 1
    return pins


def build_dictionary(name):
    commands = {}
    for fmt, mid in COMMANDS:
        commands[fmt] = mid
    responses = {}
    for fmt, mid in RESPONSES:
        responses[fmt] = mid
    doc = {
        "config": {
            "MCU": "n32g455",
            "CLOCK_FREQ": str(CLOCK_FREQ),
            "SERIAL_BAUD": "230400",
            "ADC_MAX": str(ADC_MAX),
            "PWM_MAX": "32767",
            "STATS_SUMSQ_BASE": "256",
            "STEPPER_BOTH_EDGE": "1",
            "RECEIVE_WINDOW": "192",
        },
        "enumerations": {
            "pin": pin_enum(),
            "thermocouple_type": {
                "MAX31855": 0,
                "MAX31856": 1,
                "MAX31865": 2,
                "MAX6675": 3,
            },
        },
        "commands": commands,
        "responses": responses,
        "version": "board-mcu-%s" % name,
        "build_versions": "phobos-board-sim",
    }
    return zlib.compress(json.dumps(doc, separators=(",", ":")).encode("utf-8"))


def formats():
    by_id = {}
    for fmt, mid in COMMANDS + RESPONSES:
        parts = fmt.split()
        params = []
        for part in parts[1:]:
            name, typ = part.split("=", 1)
            params.append((name, typ))
        by_id[mid] = (parts[0], params)
    return by_id


BY_ID = formats()
RESP_ID = dict((fmt.split()[0], mid) for fmt, mid in RESPONSES)


def encode_params(fmt_params, values):
    out = bytearray()
    for (name, typ), value in zip(fmt_params, values):
        if typ in ("%*s", "%.*s", "%s"):
            raw = value if isinstance(value, (bytes, bytearray)) else bytes(value)
            out.append(len(raw) & 0xFF)
            out.extend(raw)
        else:
            encode_vlq(out, int(value))
    return bytes(out)


def parse_params(fmt_params, buf, pos):
    values = {}
    for name, typ in fmt_params:
        if typ in ("%*s", "%.*s", "%s"):
            values[name], pos = parse_bytes(buf, pos)
        else:
            values[name], pos = parse_vlq(buf, pos)
    return values, pos


def tmc_crc8(data):
    crc = 0
    for b in bytearray(data):
        for _ in range(8):
            if (crc >> 7) ^ (b & 0x01):
                crc = ((crc << 1) ^ 0x07) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
            b >>= 1
    return crc


def tmc_add_bits(data):
    out = 0
    pos = 0
    for d in bytearray(data):
        b = (d << 1) | 0x200
        out |= b << pos
        pos += 10
    res = bytearray()
    for i in range((pos + 7) // 8):
        res.append((out >> (i * 8)) & 0xFF)
    return bytes(res)


def tmc_strip_bits(data):
    mval = 0
    pos = 0
    for d in bytearray(data):
        mval |= d << pos
        pos += 8
    out = bytearray()
    for i in range(pos // 10):
        b = (mval >> (i * 10)) & 0x3FF
        out.append((b >> 1) & 0xFF)
    return bytes(out)


def tmc_encode_reply(reg, val):
    # Klippy's _decode_read compares the 10-byte payload with
    # _encode_write(0x05, 0xff, reg, val).
    msg = bytearray([0x05, 0xFF, reg & 0x7F,
                     (val >> 24) & 0xFF, (val >> 16) & 0xFF,
                     (val >> 8) & 0xFF, val & 0xFF])
    msg.append(tmc_crc8(msg))
    return tmc_add_bits(msg)


class Board:
    def __init__(self, name, bootloader):
        self.name = name
        self.bootloader = bootloader
        self.identify = build_dictionary(name)
        self.buf = b""
        self.next_sequence = MESSAGE_DEST
        self.configured = False
        self.config_crc = 0
        self.adcs = {}
        self.thermos = {}
        self.buttons = {}
        self.tmc_regs = {0x02: 0}  # IFCNT
        self.spi_mem = {}
        self.clock_epoch = time.monotonic() - 5.0

    def clock64(self):
        return int((time.monotonic() - self.clock_epoch) * CLOCK_FREQ)

    def clock32(self):
        return self.clock64() & 0xFFFFFFFF

    def ack(self):
        return frame(self.next_sequence, b"")

    def respond(self, name, values):
        mid = RESP_ID[name]
        _fmt_name, params = BY_ID[mid]
        payload = bytes(bytearray([mid]) + encode_params(params, values))
        return frame(self.next_sequence, payload)

    def feed(self, data):
        self.buf += data
        out = b""
        while True:
            if not self.buf:
                break
            if self.buf[0] == MESSAGE_SYNC:
                self.buf = self.buf[1:]
                continue
            if len(self.buf) < MESSAGE_MIN:
                break
            msglen = self.buf[0]
            if msglen < MESSAGE_MIN or msglen > MESSAGE_MAX:
                self.buf = self.buf[1:]
                continue
            if len(self.buf) < msglen:
                break
            block = self.buf[:msglen]
            self.buf = self.buf[msglen:]
            if block[-1] != MESSAGE_SYNC:
                continue
            crc = crc16_ccitt(block[:-MESSAGE_TRAILER])
            got = (block[-3] << 8) | block[-2]
            if crc != got:
                continue
            seq = block[1]
            if seq != self.next_sequence:
                out += self.ack()
                continue
            self.next_sequence = ((seq + 1) & MESSAGE_SEQ_MASK) | MESSAGE_DEST
            out += self.dispatch(block[MESSAGE_HEADER:-MESSAGE_TRAILER])
            out += self.ack()
        return out

    def dispatch(self, payload):
        out = b""
        pos = 0
        raw = bytearray(payload)
        while pos < len(raw):
            mid = raw[pos]
            pos += 1
            spec = BY_ID.get(mid)
            if spec is None:
                break
            name, params = spec
            values, pos = parse_params(params, raw, pos)
            out += self.on_command(name, values)
        return out

    def on_command(self, name, values):
        if name == "identify":
            offset = values["offset"]
            count = values["count"]
            if count > 40:
                count = 40
            chunk = self.identify[offset:offset + count]
            return self.respond("identify_response", [offset, chunk])
        if name == "get_uptime":
            c = self.clock64()
            return self.respond("uptime", [c >> 32, c & 0xFFFFFFFF])
        if name == "get_clock":
            return self.respond("clock", [self.clock32()])
        if name == "get_config":
            return self.respond("config", [
                1 if self.configured else 0,
                self.config_crc,
                0,
                1024,
            ])
        if name == "finalize_config":
            self.config_crc = values["crc"]
            self.configured = True
            return b""
        if name == "query_analog_in":
            self.adcs[values["oid"]] = values["sample_count"] or 1
            return b""
        if name == "query_thermocouple":
            self.thermos[values["oid"]] = True
            return b""
        if name == "buttons_query":
            # Idle lines sit at the invert mask, so active-low buttons read released.
            self.buttons[values["oid"]] = values["invert"] & 0xFF
            return b""
        if name == "endstop_query_state":
            return self.respond("endstop_state", [values["oid"], 0, self.clock32(), 0])
        if name == "trsync_trigger":
            return self.respond("trsync_state", [values["oid"], 1, 0, self.clock32()])
        if name == "stepper_get_position":
            return self.respond("stepper_position", [values["oid"], 0])
        if name == "query_adxl345_status":
            return self.respond("adxl345_status", [
                values["oid"], self.clock32(), 0, 0, 0, 0, 0,
            ])
        if name == "spi_transfer":
            return self.respond("spi_transfer_response", [
                values["oid"], self.spi_reply(values["oid"], values["data"]),
            ])
        if name == "spi_send":
            self.spi_store(values["oid"], values["data"])
            return b""
        if name == "tmcuart_send":
            read_n = values["read"]
            if read_n == 0:
                self.tmc_write(values["write"])
                return b""
            return self.respond("tmcuart_response", [
                values["oid"], self.tmc_read(values["write"], read_n),
            ])
        return b""

    def spi_store(self, oid, data):
        if len(data) >= 2:
            self.spi_mem[(oid, data[0] & 0x3F)] = data[1]

    def spi_reply(self, oid, data):
        # ADXL345 read: first byte is reg | 0x80, second is the value.
        if data and (data[0] & 0x80):
            reg = data[0] & 0x3F
            if reg == 0x00:
                val = 0xE5
            else:
                val = self.spi_mem.get((oid, reg), 0)
            return bytes(bytearray([0x00, val]))
        if data:
            self.spi_store(oid, data)
        return bytes(bytearray([0x00] * len(data)))

    def tmc_write(self, stuffed):
        fields = tmc_strip_bits(stuffed)
        if len(fields) >= 7 and (fields[2] & 0x80):
            reg = fields[2] & 0x7F
            val = (fields[3] << 24) | (fields[4] << 16) | (fields[5] << 8) | fields[6]
            self.tmc_regs[reg] = val
            self.tmc_regs[0x02] = (self.tmc_regs.get(0x02, 0) + 1) & 0xFF

    def tmc_read(self, stuffed, read_n):
        fields = tmc_strip_bits(stuffed)
        reg = fields[2] if len(fields) >= 3 else 0
        reg &= 0x7F
        val = self.tmc_regs.get(reg, 0)
        reply = tmc_encode_reply(reg, val)
        if len(reply) < read_n:
            reply = reply + bytes(bytearray([0] * (read_n - len(reply))))
        return reply[:read_n]

    def sensor_frames(self):
        if not self.configured:
            return b""
        out = b""
        now = self.clock32()
        for oid, count in self.adcs.items():
            value = int(ROOM_FRACTION * count * ADC_MAX)
            if value > 65535:
                value = 65535
            out += self.respond("analog_in_state", [oid, now, value])
        for oid in self.thermos:
            # fault=0, value in the configured 0..2048 window.
            out += self.respond("thermocouple_result", [oid, now, 100, 0])
        for oid, idle in self.buttons.items():
            out += self.respond("buttons_state", [oid, 0, bytes(bytearray([idle]))])
        return out


def log(link, msg):
    line = "[board-mcu %s] %s\n" % (link, msg)
    try:
        sys.stderr.write(line)
        sys.stderr.flush()
    except Exception:
        pass
    try:
        fd = os.open("/dev/console", os.O_WRONLY | os.O_NONBLOCK)
        os.write(fd, line.encode("utf-8"))
        os.close(fd)
    except Exception:
        pass


def ensure_link(link, slave_name):
    try:
        if os.path.islink(link) and os.readlink(link) == slave_name:
            return
    except OSError:
        pass
    try:
        os.remove(link)
    except OSError:
        pass
    try:
        os.symlink(slave_name, link)
    except OSError as exc:
        log(link, "symlink %s" % exc)


def serve(link, role):
    bootloader = role == "eboard"
    board = Board(role, bootloader)
    master, slave = os.openpty()
    tty.setraw(master)
    tty.setraw(slave)
    slave_name = os.ttyname(slave)
    ensure_link(link, slave_name)
    log(link, "role=%s pty=%s" % (role, slave_name))
    klipper = not bootloader
    next_ready = 0.0
    next_sensor = 0.0
    while True:
        ensure_link(link, slave_name)
        now = time.monotonic()
        if bootloader and not klipper and now >= next_ready:
            try:
                os.write(master, b"Ready.\r\n")
            except OSError:
                pass
            next_ready = now + 0.2
        if klipper and now >= next_sensor:
            try:
                frames = board.sensor_frames()
                if frames:
                    os.write(master, frames)
            except OSError:
                pass
            next_sensor = now + 0.3
        readable, _, _ = select.select([master], [], [], 0.05)
        if master not in readable:
            continue
        try:
            data = os.read(master, 4096)
        except OSError:
            time.sleep(0.05)
            continue
        if not data:
            time.sleep(0.05)
            continue
        if not klipper:
            if b"A" in data or data[:1] == b"A":
                try:
                    os.write(master, b"\x06")
                except OSError:
                    pass
                klipper = True
                log(link, "bootloader ack, Klipper mode")
                data = data.replace(b"A", b"")
                if not data:
                    continue
            else:
                # A Klipper frame arrived without the bootloader dance.
                klipper = True
                log(link, "binary traffic, Klipper mode")
        try:
            reply = board.feed(data)
            if reply:
                os.write(master, reply)
        except Exception as exc:
            log(link, "feed error %s" % exc)


def self_test():
    board = Board("main", False)
    # Host's first sequence nibble is 1; the MCU still expects 0. Nak.
    nak = board.feed(frame(0x11, bytes(bytearray([1, 0, 40]))))
    if len(nak) != MESSAGE_MIN or nak[1] != MESSAGE_DEST:
        raise SystemExit("expected nak of seq 0, got %r" % nak)
    # After the host resyncs it sends seq nibble 0, which the MCU expects.
    identify = bytes(bytearray([1])) + encode_params(
        [("offset", "%u"), ("count", "%c")], [0, 40])
    reply = board.feed(frame(MESSAGE_DEST, identify))
    # response frame then ack
    if len(reply) < MESSAGE_MIN * 2 or reply[2] != 0:
        raise SystemExit("identify response missing: %r" % reply[:16])
    # Pull the data bytes out of the first frame.
    msglen = reply[0]
    block = bytearray(reply[:msglen])
    pos = MESSAGE_HEADER + 1  # skip msgid
    _offset, pos = parse_vlq(block, pos)
    chunk, _pos = parse_bytes(block, pos)
    if chunk != board.identify[:40]:
        raise SystemExit("identify chunk mismatch")
    # Finish the dictionary and ask for config.
    rest = board.identify[40:]
    while rest:
        off = len(board.identify) - len(rest)
        identify = bytes(bytearray([1])) + encode_params(
            [("offset", "%u"), ("count", "%c")], [off, 40])
        board.feed(frame(board.next_sequence, identify))
        rest = rest[40:]
    # One past the end, empty chunk.
    off = len(board.identify)
    identify = bytes(bytearray([1])) + encode_params(
        [("offset", "%u"), ("count", "%c")], [off, 40])
    board.feed(frame(board.next_sequence, identify))
    raw = zlib.decompress(board.identify)
    doc = json.loads(raw.decode("utf-8"))
    if "PC1" not in doc["enumerations"]["pin"]:
        raise SystemExit("pin enum missing PC1")
    get_config = bytes(bytearray([7]))
    cfg = board.feed(frame(board.next_sequence, get_config))
    if cfg[2] != 62:
        raise SystemExit("get_config id %s" % cfg[2])
    # TMC reply decodes the way Klippy's _decode_read expects.
    reply = tmc_encode_reply(0x02, 0x11)
    fields = tmc_strip_bits(reply)
    if fields[2] != 0x02 or fields[6] != 0x11:
        raise SystemExit("tmc reply fields %r" % fields)
    if tmc_crc8(fields[:7]) != fields[7]:
        raise SystemExit("tmc crc")
    print("board_mcu self-test ok")


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) != 3 or sys.argv[2] not in ("main", "eboard"):
        sys.stderr.write("usage: board_mcu.py /dev/ttyS5 main|eboard\n")
        sys.exit(2)
    serve(sys.argv[1], sys.argv[2])


if __name__ == "__main__":
    main()
