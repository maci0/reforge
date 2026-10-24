"""Exercise the splash through a real terminal and through redirected output."""

import errno
import fcntl
import os
from pathlib import Path
import pty
import shutil
import struct
import subprocess
import tempfile
import termios
import unittest
from unittest.mock import patch


BANNER = Path(__file__).resolve().parents[2] / "br-external/board/reforge/rootfs-overlay/usr/bin/reforge-banner"


def terminal_output(*args, term="linux", columns=100):
    master, slave = pty.openpty()
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, columns, 0, 0))
        proc = subprocess.Popen(
            ["sh", str(BANNER), *args], stdin=slave, stdout=slave, stderr=slave,
            env={**os.environ, "TERM": term, "REFORGE_LIVE": "1"},
        )
        os.close(slave)
        slave = None
        output = bytearray()
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
        assert proc.wait(timeout=10) == 0
        return output.decode()
    finally:
        os.close(master)
        if slave is not None:
            os.close(slave)


class BannerTest(unittest.TestCase):
    def test_redirected_output_is_plain_even_when_animation_requested(self):
        output = subprocess.check_output(
            ["sh", str(BANNER), "--animate"], text=True,
            env={**os.environ, "TERM": "linux", "REFORGE_LIVE": "1"},
        )
        self.assertIn("ReForge", output)
        self.assertIn("LIVE", output)
        self.assertNotIn("\033", output)

    def test_animation_updates_fire_and_restores_cursor(self):
        output = terminal_output("--animate")
        self.assertEqual(output.count("\033[2;1H"), 28)
        self.assertIn("LIVE", output)
        self.assertIn("KLIPPER, REFORGED", output)
        self.assertTrue(output.endswith("\0338\033[0m\033[?25h"))

    def test_login_stays_static(self):
        output = terminal_output()
        self.assertIn("KLIPPER, REFORGED", output)
        self.assertNotIn("\033[2;1H", output)
        self.assertNotIn("\033[?25l", output)

    @unittest.skipUnless(shutil.which("busybox"), "BusyBox is not installed")
    def test_busybox_awk_animation(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "awk").symlink_to(shutil.which("busybox"))
            with patch.dict(os.environ, {"PATH": directory + ":" + os.environ["PATH"]}):
                output = terminal_output("--animate")
        self.assertEqual(output.count("\033[2;1H"), 28)
        self.assertNotIn("awk:", output)

    def test_dumb_and_narrow_terminals_fall_back(self):
        for options in ({"term": "dumb"}, {"columns": 40}):
            with self.subTest(options=options):
                output = terminal_output("--animate", **options)
                self.assertIn("ReForge", output)
                self.assertNotIn("\033[?25l", output)


if __name__ == "__main__":
    unittest.main()
