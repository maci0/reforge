#!/usr/bin/env python3
"""Compile recovered stock board configuration; never import or flash target code."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import zlib

SOURCE = Path(__file__).resolve().parents[2] / 'br-external/board/reforge/stock'
EXPECTED = {
    'sunxi.dtb': '27501dc48c5ad4c71e3a12742e3ef2a162d6a2d8285bbbac82488c7fade79e21',
    'toc.dtb': 'c6984cf79fc07fa5ad898f6828f13b4689809b9d3cdf6301444ee69a6a15103d',
    'toc-padded.dtb': '2629b7fca484cad18a8a80094a6d3dcc544720637ea3ff0f28fb7ab385672c29',
    'u-boot-control.dtb': '488d06dfbab38e7e6d06ec9354e2fdb4d8ceadfa89b082641c1d2073a37c6731',
    'env.bin': '6c8985dc584a50782267ff6a01fa8e886901ab5e48c550a0a2055dfd806628d7',
    'env-redund.bin': '6c8985dc584a50782267ff6a01fa8e886901ab5e48c550a0a2055dfd806628d7',
}


def environment(text):
    records = text.encode('ascii').splitlines()
    names = [record.split(b'=', 1)[0] for record in records]
    if not records or any(b'=' not in record or b'\0' in record for record in records):
        raise ValueError('environment must contain ordered NAME=value records without NUL bytes')
    if any(not name for name in names) or len(set(names)) != len(names):
        raise ValueError('empty or duplicate environment name')
    data = b'\0'.join(records) + b'\0\0'
    if len(data) > 128 * 1024 - 5:
        raise ValueError('environment exceeds the stock 128-KiB redundant slot')
    data = data.ljust(128 * 1024 - 5, b'\0')
    return (struct.pack('<I', zlib.crc32(data)) + b'\1' + data).ljust(1024 * 1024, b'\0')


def build(output):
    if output.exists() or output.is_symlink():
        raise FileExistsError(f'output must be new: {output}')
    dtc = shutil.which(os.environ.get('DTC', 'dtc'))
    if not dtc:
        raise ValueError('dtc is required')
    output.mkdir(parents=True)
    for source, target in [('kernel.dts', 'sunxi.dtb'), ('toc.dts', 'toc.dtb'),
                           ('u-boot-control.dts', 'u-boot-control.dtb')]:
        with (output / (target + '.log')).open('wb') as log:
            subprocess.run([dtc, '-I', 'dts', '-O', 'dtb', '-o', str(output / target),
                            str(SOURCE / source)], stderr=log, check=True)
    toc = (output / 'toc.dtb').read_bytes()
    if len(toc) > 59392:
        raise ValueError('TOC DTB exceeds the stock allocation')
    (output / 'toc-padded.dtb').write_bytes(toc.ljust(59392, b'\0'))
    env = environment((SOURCE / 'environment.txt').read_text(encoding='ascii'))
    for name in ('env.bin', 'env-redund.bin'):
        (output / name).write_bytes(env)
    artifacts = {}
    for name, expected in EXPECTED.items():
        data = (output / name).read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        artifacts[name] = {'bytes': len(data), 'sha256': actual,
                           'expected_sha256': expected, 'byte_identical': actual == expected}
    report = {'purpose': 'source-built non-executable stock board configuration',
              'dtc_version': subprocess.check_output([dtc, '--version'], text=True).strip(),
              'dtc_sha256': hashlib.sha256(Path(dtc).read_bytes()).hexdigest(),
              'sources': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in sorted(SOURCE.iterdir()) if p.suffix in ('.dts', '.txt')},
              'target_code_imported': False, 'artifacts': artifacts}
    (output / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
    if not all(item['byte_identical'] for item in artifacts.values()):
        raise ValueError(f'board data differs from stock; inspect {output / "comparison.json"}')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='new output directory')
    args = parser.parse_args()
    try:
        build(args.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')
    print(args.output / 'comparison.json')
