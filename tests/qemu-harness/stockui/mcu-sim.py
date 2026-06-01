#!/opt/Python-3.7.11/bin/python3.7
# mcu-sim.py — qemu-only stand-in for the AD5M eboard/main MCU.
#
# The stock FlashForge UI (firmwareExe) refuses to leave its "No detected eboard
# mcu." modal until it can open the MCU serial port (/dev/ttyS1 = eboard,
# /dev/ttyS5 = main @230400) and complete a boot handshake (openSerial ->
# Serial::recvWaitOk). On qemu virt there is no 8250 UART (the platform only has
# PL011 ttyAMA*), so those nodes never exist.
#
# This emulates a Marlin-style gcode MCU on a pty: it emits "start" on open and
# replies "ok" to every command line (plus a FIRMWARE_NAME banner for M115), then
# symlinks the requested /dev node at the pty slave. The pty is raw (no echo, so
# we don't read back our own writes) and the symlink self-heals each loop (udev
# coldplug churns /dev). Logs rx/tx to /dev/console for debugging.
#
# Usage: mcu-sim.py /dev/ttyS1   (run one per port; pair with fake-klippy.py)
import os, pty, sys, select, time, tty

link = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyS1"
try:
    con = os.open("/dev/console", os.O_WRONLY)
except OSError:
    con = 2


def log(s):
    try:
        os.write(con, ("[mcu-sim %s] %s\n" % (link, s)).encode())
    except OSError:
        pass


master, slave = pty.openpty()
tty.setraw(master)
tty.setraw(slave)
sname = os.ttyname(slave)


def ensure_link():
    # (re)point link -> our pts; returns True when (re)created (target must exist)
    try:
        if os.path.lexists(link) and os.readlink(link) == sname and os.path.exists(sname):
            return False
    except OSError:
        pass
    try:
        os.remove(link)
    except OSError:
        pass
    try:
        os.symlink(sname, link)
        return True
    except OSError as e:
        log("symlink err %r" % e)
        return False


ensure_link()
os.write(master, b"start\n")
log("bound -> %s, TX start" % sname)

buf = b""
while True:
    if ensure_link():
        os.write(master, b"start\n")
        log("relink, TX start")
    r, _, _ = select.select([master], [], [], 1.0)
    if master not in r:
        continue
    try:
        data = os.read(master, 4096)
    except OSError:
        time.sleep(0.2)
        continue
    if not data:
        time.sleep(0.2)
        continue
    log("RX %r" % data[:32])
    buf += data
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        if not line.strip():
            continue
        if b"M115" in line:
            os.write(master, b"FIRMWARE_NAME:Reforge-sim MACHINE_TYPE:AD5M\n")
        os.write(master, b"ok\n")
