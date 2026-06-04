#!/usr/bin/env python3
"""Unit + fuzz tests for check-ff-update.py (stdlib only).

Run:  python3 -m unittest tools.ota.test_check_ff_update   (or run this file directly)
Each public function has both an example-based unit test and a randomized fuzz test
that asserts invariants (no crashes, total ordering, idempotence) over random input.
"""
from __future__ import annotations

import importlib.util
import json
import os
import random
import string
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("ffupd", os.path.join(_HERE, "check-ff-update.py"))
ff = importlib.util.module_from_spec(_spec)
sys.modules["ffupd"] = ff  # dataclasses needs the module registered to resolve annotations
_spec.loader.exec_module(ff)

FUZZ_ITERS = int(os.environ.get("FUZZ_ITERS", "2000"))


def _rand_version(rng: random.Random) -> str:
    parts = [str(rng.randint(0, 99)) for _ in range(rng.randint(1, 4))]
    s = ".".join(parts)
    if rng.random() < 0.3:
        s += rng.choice(["-rc1", "rc2", "-beta", ".dev", "a", "b", "+build9"])
    return s


def _rand_str(rng: random.Random, n: int = 12) -> str:
    alphabet = string.printable + "äé—\x00\t{}[]\"\\"
    return "".join(rng.choice(alphabet) for _ in range(rng.randint(0, n)))


# --- parse_version -----------------------------------------------------------


class TestParseVersion(unittest.TestCase):
    def test_ordering(self):
        self.assertTrue(ff.parse_version("3.1.4") > ff.parse_version("3.1.3"))
        self.assertTrue(ff.parse_version("3.2.0") > ff.parse_version("3.1.9"))
        self.assertTrue(ff.parse_version("5.1.4") > ff.parse_version("3.1.3"))

    def test_numeric_outranks_alpha_at_slot(self):
        # at the same position a numeric token beats an alpha one
        self.assertTrue(ff.parse_version("1.2") > ff.parse_version("1.b"))
        # extra trailing token makes a version sort greater (FF never ships pre-release tags)
        self.assertTrue(ff.parse_version("1.0rc1") > ff.parse_version("1.0"))

    def test_empty_is_lowest(self):
        self.assertEqual(ff.parse_version(""), ())
        self.assertTrue(ff.parse_version("0.0.1") > ff.parse_version(""))

    def test_non_string(self):
        self.assertEqual(ff.parse_version(314), ff.parse_version("314"))

    def test_fuzz_total_order_and_no_crash(self):
        rng = random.Random(1)
        for _ in range(FUZZ_ITERS):
            a, b = _rand_str(rng), _rand_str(rng)
            pa, pb = ff.parse_version(a), ff.parse_version(b)
            # comparable (no TypeError) and antisymmetric
            self.assertEqual(pa > pb, not (pa <= pb))
            # deterministic
            self.assertEqual(pa, ff.parse_version(a))


class TestVersionGt(unittest.TestCase):
    def test_basic(self):
        self.assertTrue(ff.version_gt("2.0.0", "1.9.9"))
        self.assertFalse(ff.version_gt("1.0.0", "1.0.0"))
        self.assertFalse(ff.version_gt("1.0.0", "2.0.0"))

    def test_fuzz_irreflexive_antisymmetric(self):
        rng = random.Random(2)
        for _ in range(FUZZ_ITERS):
            a, b = _rand_version(rng), _rand_version(rng)
            self.assertFalse(ff.version_gt(a, a))
            if ff.version_gt(a, b):
                self.assertFalse(ff.version_gt(b, a))


# --- request builders --------------------------------------------------------


class TestBuilders(unittest.TestCase):
    def test_check_param_keys(self):
        ident = ff.Identity(version="3.1.3", app_id="7", platform="linux", entity_id="e", hardware_version="hw")
        body = ff.build_check_param(ident)
        self.assertEqual(set(body), {"app_id", "platform", "version", "entity_id", "hardware_version"})
        self.assertEqual(body["version"], "3.1.3")

    def test_legacy_param_keys(self):
        ident = ff.Identity(version="3.1.3", sn="SN1", name="Adventurer5Mpro", oem="flashforge")
        body = ff.build_legacy_param(ident)
        self.assertEqual(body["ClientSN"], "SN1")
        self.assertEqual(body["ClientVersion"], "3.1.3")
        self.assertIn("ClientHardware", body)

    def test_download_url_order_and_escaping(self):
        ident = ff.Identity(version="3.1 3", app_id="a&b", platform="p", entity_id="e", hardware_version="h")
        url = ff.build_download_url("https://x/dl", ident)
        # documented param order, and special chars are escaped
        self.assertTrue(url.startswith("https://x/dl?app_id=a%26b&platform=p&version=3.1%203&entity_id=e&hardware_version=h"))

    def test_fuzz_download_url_wellformed(self):
        rng = random.Random(3)
        for _ in range(FUZZ_ITERS):
            ident = ff.Identity(
                version=_rand_str(rng), app_id=_rand_str(rng), platform=_rand_str(rng),
                entity_id=_rand_str(rng), hardware_version=_rand_str(rng),
            )
            url = ff.build_download_url("https://h/p", ident)
            self.assertEqual(url.count("?"), 1)
            for key in ("app_id=", "&platform=", "&version=", "&entity_id=", "&hardware_version="):
                self.assertIn(key, url)
            # no raw whitespace/control leaked into the query
            self.assertNotIn(" ", url.split("?", 1)[1])


# --- response parsing --------------------------------------------------------


class TestParseCheckResponse(unittest.TestCase):
    def test_update_available(self):
        r = ff.parse_check_response({"version": "3.1.4", "message": "new"}, "3.1.3")
        self.assertTrue(r.update_available)
        self.assertEqual(r.latest_version, "3.1.4")

    def test_up_to_date(self):
        r = ff.parse_check_response({"version": "3.1.3"}, "3.1.3")
        self.assertFalse(r.update_available)

    def test_older_server_version(self):
        r = ff.parse_check_response({"version": "3.0.0"}, "3.1.3")
        self.assertFalse(r.update_available)

    def test_force_update_same_or_diff(self):
        r = ff.parse_check_response({"version": "3.1.2", "force_update": True}, "3.1.3")
        self.assertTrue(r.update_available)  # forced downgrade still flagged
        r2 = ff.parse_check_response({"version": "3.1.3", "force_update": 1}, "3.1.3")
        self.assertFalse(r2.update_available)  # identical version, nothing to do

    def test_wrapped_payload(self):
        r = ff.parse_check_response({"data": {"version": "9.9.9"}}, "3.1.3")
        self.assertTrue(r.update_available)
        self.assertEqual(r.latest_version, "9.9.9")

    def test_text_and_bytes_input(self):
        self.assertTrue(ff.parse_check_response('{"version":"4.0"}', "3.1").update_available)
        self.assertTrue(ff.parse_check_response(b'{"version":"4.0"}', "3.1").update_available)

    def test_empty(self):
        r = ff.parse_check_response("", "3.1.3")
        self.assertFalse(r.update_available)
        self.assertEqual(r.latest_version, "")

    def test_bad_json_raises(self):
        with self.assertRaises(ValueError):
            ff.parse_check_response("{not json", "3.1.3")

    def test_fuzz_never_crashes_on_dicts(self):
        rng = random.Random(4)
        keys = ["version", "force_update", "message", "detail", "changelist", "data", "result", "junk"]
        for _ in range(FUZZ_ITERS):
            d = {}
            for _ in range(rng.randint(0, 5)):
                v = rng.choice([_rand_str(rng), rng.randint(-9, 9), True, False, None, [], {"x": 1}, _rand_version(rng)])
                d[rng.choice(keys)] = v
            r = ff.parse_check_response(d, _rand_version(rng))
            self.assertIsInstance(r.update_available, bool)
            self.assertIsInstance(r.latest_version, str)

    def test_fuzz_random_json_text(self):
        rng = random.Random(5)
        for _ in range(FUZZ_ITERS // 2):
            payload = json.dumps({"version": _rand_version(rng), "force_update": rng.choice([0, 1, True, "yes"])})
            cur = _rand_version(rng)
            r = ff.parse_check_response(payload, cur)
            # invariant: flagged-available implies newer-or-forced
            if r.update_available and not r.force_update:
                self.assertTrue(ff.version_gt(r.latest_version, cur))


class TestParseLegacyResponse(unittest.TestCase):
    def test_packages_mean_update(self):
        r = ff.parse_legacy_response({"SoftwarePackage": "sw.tar.xz"}, "3.1.3")
        self.assertTrue(r.update_available)
        self.assertIn("SoftwarePackage", r.packages)

    def test_no_packages_no_update(self):
        r = ff.parse_legacy_response({}, "3.1.3")
        self.assertFalse(r.update_available)

    def test_fuzz_no_crash(self):
        rng = random.Random(6)
        fields = ["KernelPackage", "ControlPackage", "LibraryPackage", "SoftwarePackage", "Version", "junk"]
        for _ in range(FUZZ_ITERS):
            d = {rng.choice(fields): rng.choice([_rand_str(rng), "", None, 0]) for _ in range(rng.randint(0, 4))}
            r = ff.parse_legacy_response(d, _rand_version(rng))
            self.assertIsInstance(r.update_available, bool)


# --- coerce_bool -------------------------------------------------------------


class TestCoerceBool(unittest.TestCase):
    def test_examples(self):
        for truthy in (True, 1, "1", "true", "YES", "force"):
            self.assertTrue(ff._coerce_bool(truthy))
        for falsy in (False, 0, "", "0", "no", None, [], {}):
            self.assertFalse(ff._coerce_bool(falsy))

    def test_fuzz_returns_bool(self):
        rng = random.Random(7)
        for _ in range(FUZZ_ITERS):
            v = rng.choice([_rand_str(rng), rng.randint(-5, 5), None, True, False, [], {}])
            self.assertIsInstance(ff._coerce_bool(v), bool)


# --- local detection ---------------------------------------------------------


class TestDetectLocal(unittest.TestCase):
    def test_highest_version_dir(self):
        with tempfile.TemporaryDirectory() as d:
            for name in ("3.1.3", "5.1.4", "2.0.0", "notes.txt", "backup"):
                if "." in name and name[0].isdigit():
                    os.mkdir(os.path.join(d, name))
                else:
                    os.mkdir(os.path.join(d, name))
            self.assertEqual(ff.detect_local_version(d), "5.1.4")

    def test_missing_root(self):
        self.assertEqual(ff.detect_local_version("/nonexistent/path/xyz"), "")

    def test_machine_json(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "m.json")
            with open(path, "w") as fh:
                json.dump({"serialNumber": "SN42", "machineType": "Adventurer5Mpro"}, fh)
            got = ff.detect_identity_from_machine_json(path)
            self.assertEqual(got["sn"], "SN42")
            self.assertEqual(got["name"], "Adventurer5Mpro")

    def test_machine_json_missing(self):
        self.assertEqual(ff.detect_identity_from_machine_json("/no/such.json"), {})

    def test_fuzz_machine_json_garbage(self):
        rng = random.Random(8)
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "m.json")
            for _ in range(FUZZ_ITERS // 20):
                with open(path, "w") as fh:
                    fh.write(_rand_str(rng, 40))
                # garbage must yield {} (or a dict), never raise
                self.assertIsInstance(ff.detect_identity_from_machine_json(path), dict)


# --- orchestration with injected transport -----------------------------------


class TestCheckUpdate(unittest.TestCase):
    def _transport(self, payload_text):
        calls = {}

        def t(url, body, headers):
            calls["url"], calls["body"], calls["headers"] = url, body, headers
            return payload_text

        return t, calls

    def test_v2_flow(self):
        t, calls = self._transport('{"version":"5.1.4"}')
        ident = ff.Identity(version="3.1.3", app_id="1")
        r = ff.check_update(ident, channel="v2", transport=t)
        self.assertTrue(r.update_available)
        self.assertEqual(calls["url"], ff.ENDPOINTS["v2"]["check"])
        self.assertEqual(calls["body"]["version"], "3.1.3")

    def test_legacy_flow(self):
        t, calls = self._transport('{"SoftwarePackage":"sw.tar.xz"}')
        ident = ff.Identity(version="3.1.3", sn="SN")
        r = ff.check_update(ident, channel="legacy", transport=t)
        self.assertTrue(r.update_available)
        self.assertIn("ClientSN", calls["body"])

    def test_unknown_channel(self):
        with self.assertRaises(ValueError):
            ff.check_update(ff.Identity(version="1"), channel="bogus", transport=lambda *a: "{}")

    def test_fuzz_transport_payloads(self):
        rng = random.Random(9)
        for _ in range(FUZZ_ITERS // 4):
            payload = json.dumps({"version": _rand_version(rng)})
            t, _ = self._transport(payload)
            r = ff.check_update(ff.Identity(version=_rand_version(rng)), channel="v2", transport=t)
            self.assertIsInstance(r.update_available, bool)


# --- CLI smoke (offline via monkeypatched transport) -------------------------


class TestCLI(unittest.TestCase):
    def test_main_requires_version(self):
        self.assertEqual(ff.main(["--channel", "v2"]), 1)

    def test_main_blocks_dev(self):
        self.assertEqual(ff.main(["--channel", "dev", "--version", "1.0"]), 1)

    def test_main_update_available(self):
        orig = ff.http_transport
        try:
            ff.http_transport = lambda url, body, headers, timeout=15: '{"version":"9.9.9"}'
            rc = ff.main(["--version", "3.1.3", "--json"])
            self.assertEqual(rc, 10)
        finally:
            ff.http_transport = orig

    def test_main_up_to_date(self):
        orig = ff.http_transport
        try:
            ff.http_transport = lambda url, body, headers, timeout=15: '{"version":"3.1.3"}'
            self.assertEqual(ff.main(["--version", "3.1.3"]), 0)
        finally:
            ff.http_transport = orig


if __name__ == "__main__":
    unittest.main()
