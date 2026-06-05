#!/usr/bin/env python3
"""Unit + fuzz tests for the shipped moonraker.conf (stdlib only).

Guards two classes of regression we actually hit on hardware:

  1. The reserved `klipper`/`moonraker` update_manager sections must list ONLY
     options Moonraker reads for reserved updaters (common.py OPTION_OVERRIDES,
     plus `repo` added by our 0002 patch). Anything else is silently ignored and
     emits an "Unparsed config option" warning — the bug this test locks down.
  2. `[file_manager] file_system_observer` must be `none`: the stock 5.4.61
     kernel has no CONFIG_INOTIFY_USER, so `inotify` aborts Moonraker at startup.

Run:  python3 tests/release/test_moonraker_conf.py
      FUZZ_ITERS=20000 python3 tests/release/test_moonraker_conf.py
"""

import configparser
import os
import random
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_CONF = os.path.join(
    _HERE, "..", "..", "br-external", "board", "reforge",
    "rootfs-overlay", "etc", "reforge", "moonraker.conf")

# Options Moonraker reads from a RESERVED updater's section. Mirrors
# update_manager/common.py OPTION_OVERRIDES (+ our 0002 patch adding "repo").
RESERVED_ALLOWED = frozenset((
    "channel", "repo", "pinned_commit", "refresh_interval", "report_anomalies",
))
RESERVED_NAMES = frozenset(("klipper", "moonraker"))

FUZZ_ITERS = int(os.environ.get("FUZZ_ITERS", "2000"))


def reserved_unparsed(options):
    """Options that Moonraker would IGNORE (→ warning) in a reserved section."""
    return set(options) - RESERVED_ALLOWED


def load_conf():
    cp = configparser.ConfigParser(strict=False)
    # Moonraker uses `key: value`; configparser handles it. allow_no_value for
    # bare sections like [history] / [zeroconf].
    cp = configparser.ConfigParser(strict=False, allow_no_value=True)
    with open(_CONF) as fh:
        cp.read_file(fh)
    return cp


class TestReservedUnparsed(unittest.TestCase):
    def test_clean_set(self):
        self.assertEqual(reserved_unparsed(["channel", "repo"]), set())

    def test_flags_ignored(self):
        self.assertEqual(
            reserved_unparsed(["channel", "repo", "type", "path",
                               "managed_services"]),
            {"type", "path", "managed_services"})

    def test_all_overrides_allowed(self):
        self.assertEqual(reserved_unparsed(RESERVED_ALLOWED), set())

    def test_fuzz_never_flags_allowed(self):
        rnd = random.Random(1)
        allowed = list(RESERVED_ALLOWED)
        for _ in range(FUZZ_ITERS):
            opts = rnd.sample(allowed, rnd.randrange(len(allowed) + 1))
            self.assertEqual(reserved_unparsed(opts), set())

    def test_fuzz_flags_exactly_the_extras(self):
        rnd = random.Random(2)
        allowed = list(RESERVED_ALLOWED)
        for _ in range(FUZZ_ITERS):
            extras = {f"opt{rnd.randrange(1000)}" for _ in range(rnd.randrange(4))}
            extras -= RESERVED_ALLOWED
            opts = rnd.sample(allowed, rnd.randrange(len(allowed) + 1)) + list(extras)
            self.assertEqual(reserved_unparsed(opts), extras)


class TestShippedConf(unittest.TestCase):
    def setUp(self):
        self.cp = load_conf()

    def test_reserved_sections_have_no_ignored_options(self):
        for section in self.cp.sections():
            if not section.startswith("update_manager "):
                continue
            name = section.split(maxsplit=1)[1]
            if name not in RESERVED_NAMES:
                continue
            ignored = reserved_unparsed(self.cp.options(section))
            self.assertEqual(
                ignored, set(),
                f"[{section}] lists options Moonraker ignores for a reserved "
                f"updater (would warn): {sorted(ignored)}")

    def test_reserved_sections_keep_repo_and_channel(self):
        for name in RESERVED_NAMES:
            sec = f"update_manager {name}"
            self.assertIn(sec, self.cp.sections())
            self.assertEqual(self.cp.get(sec, "repo"), "maci0/reforge")
            self.assertEqual(self.cp.get(sec, "channel"), "stable")

    def test_file_system_observer_disabled(self):
        # The stock kernel lacks CONFIG_INOTIFY_USER; inotify aborts Moonraker.
        self.assertEqual(self.cp.get("file_manager", "file_system_observer"),
                         "none")

    def test_non_reserved_zip_updaters_well_formed(self):
        # guppyscreen / reforge are non-reserved: they DO read type/repo/path.
        for name in ("guppyscreen", "reforge"):
            sec = f"update_manager {name}"
            self.assertIn(sec, self.cp.sections())
            self.assertEqual(self.cp.get(sec, "type"), "zip")
            self.assertTrue(self.cp.get(sec, "repo"))
            self.assertTrue(self.cp.get(sec, "path"))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
