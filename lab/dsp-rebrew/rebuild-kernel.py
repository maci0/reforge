#!/usr/bin/env python3
# /// script
# requires-python = ">=3.15"
# dependencies = ["rebrew @ https://github.com/maci0/rebrew/releases/download/v6.9.0/rebrew-6.9.0-py3-none-any.whl", "pyelftools==0.33"]
# ///
"""Recompile the stock DSP's retained FreeRTOS C core without reading stock bytes."""

import argparse
import hashlib
import json
import re
from dataclasses import replace
from pathlib import Path

from elftools.elf.elffile import ELFFile
from rebrew.compiler.toolchain import cached_image_digest, run_toolchain
from rebrew.compiler.toolchain_spec import ToolchainSpec

HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def image(path):
    with path.open("rb") as stream:
        elf = ELFFile(stream)
        sections = [
            (s.name, s["sh_addr"], s["sh_size"], s["sh_type"], s.data())
            for s in elf.iter_sections()
            if s["sh_flags"] & 2
        ]
        table = elf.get_section_by_name(".symtab")
        symbols = (
            {s.name: (s["st_value"], s["st_size"]) for s in table.iter_symbols()}
            if table is not None
            else {}
        )
    return sections, symbols


def read(sections, address, size):
    for _, origin, length, kind, data in sections:
        if origin <= address and address + size <= origin + length:
            return (
                bytes(size)
                if kind == "SHT_NOBITS"
                else data[address - origin : address - origin + size]
            )
    raise ValueError(f"unmapped component range {address:#x}+{size:#x}")


def component_ranges(layout):
    ranges = [
        {
            "name": "literal pool",
            "address": layout["literal_address"],
            "size": layout["literal_size"],
        }
    ]
    for kind in ["code", "rodata", "bss"]:
        ranges += [
            {"name": f"{kind} span {i}", "zero_fill": kind == "bss", **span}
            for i, span in enumerate(layout[kind + "_spans"])
        ]
    return sorted(ranges, key=lambda row: int(row["address"], 16))


def payload(sections, ranges):
    return b"".join(
        read(sections, int(r["address"], 16), r["size"])
        for r in ranges
        if not r.get("zero_fill")
    )


def verify(layout, output, reference):
    if digest(reference) != layout["stock_sha256"]:
        raise ValueError("stock ELF SHA-256 mismatch")
    stock, _ = image(reference)
    built, symbols = image(output / "kernel.elf")
    ranges = component_ranges(layout)
    for i, obj in enumerate(layout["objects"]):
        for func in obj["functions"]:
            expected = (int(func["address"], 16), func["size"])
            if symbols.get(func["name"]) != expected:
                raise ValueError(
                    f"linked function placement/length differs: {func['name']}"
                )
        with (output / f"input{i}.o").open("rb") as stream:
            elf = ELFFile(stream)
            table = elf.get_section_by_name(".symtab")
            placements = {
                s["name"]: int(s["address"], 16)
                for s in obj["sections"]
                if s["address"] is not None
            }
            for symbol in table.iter_symbols():
                idx = symbol["st_shndx"]
                if symbol["st_info"]["type"] != "STT_OBJECT" or not isinstance(
                    idx, int
                ):
                    continue
                section = elf.get_section(idx).name
                if section in placements:
                    expected = (
                        placements[section] + symbol["st_value"],
                        symbol["st_size"],
                    )
                    if symbols.get(symbol.name) != expected:
                        raise ValueError(
                            f"linked data placement/length differs: {symbol.name}"
                        )
    result = []
    for row in ranges:
        address, size = int(row["address"], 16), row["size"]
        expected, actual = read(stock, address, size), read(built, address, size)
        result.append(
            {
                **row,
                "equal": actual == expected,
                "sha256": hashlib.sha256(actual).hexdigest(),
            }
        )
    actual_payload = payload(built, ranges)
    if (
        all(row["equal"] for row in result)
        and (output / "kernel-component.bin").read_bytes() != actual_payload
    ):
        raise ValueError("component binary disagrees with linked ELF")
    expected_payload = payload(stock, ranges)
    (output / "reference-component.bin").write_bytes(expected_payload)
    report = {
        "component": layout["component"],
        "scope": layout["scope"],
        "equal": all(row["equal"] for row in result),
        "functions": sum(len(obj["functions"]) for obj in layout["objects"]),
        "initialized_bytes": sum(r["size"] for r in ranges if not r.get("zero_fill")),
        "zero_fill_bytes": sum(r["size"] for r in ranges if r.get("zero_fill")),
        "stock_sha256": digest(reference),
        "built_elf_sha256": digest(output / "kernel.elf"),
        "component_sha256": hashlib.sha256(actual_payload).hexdigest(),
        "reference_component_sha256": hashlib.sha256(expected_payload).hexdigest(),
        "ranges": result,
    }
    (output / "comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report["equal"]:
        raise ValueError(
            "component bytes differ: "
            + ", ".join(r["name"] for r in result if not r["equal"])
        )
    return report


def build(source, output, layout):
    for name, expected in layout["source_inputs"].items():
        if digest(source / name) != expected:
            raise ValueError(f"source input SHA-256 mismatch: {name}")
    output.mkdir(parents=True, exist_ok=False)
    spec = ToolchainSpec(
        "xtensa-kernel",
        layout["image"],
        binary="xt-xcc",
        runtime="native",
        flags_style="posix",
        image_entrypoint="xt-xcc",
    )
    image_id = cached_image_digest(spec.image, runtime="docker")
    if image_id != layout["image_id"]:
        raise ValueError("XCC image identity differs from the verified compiler")
    commands = []

    def tool(binary, args):
        commands.append([binary, *args])
        result = run_toolchain(
            replace(spec, binary=binary, image_entrypoint=binary),
            args,
            workdir=output,
            mounts=[(str(source), "/source")],
            image_id=image_id,
            execution_backend="docker",
            timeout=120,
        )
        with (output / "build.log").open("a") as log:
            log.write(result.stdout + result.stderr)
        if result.returncode:
            raise ValueError(f"{binary} failed; see {output / 'build.log'}")

    config = HERE / "cohort-candidate.config"
    if digest(config) != layout["config_sha256"]:
        raise ValueError("candidate configuration SHA-256 mismatch")
    (output / "config").mkdir()
    defines = []
    for line in config.read_text().splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            name, value = line.split("=", 1)
            defines.append(f"#define {name} {'1' if value == 'y' else value}")
    (output / "config/autoconf.h").write_text("\n".join(defines) + "\n")
    # The vendor Makefile copies this SDK header into the source tree; use it in place.
    (output / "config/reent.h").write_text("#include <sys/reent.h>\n")
    kernel = "kernel/FreeRTOS_xtensa_v1.7"
    includes = [
        "config",
        "/source/projects/r528/dsp0/src",
        "/source/projects/r528/dsp0/include",
        "/source/include",
        "/source/include/hal",
        "/source/include/hal/sound",
        "/source/include/osal",
        "/source/drivers/hal/source",
        "/source/components/thirdparty/freertos",
        f"/source/{kernel}/include",
        f"/source/{kernel}/include/private",
        f"/source/{kernel}/FreeRTOS/portable/XCC/Xtensa",
        "/source/arch/include",
        "/source/arch/sun8iw20/include",
    ]
    flags = [
        "-O3",
        "-g3",
        "-Wall",
        "-ffunction-sections",
        "-fdata-sections",
        "-mlongcalls",
        "-DXT_BOARD",
        "-DSTANDALONE=1",
        "-DXTUTIL_NO_OVERRIDE",
    ]
    flags += ["-I" + directory for directory in includes] + [
        "-include",
        "autoconf.h",
        "-include",
        "map_func.h",
    ]
    for i, obj in enumerate(layout["objects"]):
        if digest(source / obj["source"]) != obj["sha256"]:
            raise ValueError(f"source SHA-256 mismatch: {obj['source']}")
        tool(
            "xt-xcc",
            [
                *flags,
                "-MD",
                "-MF",
                f"input{i}.d",
                "-c",
                "/source/" + obj["source"],
                "-o",
                f"input{i}.o",
            ],
        )
    # These modules are compiled in the stock cohort but have no retained code/data.
    for name in ["event_groups", "stream_buffer"]:
        tool(
            "xt-xcc",
            [
                *flags,
                "-MD",
                "-MF",
                f"unused-{name}.d",
                "-c",
                f"/source/{kernel}/FreeRTOS/{name}.c",
                "-o",
                f"unused-{name}.o",
            ],
        )
    dependencies = set()
    for depfile in output.glob("*.d"):
        dependencies.update(re.findall(r"/source/([^\s\\]+)", depfile.read_text()))
    if dependencies != set(layout["source_inputs"]):
        raise ValueError(
            "compiled source dependency closure differs from the pinned manifest"
        )

    groups = {".text": []}
    assembly = []
    for i, (name, binding) in enumerate(sorted(layout["externals"].items())):
        if binding["type"] == "STT_FUNC":
            section = f".text.bind.{i}"
            assembly += [
                f'.section {section},"ax"',
                f".global {name}",
                f".type {name},@function",
                f"{name}:",
                ".byte 0",
            ]
            groups[".text"].append(
                (int(binding["address"], 16), f'KEEP(bindings.o("{section}"))')
            )
    (output / "bindings.S").write_text("\n".join(assembly) + "\n")
    tool("xt-xcc", ["-c", "bindings.S", "-o", "bindings.o"])
    literals = []
    for i in layout["literal_order"]:
        literals += [
            f'KEEP(input{i}.o("{s["name"]}"))'
            for s in layout["objects"][i]["sections"]
            if s["name"].startswith(".literal")
        ]
    groups[".text"].append((int(layout["literal_address"], 16), "\n".join(literals)))
    for i, obj in enumerate(layout["objects"]):
        for section in obj["sections"]:
            if section["address"] is None:
                continue
            group = (
                ".text"
                if section["flags"] & 4
                else ".bss"
                if section["type"] == "SHT_NOBITS"
                else ".data"
                if section["flags"] & 1
                else ".rodata"
            )
            groups.setdefault(group, []).append(
                (int(section["address"], 16), f'KEEP(input{i}.o("{section["name"]}"))')
            )
    script = ["SECTIONS {"]
    for group, entries in groups.items():
        entries.sort()
        origin = entries[0][0]
        script.append(f"{group} 0x{origin:x} : {{")
        for address, expression in entries:
            # MAX permits the native linker's initial unrelaxed size; verify checks final VAs.
            script += [f". = MAX(., 0x{address - origin:x});", expression]
        script.append("}")
    script += [
        "/DISCARD/ : { *(.debug*) *(.text*) *(.literal*) *(.rodata*) *(.data*) *(.bss*) }",
        "}",
    ]
    (output / "layout.ld").write_text("\n".join(script) + "\n")
    args = ["-T", "layout.ld", "-Map=kernel.map", "-o", "kernel.elf", "bindings.o"]
    args += [f"input{i}.o" for i in range(len(layout["objects"]))] + [
        "unused-event_groups.o",
        "unused-stream_buffer.o",
    ]
    args += [
        f"--defsym={name}={binding['address']}"
        for name, binding in layout["externals"].items()
        if binding["type"] != "STT_FUNC"
    ]
    tool("xt-ld", args)
    sections, _ = image(output / "kernel.elf")
    (output / "kernel-component.bin").write_bytes(
        payload(sections, component_ranges(layout))
    )
    (output / "buildinfo.json").write_text(
        json.dumps(
            {
                "image_id": image_id,
                "source_commit": layout["source_commit"],
                "source_inputs": layout["source_inputs"],
                "layout_sha256": digest(HERE / "kernel-layout.json"),
                "commands": commands,
                "elf_sha256": digest(output / "kernel.elf"),
            },
            indent=2,
        )
        + "\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "source", type=Path, help="candidate repository's freertos directory"
    )
    parser.add_argument("output", type=Path, help="new build directory")
    parser.add_argument(
        "--reference", type=Path, help="stock ELF, read only after compilation/linking"
    )
    args = parser.parse_args()
    layout = json.loads((HERE / "kernel-layout.json").read_text())
    build(args.source.resolve(), args.output.resolve(), layout)
    if args.reference is not None:
        result = verify(layout, args.output.resolve(), args.reference.resolve())
        print(
            f"EXACT: {result['functions']} kernel functions and every declared component range"
        )
    else:
        print(f"Built {args.output / 'kernel.elf'} without a reference image")


if __name__ == "__main__":
    main()
