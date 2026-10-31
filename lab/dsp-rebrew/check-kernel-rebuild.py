#!/usr/bin/env python3
# /// script
# requires-python = ">=3.15"
# dependencies = ["rebrew @ https://github.com/maci0/rebrew/releases/download/v6.9.0/rebrew-6.9.0-py3-none-any.whl", "pyelftools==0.33"]
# ///
"""Check two independent builds and reject byte/length/binding regressions."""

import argparse
import importlib.util
import json
import shutil
import tempfile
from copy import deepcopy
from pathlib import Path

from elftools.elf.elffile import ELFFile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("first", type=Path)
    parser.add_argument("second", type=Path)
    parser.add_argument("reference", type=Path)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location(
        "kernel_rebuild", here / "rebuild-kernel.py"
    )
    rebuild = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rebuild)
    layout = json.loads((here / "kernel-layout.json").read_text())
    report = rebuild.verify(layout, args.first, args.reference)
    rebuild.verify(layout, args.second, args.reference)
    assert (args.first / "kernel.elf").read_bytes() == (
        args.second / "kernel.elf"
    ).read_bytes()
    checks = ["two independent builds are byte-identical"]

    def reject(candidate_layout, directory, message):
        try:
            rebuild.verify(candidate_layout, directory, args.reference)
        except ValueError as exc:
            assert message in str(exc), str(exc)
        else:
            raise AssertionError("invalid component accepted")

    with tempfile.TemporaryDirectory(prefix="dsp-kernel-controls-") as temporary:
        root = Path(temporary)
        damaged = root / "damaged"
        shutil.copytree(args.first, damaged)
        original = (args.first / "kernel.elf").read_bytes()
        with (args.first / "kernel.elf").open("rb") as stream:
            elf = ELFFile(stream)
            sections = [
                (s["sh_addr"], s["sh_size"], s["sh_offset"])
                for s in elf.iter_sections()
                if s["sh_flags"] & 2
            ]
        for row in report["ranges"]:
            if row.get("zero_fill"):
                continue
            address = int(row["address"], 16)
            start, _, offset = next(
                s for s in sections if s[0] <= address < s[0] + s[1]
            )
            data = bytearray(original)
            data[offset + address - start] ^= 1
            (damaged / "kernel.elf").write_bytes(data)
            reject(layout, damaged, "component bytes differ")
            checks.append("reject changed byte: " + row["name"])
        wrong_size = deepcopy(layout)
        wrong_size["objects"][0]["functions"][0]["size"] += 1
        reject(wrong_size, args.first, "placement/length differs")
        checks.append("reject wrong function length")
        (damaged / "kernel.elf").write_bytes(original)
        data = bytearray((damaged / "kernel-component.bin").read_bytes())
        data[0] ^= 1
        (damaged / "kernel-component.bin").write_bytes(data)
        reject(layout, damaged, "component binary disagrees")
        checks.append("reject modified component binary")
        wrong_binding = deepcopy(layout)
        binding = wrong_binding["externals"]["sprintf"]
        binding["address"] = hex(int(binding["address"], 16) + 4)
        rebuild.build(args.source.resolve(), root / "wrong-binding", wrong_binding)
        reject(layout, root / "wrong-binding", "component bytes differ")
        checks.append("reject recompiled component with sprintf address +4")
    (args.second / "checks.json").write_text(
        json.dumps({"passed": True, "checks": checks}, indent=2) + "\n"
    )
    print(f"PASS: {len(checks)} component checks")


if __name__ == "__main__":
    main()
