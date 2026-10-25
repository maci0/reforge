#!/usr/bin/env python3
"""Apply and check the lazy-import patch against a supplied Klipper source tree."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
from unittest.mock import Mock, patch

REPO = Path(__file__).resolve().parents[2]


def check(source):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for name in ('mathutil.py', 'extras/adxl345.py',
                     'extras/shaper_calibrate.py'):
            dest = root / 'klippy' / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / 'klippy' / name, dest)
        subprocess.run(
            ['patch', '-p1', '--batch', '--fuzz=0', '-i', str(REPO /
             'br-external/package/klipper/0007-defer-multiprocessing-imports.patch')],
            cwd=root, check=True)
        # Stub printer dependencies; execute the complete patched modules.
        extras = types.ModuleType('extras')
        extras.__path__ = []
        modules = {'extras': extras, 'queuelogger': types.ModuleType('queuelogger')}
        for name in ('bus', 'motion_report', 'shaper_defs'):
            modules['extras.' + name] = types.ModuleType('extras.' + name)
        with patch.dict(sys.modules, modules):
            loaded = {}
            real_import = __import__
            imports = []

            def track(name, *args, **kwargs):
                imports.append(name)
                return real_import(name, *args, **kwargs)

            with patch('builtins.__import__', side_effect=track):
                for name in ('mathutil', 'extras.adxl345', 'extras.shaper_calibrate'):
                    path = root / 'klippy' / (name.replace('.', '/') + '.py')
                    namespace = {'__name__': name, '__package__': name.rpartition('.')[0]}
                    exec(compile(path.read_text(), str(path), 'exec'), namespace)
                    loaded[name] = namespace
            assert 'multiprocessing' not in imports, imports

            class ProcessReached(Exception):
                pass

            process_api = types.ModuleType('multiprocessing')
            process_api.Pipe = Mock(side_effect=ProcessReached)
            process_api.Process = Mock(side_effect=ProcessReached)
            with patch.dict(sys.modules, {'multiprocessing': process_api}):
                mathutil = loaded['mathutil']
                adxl = loaded['extras.adxl345']
                shaper = loaded['extras.shaper_calibrate']
                helper = shaper['ShaperCalibrate'].__new__(shaper['ShaperCalibrate'])
                helper.printer = None
                assert helper.background_process_exec(lambda x: x + 1, (2,)) == 3
                process_api.Pipe.assert_not_called()
                helper.printer = object()
                for call in (
                    lambda: mathutil['background_coordinate_descent'](None, [], {}, None),
                    lambda: adxl['AccelQueryHelper'].write_to_file(None, 'unused.csv'),
                    lambda: helper.background_process_exec(lambda: None, ()),
                ):
                    try:
                        call()
                    except ProcessReached:
                        pass
                    else:
                        raise AssertionError('Deferred process API was not reached')
                assert process_api.Pipe.call_count == 2
                process_api.Process.assert_called_once()
    print('Klipper lazy imports: startup and deferred call paths passed')


if __name__ == '__main__':
    check(Path(sys.argv[1]).resolve())
