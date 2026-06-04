#!/usr/bin/env python3
# ruff: noqa: E501
"""Check the official FlashForge update server for an AD5M / AD5M Pro firmware update.

This is a *read-only* checker — it queries FlashForge's cloud update endpoints, compares
the advertised version against the version running locally, and reports whether an update
is offered. It never downloads, unpacks, or flashes anything.

Endpoints (reverse-engineered from the stock `firmwareExe`, see
docs/reverse-engineering/firmwareexe-ota-update.md):

  v2 (current):  POST https://update.voxelshare.com/api/updates/check
                 GET  .../api/updates/v2/download_url?app_id=&platform=&version=&entity_id=&hardware_version=
  legacy:        POST https://update.sz3dp.com:10443/update
                 (ClientSN/ClientName/ClientOEM/ClientVersion/ClientBuildTime/ClientHardware)
  dev:           http://10.33.11.172:32112  -- plaintext internal server, BLOCKED unless --allow-dev.

Security note: the stock update path verifies firmware with MD5 only (no signature) and runs
an in-package run.sh as root. This tool only *checks*; do not pipe its output into a flasher.

Exit codes:
  0   up to date (no newer version offered)
  10  update available
  1   error (network/parse/usage)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from dataclasses import dataclass, field
from typing import Callable, Optional

# --- endpoints ---------------------------------------------------------------

ENDPOINTS = {
    "v2": {
        "check": "https://update.voxelshare.com/api/updates/check",
        "download_url": "https://update.voxelshare.com/api/updates/v2/download_url",
    },
    "v2-cn": {
        "check": "https://api.voxelshare.com/api/updates/check",
        "download_url": "https://api.voxelshare.com/api/updates/v2/download_url",
    },
    "legacy": {
        "check": "https://update.sz3dp.com:10443/update",
    },
    "legacy-cn": {
        "check": "https://update.cn.sz3dp.com:10443/update",
    },
    "dev": {  # plaintext internal server compiled into the shipping binary; opt-in only
        "check": "http://10.33.11.172:32112/api/updates/check",
        "download_url": "http://10.33.11.172:32112/api/updates/v2/download_url",
    },
}

USER_AGENT = "reforge-ff-update-check/1"
DEFAULT_TIMEOUT = 15

# Where the stock firmware records the running software version.
STOCK_VERSION_GLOB = "/opt/PROGRAM/software"
STOCK_MACHINE_JSON = "/opt/config/Adventurer5M.json"


# --- identity ----------------------------------------------------------------


@dataclass
class Identity:
    """The device fields the update server keys off of."""

    version: str = ""           # currently-running firmware version, e.g. "3.1.3"
    app_id: str = ""
    platform: str = ""
    entity_id: str = ""
    hardware_version: str = ""
    sn: str = ""                # serial number (legacy ClientSN)
    name: str = "Adventurer5Mpro"
    oem: str = "flashforge"
    build_time: str = ""


# --- version comparison ------------------------------------------------------

_VER_TOKEN = re.compile(r"\d+|[A-Za-z]+")


def parse_version(s: str) -> tuple:
    """Split a version string into a comparable tuple.

    Each token is a numeric run (compared as an int) or an alpha run (compared as a
    lowercased string); a numeric token always sorts above an alpha token at the same
    slot. Empty/garbage input yields an empty tuple (sorts lowest). Total order over any
    two strings, never raises. Tuned for FlashForge's numeric dotted versions ("3.1.3",
    "5.1.4"); it does not implement semver pre-release ("1.0rc1" sorts above "1.0"), which
    FF never ships.
    """
    if not isinstance(s, str):
        s = str(s)
    out = []
    for tok in _VER_TOKEN.findall(s):
        if tok.isdigit():
            out.append((1, int(tok), ""))
        else:
            out.append((0, 0, tok.lower()))
    return tuple(out)


def version_gt(a: str, b: str) -> bool:
    """True iff version a is strictly newer than version b."""
    return parse_version(a) > parse_version(b)


# --- request building --------------------------------------------------------


def build_check_param(ident: Identity) -> dict:
    """The v2 CheckParam JSON body (param vocabulary per the documented download query)."""
    return {
        "app_id": ident.app_id,
        "platform": ident.platform,
        "version": ident.version,
        "entity_id": ident.entity_id,
        "hardware_version": ident.hardware_version,
    }


def build_legacy_param(ident: Identity) -> dict:
    """The legacy sz3dp request body."""
    return {
        "ClientSN": ident.sn,
        "ClientName": ident.name,
        "ClientOEM": ident.oem,
        "ClientVersion": ident.version,
        "ClientBuildTime": ident.build_time,
        "ClientHardware": ident.hardware_version,
    }


def _q(s: str) -> str:
    from urllib.parse import quote

    return quote(s, safe="")


def build_download_url(base: str, ident: Identity) -> str:
    """Reconstruct the v2 download_url GET (exact param order from the stock binary)."""
    return (
        f"{base}?app_id={_q(ident.app_id)}"
        f"&platform={_q(ident.platform)}"
        f"&version={_q(ident.version)}"
        f"&entity_id={_q(ident.entity_id)}"
        f"&hardware_version={_q(ident.hardware_version)}"
    )


# --- response parsing --------------------------------------------------------


@dataclass
class Result:
    update_available: bool = False
    current_version: str = ""
    latest_version: str = ""
    force_update: bool = False
    message: str = ""
    detail: str = ""
    changelist: str = ""
    packages: dict = field(default_factory=dict)  # legacy per-component packages
    raw: dict = field(default_factory=dict)


def _coerce_bool(v) -> bool:
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v != 0
    if isinstance(v, str):
        return v.strip().lower() in ("1", "true", "yes", "y", "force")
    return False


def parse_check_response(raw, current_version: str) -> Result:
    """Parse a v2 check response (dict or JSON text) into a Result.

    Tolerant of missing/extra keys and of the server wrapping the payload in
    {"data": {...}} / {"result": {...}}. Never raises on shape; raises only on
    genuinely undecodable JSON text.
    """
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8", "replace")
    if isinstance(raw, str):
        raw = json.loads(raw) if raw.strip() else {}
    if not isinstance(raw, dict):
        raw = {}

    body = raw
    for wrap in ("data", "result", "body"):
        inner = body.get(wrap)
        if isinstance(inner, dict) and any(
            k in inner for k in ("version", "force_update", "changelist", "message")
        ):
            body = inner
            break

    latest = str(body.get("version", "") or "")
    res = Result(
        current_version=current_version,
        latest_version=latest,
        force_update=_coerce_bool(body.get("force_update")),
        message=str(body.get("message", "") or ""),
        detail=str(body.get("detail", "") or ""),
        changelist=str(body.get("changelist", "") or ""),
        raw=raw if isinstance(raw, dict) else {},
    )
    res.update_available = bool(latest) and version_gt(latest, current_version)
    if res.force_update and latest and latest != current_version:
        res.update_available = True
    return res


def parse_legacy_response(raw, current_version: str) -> Result:
    """Parse a legacy sz3dp response — presence of any *Package field means an update."""
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8", "replace")
    if isinstance(raw, str):
        raw = json.loads(raw) if raw.strip() else {}
    if not isinstance(raw, dict):
        raw = {}

    pkg_fields = ("KernelPackage", "ControlPackage", "LibraryPackage", "SoftwarePackage")
    packages = {k: raw[k] for k in pkg_fields if raw.get(k)}
    latest = str(
        raw.get("SoftwareVersion") or raw.get("Version") or raw.get("version") or ""
    )
    res = Result(
        current_version=current_version,
        latest_version=latest,
        message=str(raw.get("Description", "") or raw.get("message", "") or ""),
        packages=packages,
        raw=raw,
    )
    res.update_available = bool(packages) or (
        bool(latest) and version_gt(latest, current_version)
    )
    return res


# --- local identity detection ------------------------------------------------


def detect_local_version(software_root: str = STOCK_VERSION_GLOB) -> str:
    """Highest version-named subdir under /opt/PROGRAM/software (stock layout)."""
    try:
        subdirs = [
            d
            for d in os.listdir(software_root)
            if os.path.isdir(os.path.join(software_root, d))
        ]
    except OSError:
        return ""
    versions = [d for d in subdirs if re.match(r"^\d", d)]
    if not versions:
        return ""
    return max(versions, key=parse_version)


def detect_identity_from_machine_json(path: str = STOCK_MACHINE_JSON) -> dict:
    """Pull whatever identity hints exist in the stock machine config (best-effort)."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    out = {}
    for key, dst in (
        ("sn", "sn"),
        ("serialNumber", "sn"),
        ("SerialNumber", "sn"),
        ("name", "name"),
        ("machineType", "name"),
        ("oem", "oem"),
        ("hardwareVersion", "hardware_version"),
        ("hardware_version", "hardware_version"),
    ):
        v = data.get(key)
        if isinstance(v, (str, int)) and str(v):
            out.setdefault(dst, str(v))
    return out


# --- transport ---------------------------------------------------------------

# A transport is: (url, body_dict_or_None, headers_dict) -> response_text.
Transport = Callable[[str, Optional[dict], dict], str]


def http_transport(url: str, body: Optional[dict], headers: dict, timeout: int = DEFAULT_TIMEOUT) -> str:
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data is not None else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (https endpoints; dev http is opt-in)
        return resp.read().decode("utf-8", "replace")


# --- orchestration -----------------------------------------------------------


def check_update(
    ident: Identity,
    channel: str = "v2",
    transport: Optional[Transport] = None,
    timeout: int = DEFAULT_TIMEOUT,
) -> Result:
    """Query one channel and return a Result. Pure given the transport (injectable for tests)."""
    if channel not in ENDPOINTS:
        raise ValueError(f"unknown channel {channel!r}; choose from {sorted(ENDPOINTS)}")
    transport = transport or (lambda u, b, h: http_transport(u, b, h, timeout))
    headers = {"User-Agent": USER_AGENT, "Content-Type": "application/json", "Accept": "application/json"}
    url = ENDPOINTS[channel]["check"]
    legacy = channel.startswith("legacy")
    body = build_legacy_param(ident) if legacy else build_check_param(ident)
    text = transport(url, body, headers)
    return (parse_legacy_response if legacy else parse_check_response)(text, ident.version)


# --- CLI ---------------------------------------------------------------------


def build_identity_from_args(args) -> Identity:
    ident = Identity()
    if args.auto:
        for k, v in detect_identity_from_machine_json().items():
            setattr(ident, k, v)
        detected = detect_local_version()
        if detected:
            ident.version = detected
    for attr in ("version", "app_id", "platform", "entity_id", "hardware_version", "sn", "name", "oem", "build_time"):
        v = getattr(args, attr, None)
        if v:
            setattr(ident, attr, v)
    return ident


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Check the FlashForge server for an AD5M firmware update (read-only).")
    p.add_argument("--channel", default="v2", choices=sorted(ENDPOINTS), help="update channel (default: v2)")
    p.add_argument("--version", help="current firmware version (else --auto / required)")
    p.add_argument("--app-id", dest="app_id", default="")
    p.add_argument("--platform", default="")
    p.add_argument("--entity-id", dest="entity_id", default="")
    p.add_argument("--hardware-version", dest="hardware_version", default="")
    p.add_argument("--sn", default="", help="serial number (legacy channel)")
    p.add_argument("--name", default="", help="machine name, e.g. Adventurer5Mpro")
    p.add_argument("--oem", default="", help="oem, e.g. flashforge")
    p.add_argument("--build-time", dest="build_time", default="")
    p.add_argument("--auto", action="store_true", help="autodetect identity/version from the local stock filesystem")
    p.add_argument("--allow-dev", action="store_true", help="permit the dev channel (plaintext internal server)")
    p.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    p.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = p.parse_args(argv)

    if args.channel == "dev" and not args.allow_dev:
        print("refusing dev channel (plaintext internal server); pass --allow-dev to override", file=sys.stderr)
        return 1

    ident = build_identity_from_args(args)
    if not ident.version:
        print("no current version: pass --version or run on the device with --auto", file=sys.stderr)
        return 1

    try:
        res = check_update(ident, channel=args.channel, timeout=args.timeout)
    except Exception as exc:  # network/parse: report, don't traceback
        print(f"check failed: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps({
            "update_available": res.update_available,
            "current_version": res.current_version,
            "latest_version": res.latest_version,
            "force_update": res.force_update,
            "message": res.message,
            "detail": res.detail,
            "changelist": res.changelist,
            "packages": res.packages,
        }, indent=2))
    elif res.update_available:
        print(f"UPDATE AVAILABLE: {res.current_version} -> {res.latest_version}"
              + ("  [FORCED]" if res.force_update else ""))
        if res.message:
            print(f"  {res.message}")
        if res.changelist:
            print(f"  changelog: {res.changelist}")
        if res.packages:
            print(f"  packages: {', '.join(res.packages)}")
    else:
        print(f"up to date (running {res.current_version}"
              + (f", server offers {res.latest_version}" if res.latest_version else "") + ")")

    return 10 if res.update_available else 0


if __name__ == "__main__":
    raise SystemExit(main())
