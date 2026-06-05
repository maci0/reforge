#!/usr/bin/env python3
"""Unit + fuzz tests for reforge-boot-eboard (stdlib only).

The script under test is the eboard (toolhead MCU) boot handshake — the step
ReForge was missing that left the toolhead dark in live mode. The byte protocol
(has_ready / is_boot_ack / run_handshake) is exercised purely via injected I/O;
configure_tty and main() are exercised against a real pty so no printer or
serial cable is needed.

Run:  python3 tests/release/test_boot_eboard.py
      FUZZ_ITERS=20000 python3 tests/release/test_boot_eboard.py
"""

import os
import importlib.util
import random
import sys
import termios
import threading
import time
import unittest
from importlib.machinery import SourceFileLoader

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPT = os.path.join(
    _HERE, "..", "..", "br-external", "board", "reforge",
    "rootfs-overlay", "usr", "bin", "reforge-boot-eboard")

# The script has no .py extension, so spec_from_file_location can't infer a
# loader — name a SourceFileLoader explicitly.
_loader = SourceFileLoader("reforge_boot_eboard", os.path.abspath(_SCRIPT))
_spec = importlib.util.spec_from_loader("reforge_boot_eboard", _loader)
eb = importlib.util.module_from_spec(_spec)
_loader.exec_module(eb)

FUZZ_ITERS = int(os.environ.get("FUZZ_ITERS", "2000"))


def seq_reader(chunks):
    """A read() callable that yields the given chunks then b"" forever."""
    it = iter(chunks)

    def _read():
        return next(it, b"")
    return _read


class TestHasReady(unittest.TestCase):
    def test_present(self):
        self.assertTrue(eb.has_ready(b"Ready."))
        self.assertTrue(eb.has_ready(b"garbage\x00Ready.\r\n"))

    def test_absent(self):
        self.assertFalse(eb.has_ready(b""))
        self.assertFalse(eb.has_ready(b"Read"))
        self.assertFalse(eb.has_ready(b"ready."))  # case-sensitive, like boot_mcu

    def test_fuzz_never_crashes_returns_bool(self):
        rnd = random.Random(1)
        for _ in range(FUZZ_ITERS):
            buf = bytes(rnd.randrange(256) for _ in range(rnd.randrange(40)))
            self.assertIsInstance(eb.has_ready(buf), bool)

    def test_fuzz_token_injection_property(self):
        """Token embedded at a random offset is always found; pure noise that
        happens to contain the token is also found (define-by-substring)."""
        rnd = random.Random(2)
        for _ in range(FUZZ_ITERS):
            pre = bytes(rnd.randrange(256) for _ in range(rnd.randrange(20)))
            post = bytes(rnd.randrange(256) for _ in range(rnd.randrange(20)))
            self.assertTrue(eb.has_ready(pre + eb.READY_TOKEN + post))


class TestIsBootAck(unittest.TestCase):
    def test_ack_bytes(self):
        self.assertTrue(eb.is_boot_ack(b"\x01"))
        self.assertTrue(eb.is_boot_ack(b"\x06"))
        self.assertTrue(eb.is_boot_ack(b"\xff\x06\xff"))

    def test_no_ack(self):
        self.assertFalse(eb.is_boot_ack(b""))
        self.assertFalse(eb.is_boot_ack(b"\x00\x02\x05\x07"))

    def test_fuzz_never_crashes_returns_bool(self):
        rnd = random.Random(3)
        for _ in range(FUZZ_ITERS):
            buf = bytes(rnd.randrange(256) for _ in range(rnd.randrange(40)))
            res = eb.is_boot_ack(buf)
            self.assertIsInstance(res, bool)
            # Property: equals whether any configured ack byte is in the buffer.
            self.assertEqual(res, any(b in buf for b in eb.ACK_BYTES))


class TestRunHandshake(unittest.TestCase):
    def test_fresh_boot_ok(self):
        writes = []
        rc = eb.run_handshake(
            seq_reader([b"\x00noise", b"..Ready.\r\n", b"\x06"]), writes.append)
        self.assertEqual(rc, eb.OK)
        self.assertEqual(writes, [eb.CMD_BOOT])  # one 'A' sent, acked first try

    def test_already_booted_not_ready(self):
        # App traffic at the wrong baud: never the token -> NOT_READY, no write.
        writes = []
        rc = eb.run_handshake(
            seq_reader([b"\x4f\x03\xf4"] * 50), writes.append)
        self.assertEqual(rc, eb.ERR_NOT_READY)
        self.assertEqual(writes, [])

    def test_silent_mcu_not_ready(self):
        rc = eb.run_handshake(seq_reader([]), lambda b: None)  # all b""
        self.assertEqual(rc, eb.ERR_NOT_READY)

    def test_ready_but_no_ack(self):
        writes = []
        rc = eb.run_handshake(
            seq_reader([b"Ready."] + [b"\x00"] * 50), writes.append)
        self.assertEqual(rc, eb.ERR_NO_BOOT)
        # One write per boot attempt, capped at BOOT_RETRIES.
        self.assertEqual(len(writes), eb.BOOT_RETRIES)

    def test_ready_on_last_retry(self):
        chunks = [b"x"] * (eb.READY_RETRIES - 1) + [b"Ready.", b"\x01"]
        rc = eb.run_handshake(seq_reader(chunks), lambda b: None)
        self.assertEqual(rc, eb.OK)

    def test_ready_one_too_late_fails(self):
        chunks = [b"x"] * eb.READY_RETRIES + [b"Ready.", b"\x01"]
        rc = eb.run_handshake(seq_reader(chunks), lambda b: None)
        self.assertEqual(rc, eb.ERR_NOT_READY)

    def test_ack_on_last_boot_retry(self):
        reads = [b"Ready."] + [b"\x00"] * (eb.BOOT_RETRIES - 1) + [b"\x06"]
        rc = eb.run_handshake(seq_reader(reads), lambda b: None)
        self.assertEqual(rc, eb.OK)

    def test_fuzz_terminates_valid_code(self):
        """Arbitrary read streams: always a valid code, bounded writes."""
        rnd = random.Random(4)
        valid = {eb.OK, eb.ERR_NOT_READY, eb.ERR_NO_BOOT}
        for _ in range(FUZZ_ITERS):
            n = rnd.randrange(60)
            chunks = [bytes(rnd.randrange(256)
                            for _ in range(rnd.randrange(34)))
                      for _ in range(n)]
            writes = []
            rc = eb.run_handshake(seq_reader(chunks), writes.append)
            self.assertIn(rc, valid)
            self.assertLessEqual(len(writes), eb.BOOT_RETRIES)
            if rc == eb.ERR_NOT_READY:
                self.assertEqual(writes, [])  # never wrote before seeing Ready.

    def test_fuzz_constructed_outcomes(self):
        """Build streams with a known outcome and assert the code matches."""
        rnd = random.Random(5)
        noise = lambda k: bytes(rnd.randrange(1, 256) for _ in range(k))  # noqa: E731
        for _ in range(FUZZ_ITERS):
            ready_at = rnd.randrange(eb.READY_RETRIES + 3)
            reads = [noise(rnd.randrange(1, 8)) for _ in range(ready_at)]
            reads.append(b"Ready.")
            if ready_at >= eb.READY_RETRIES:
                rc = eb.run_handshake(seq_reader(reads), lambda b: None)
                self.assertEqual(rc, eb.ERR_NOT_READY)
                continue
            ack_at = rnd.randrange(eb.BOOT_RETRIES + 3)
            reads += [b"\x00"] * ack_at + [bytes([rnd.choice(eb.ACK_BYTES)])]
            rc = eb.run_handshake(seq_reader(reads), lambda b: None)
            self.assertEqual(rc, eb.OK if ack_at < eb.BOOT_RETRIES
                             else eb.ERR_NO_BOOT)


class TestConfigureTty(unittest.TestCase):
    def test_sets_raw_115200(self):
        master, slave = os.openpty()
        try:
            eb.configure_tty(slave)
            iflag, oflag, cflag, lflag, ispeed, ospeed, cc = \
                termios.tcgetattr(slave)
            self.assertEqual(ispeed, eb.BAUD)
            self.assertEqual(ospeed, eb.BAUD)
            self.assertEqual(cc[termios.VMIN], 0)
            self.assertEqual(cc[termios.VTIME], eb.READ_TIMEOUT_DS)
            self.assertFalse(lflag & termios.ICANON)
            self.assertFalse(lflag & termios.ECHO)
            self.assertFalse(oflag & termios.OPOST)
            self.assertTrue(cflag & termios.CS8)
        finally:
            os.close(master)
            os.close(slave)

    def test_fuzz_idempotent(self):
        # Applying the config repeatedly converges to the same attrs.
        master, slave = os.openpty()
        try:
            eb.configure_tty(slave)
            first = termios.tcgetattr(slave)
            for _ in range(min(FUZZ_ITERS, 200)):
                eb.configure_tty(slave)
            self.assertEqual(termios.tcgetattr(slave), first)
        finally:
            os.close(master)
            os.close(slave)


class TestMainOverPty(unittest.TestCase):
    def test_missing_tty(self):
        rc = eb.main(["reforge-boot-eboard", "/dev/does-not-exist-ttyZZ"])
        self.assertEqual(rc, eb.ERR_NO_TTY)

    def _fake_mcu(self, master, stop, ready_until_ack=True):
        """Background 'eboard bootloader': spew Ready. until it gets 'A',
        then answer 0x06 once."""
        os.set_blocking(master, False)
        acked = False
        deadline = time.time() + 5
        while not stop.is_set() and time.time() < deadline:
            try:
                data = os.read(master, 32)
            except (BlockingIOError, OSError):
                data = b""
            if data and eb.CMD_BOOT in data and not acked:
                os.write(master, b"\x06")
                acked = True
                return
            if not acked:
                try:
                    os.write(master, b"Ready.\r\n")
                except OSError:
                    return
            time.sleep(0.05)

    def test_main_handshake_ok(self):
        master, slave = os.openpty()
        slave_name = os.ttyname(slave)
        os.close(slave)  # main() opens it by name itself
        stop = threading.Event()
        t = threading.Thread(target=self._fake_mcu, args=(master, stop))
        t.start()
        try:
            rc = eb.main(["reforge-boot-eboard", slave_name])
        finally:
            stop.set()
            t.join(timeout=2)
            os.close(master)
        self.assertEqual(rc, eb.OK)


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
