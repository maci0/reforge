#!/usr/bin/env python3
"""Check patch 0003 against a pinned Moonraker tree (before patch 0003)."""
import ast
import asyncio
import builtins
from enum import Enum
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
from unittest.mock import Mock, patch

REPO = Path(__file__).resolve().parents[2]
PACKAGE = 'moonraker.components.update_manager'


def check(source):
    with tempfile.TemporaryDirectory() as tmp:
        relative = Path('moonraker/components/update_manager/update_manager.py')
        target = Path(tmp) / relative
        target.parent.mkdir(parents=True)
        shutil.copyfile(source / relative, target)
        subprocess.run(['patch', '-p1', '--batch', '--fuzz=0', '-i', str(REPO /
                        'br-external/package/moonraker/0003-lazy-import-update-backends.patch')],
                       cwd=tmp, check=True)
        # Use upstream's actual enums; stub services and deployment side effects.
        enums = {'Enum': Enum}
        for path, name in (('moonraker/common.py', 'ExtendedEnum'),
                           ('moonraker/components/update_manager/common.py', 'AppType')):
            tree = ast.parse((source / path).read_text())
            node = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == name)
            exec('from __future__ import annotations\n' + ast.unparse(node), enums)
        AppType = enums['AppType']

        class BaseDeploy:
            set_command_helper = Mock()

            def __init__(self, *args):
                pass

        classes = {name: type(name, (BaseDeploy,), {}) for name in
                   ('AppDeploy', 'NetDeploy', 'GitDeploy', 'PythonDeploy', 'PackageDeploy')}
        modules = {}

        def module(name, **attrs):
            value = types.ModuleType(name)
            value.__dict__.update(attrs)
            modules[name] = value

        for name in ('moonraker', 'moonraker.components', PACKAGE, 'moonraker.utils'):
            module(name, __path__=[])
        module(PACKAGE + '.common', AppType=AppType, get_base_configuration=lambda c: {
            'moonraker': {'type': AppType.ZIP},
            'klipper': {'type': AppType.ZIP, 'path': '/', 'env': '/'}})
        module(PACKAGE + '.base_deploy', BaseDeploy=BaseDeploy)
        for name, cls in (('app_deploy', 'AppDeploy'), ('net_deploy', 'NetDeploy'),
                          ('git_deploy', 'GitDeploy'), ('python_deploy', 'PythonDeploy'),
                          ('system_deploy', 'PackageDeploy')):
            module(PACKAGE + '.' + name, **{cls: classes[cls]})
        module('moonraker.common', RequestType=Mock())
        module('moonraker.utils.filelock', AsyncExclusiveFileLock=Mock(), LockTimeout=Exception)
        imports = []
        real_import = builtins.__import__

        def track(name, *args, **kwargs):
            imports.append(name)
            return real_import(name, *args, **kwargs)

        with patch.dict(sys.modules, modules), patch('builtins.__import__', side_effect=track):
            ns = {'__name__': PACKAGE + '.update_manager', '__package__': PACKAGE}
            exec(compile(target.read_text(), str(target), 'exec'), ns)
            ns['CommandHelper'] = Mock()
            ns['InstanceTracker'] = Mock()
            config = Mock()
            config.getintlist.return_value = [0, 5]
            config.get.return_value = None
            config.get_prefix_sections.return_value = []
            config.getboolean.return_value = False
            manager = ns['UpdateManager'](config)
            assert type(manager.updaters['moonraker']) is classes['NetDeploy']
            assert type(manager.updaters['klipper']) is classes['NetDeploy']
            assert not {'git_deploy', 'python_deploy', 'system_deploy'} & set(imports), imports

            factory = ns['get_deploy_class']
            for key in ('web', 'zip', 'executable'):
                assert factory(key, None) is classes['NetDeploy']
            sentinel = object()
            assert factory(AppType.NONE, sentinel) is sentinel
            try:
                factory('invalid', sentinel)
            except ValueError:
                pass
            else:
                raise AssertionError('Invalid deployment type was accepted')
            for key, cls, mod in (('git_repo', 'GitDeploy', 'git_deploy'),
                                  ('python', 'PythonDeploy', 'python_deploy')):
                imports.clear()
                assert factory(key, None) is classes[cls]
                assert mod in imports
                assert factory(AppType.from_string(key), None) is classes[cls]
            config.getboolean.side_effect = lambda name, default: name == 'enable_system_updates'
            imports.clear()
            manager = ns['UpdateManager'](config)
            assert type(manager.updaters['system']) is classes['PackageDeploy']
            assert 'system_deploy' in imports

            # A ZIP updater must still be rejected by Git repository recovery.
            manager.kconn.is_printing.return_value = False
            manager.server.error.side_effect = lambda message, *args: RuntimeError(message)
            request = Mock()
            request.get_str.return_value = 'moonraker'
            try:
                asyncio.run(manager._handle_repo_recovery(request))
            except RuntimeError as exc:
                assert 'not a Git Repo Type' in str(exc)
            else:
                raise AssertionError('ZIP updater accepted for Git recovery')
    print('Moonraker lazy imports: startup, backend selection and recovery checks passed')


if __name__ == '__main__':
    check(Path(sys.argv[1]).resolve())
