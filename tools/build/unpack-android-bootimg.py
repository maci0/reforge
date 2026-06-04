#!/usr/bin/env python3
"""
unpack-android-bootimg.py — minimal Android boot-image v0 unpacker.

The FlashForge AD5M Pro's mmcblk0p4 carries kernel + dtb + ramdisk + cmdline in
the standard Android boot-image format (the boot.md §1 cmdline confirms
"ANDROID! image format"). This is a no-dep Python replacement for `abootimg`
that handles the v0 header (`header_version == 0`), which is what FlashForge's
stock 2018.05 vendor U-Boot expects.

Header layout (v0): include/uapi/linux/android_boot.h equivalent.

Outputs into <outdir>:
  kernel        page-aligned slice
  ramdisk       page-aligned slice (or empty file if size==0)
  second        page-aligned slice (DTB on some FF builds; or empty)
  bootimg.cfg   key=value: cmdline, pagesize, kernel_addr, ramdisk_addr, ...
"""

from __future__ import annotations
import os
import struct
import sys
from pathlib import Path


# Android boot-image v0 header (AOSP `boot_img_hdr_v0` from include/bootimg/bootimg.h)
#   magic[8] kernel_size kernel_addr
#   ramdisk_size ramdisk_addr
#   second_size second_addr
#   tags_addr page_size header_version os_version
#   name[16] cmdline[512] id[8 × u32] extra_cmdline[1024]
HEADER_FMT = "<8sIIIIIIIIII16s512s8I1024s"
HEADER_SIZE = struct.calcsize(HEADER_FMT)
# 8 (magic) + 40 (10 × uint32) + 16 (name) + 512 (cmdline)
#   + 32 (8 × uint32 id) + 1024 (extra_cmdline) = 1632 bytes
assert HEADER_SIZE == 1632, HEADER_SIZE


def align_up(n: int, page: int) -> int:
    return ((n + page - 1) // page) * page


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write(f"usage: {argv[0]} <boot.img> <outdir>\n")
        return 2

    boot_img, outdir = argv[1], Path(argv[2])
    outdir.mkdir(parents=True, exist_ok=True)

    with open(boot_img, "rb") as f:
        hdr = f.read(HEADER_SIZE)
        if len(hdr) != HEADER_SIZE:
            sys.stderr.write("ERROR: short read on header\n")
            return 1

        fields = struct.unpack(HEADER_FMT, hdr)
        (
            magic,
            kernel_size, kernel_addr,
            ramdisk_size, ramdisk_addr,
            second_size, second_addr,
            tags_addr,
            page_size,
            header_version,
            os_version,
            name,
            cmdline,
            *id_words_and_extra,
        ) = fields
        # The trailing 8 × uint32 id[] + 1024-byte extra_cmdline come back as 9 values.
        _id_words = id_words_and_extra[:8]
        extra_cmdline = id_words_and_extra[8]

        if magic != b"ANDROID!":
            sys.stderr.write(f"ERROR: bad magic {magic!r}\n")
            return 1

        name = name.rstrip(b"\x00").decode("utf-8", "replace")
        cmdline = cmdline.rstrip(b"\x00").decode("utf-8", "replace")
        extra_cmdline = extra_cmdline.rstrip(b"\x00").decode("utf-8", "replace")

        # Print header summary
        sys.stderr.write(
            f"[unpack] magic={magic.decode()} ver={header_version} "
            f"page={page_size} kernel={kernel_size} ramdisk={ramdisk_size} "
            f"second={second_size} tags=0x{tags_addr:x}\n"
        )
        sys.stderr.write(f"[unpack] name={name!r}\n")
        sys.stderr.write(f"[unpack] cmdline={cmdline!r}\n")
        if extra_cmdline:
            sys.stderr.write(f"[unpack] extra_cmdline={extra_cmdline!r}\n")

        # Offsets are page-aligned starting at page 1 (header is page 0).
        kernel_off  = page_size
        ramdisk_off = kernel_off  + align_up(kernel_size,  page_size)
        second_off  = ramdisk_off + align_up(ramdisk_size, page_size)

        def slice_to(path: Path, off: int, size: int) -> None:
            f.seek(off)
            data = f.read(size) if size else b""
            path.write_bytes(data)
            sys.stderr.write(f"[unpack] wrote {path}  ({len(data)} bytes)\n")

        slice_to(outdir / "kernel",  kernel_off,  kernel_size)
        slice_to(outdir / "ramdisk", ramdisk_off, ramdisk_size)
        slice_to(outdir / "second",  second_off,  second_size)

        cfg = outdir / "bootimg.cfg"
        cfg.write_text(
            f"# from {boot_img}\n"
            f"bootsize=0x{os.path.getsize(boot_img):x}\n"
            f"pagesize=0x{page_size:x}\n"
            f"kerneladdr=0x{kernel_addr:x}\n"
            f"ramdiskaddr=0x{ramdisk_addr:x}\n"
            f"secondaddr=0x{second_addr:x}\n"
            f"tagsaddr=0x{tags_addr:x}\n"
            f"name={name}\n"
            f"cmdline={cmdline}\n"
            f"extra_cmdline={extra_cmdline}\n"
            f"header_version={header_version}\n"
            f"os_version=0x{os_version:x}\n"
        )
        sys.stderr.write(f"[unpack] wrote {cfg}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
