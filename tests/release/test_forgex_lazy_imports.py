#!/usr/bin/env python3
"""Check the experimental Forge-X patch against the local firmware fixture."""
import ast
import enum
import pathlib
import shutil
import subprocess
import tempfile
import types
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'tests/qemu-harness/build/forgex-rootfs.ext4'
PATCH = ROOT / 'tests/qemu-harness/patches/forgex-lazy-update-backends.patch'


@unittest.skipUnless(FIXTURE.exists() and shutil.which('debugfs'), 'Forge-X fixture required')
class LazyImports(unittest.TestCase):
    def test_backend_selection_and_deferred_imports(self):
        original = subprocess.check_output([
            'debugfs', '-R', 'cat /opt/config/mod/.root/moonraker/components/'
            'update_manager/update_manager.py', str(FIXTURE)], stderr=subprocess.DEVNULL)
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'update_manager.py'
            path.write_bytes(original)
            subprocess.run(['patch', '--batch', '--fuzz=0', str(path), str(PATCH)],
                           check=True, capture_output=True)
            tree = ast.parse(path.read_text())
        compile(tree, 'update_manager.py', 'exec')
        eager = [n.module for n in tree.body if isinstance(n, ast.ImportFrom)]
        for backend in ('zip_deploy', 'python_deploy', 'system_deploy'):
            self.assertNotIn(backend, eager)
        system_imports = [n for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)
                          and n.module == 'system_deploy']
        self.assertEqual(len(system_imports), 2)  # type checking and enabled branch
        manager = next(n for n in tree.body if isinstance(n, ast.ClassDef)
                       and n.name == 'UpdateManager')
        enabled = next(n for n in ast.walk(manager) if isinstance(n, ast.If)
                       and 'enable_system_updates' in ast.unparse(n.test))
        self.assertEqual(enabled.body[0].module, 'system_deploy')

        class AppType(enum.Enum):
            WEB = 1
            ZIP = 2
            GIT_REPO = 3
            PYTHON = 4
            NONE = 5

            @classmethod
            def from_string(cls, value):
                return cls[value.upper()]

        imports = []
        classes = {name: type(name, (), {}) for name in ('ZipDeploy', 'PythonDeploy')}

        def load(name, globals=None, locals=None, fromlist=(), level=0):
            imports.append(name)
            self.assertIn(name, ('zip_deploy', 'python_deploy'))
            return types.SimpleNamespace(**classes)

        function = next(n for n in tree.body if isinstance(n, ast.FunctionDef)
                        and n.name == 'get_deploy_class')
        function.returns = None
        for arg in function.args.args:
            arg.annotation = None
        namespace = {'AppType': AppType, 'GitDeploy': object(),
                     '__builtins__': {'__import__': load, 'isinstance': isinstance, 'str': str}}
        exec(compile(ast.Module(body=[function], type_ignores=[]), 'selection', 'exec'), namespace)
        select = namespace['get_deploy_class']
        default = object()
        self.assertIs(select(AppType.NONE, default), default)
        self.assertIs(select('git_repo', default), namespace['GitDeploy'])
        self.assertEqual(imports, [])
        for key in (AppType.WEB, AppType.ZIP):
            self.assertIs(select(key, default), classes['ZipDeploy'])
        self.assertIs(select('python', default), classes['PythonDeploy'])
        self.assertEqual(imports, ['zip_deploy', 'zip_deploy', 'python_deploy'])


if __name__ == '__main__':
    unittest.main()
