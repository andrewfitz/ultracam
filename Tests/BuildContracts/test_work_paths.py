"""Portable work paths must be safe to query before any build writes files."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/work_paths.py'


class WorkPathsTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('work_paths', SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.checkout = self.base / 'source checkout'
        self.checkout.mkdir()

    def paths(self, value=None):
        env = {} if value is None else {'ULTRACAM_WORK_ROOT': value}
        return self.module.work_paths(self.checkout, environ=env)

    def test_reusable_derived_data_cannot_escape_build_root(self):
        paths = self.paths()
        resolved = self.module.derived_data_path('xcode-shared', self.checkout, environ={})
        self.assertEqual(resolved, paths['build_root'] / 'xcode-shared')
        self.assertFalse(resolved.exists())
        for value in (self.checkout / 'Sources', paths['build_root'], self.base / 'outside'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.module.derived_data_path(value, self.checkout, environ={})
        paths['build_root'].mkdir(parents=True)
        (paths['build_root'] / 'escape').symlink_to(self.base, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.module.derived_data_path('escape/DerivedData', self.checkout, environ={})

    def test_default_is_checkout_build_without_creating_directories(self):
        paths = self.paths()
        self.assertEqual(paths['work_root'], self.checkout / '.build')
        self.assertFalse(paths['work_root'].exists())

    def test_designated_checkout_build_subtree_is_allowed(self):
        self.assertEqual(self.paths('.build/custom runs')['work_root'], self.checkout / '.build/custom runs')
        (self.checkout / '.build').symlink_to(self.checkout / 'Sources', target_is_directory=True)
        with self.assertRaises(ValueError):
            self.paths()

    def test_absolute_relative_and_spaces_resolve_from_checkout(self):
        for value in (str(self.base / 'work space'), '../work space'):
            with self.subTest(value=value):
                self.assertEqual(self.paths(value)['work_root'], self.base / 'work space')

    def test_rejects_empty_file_and_source_overlap(self):
        file = self.base / 'file'
        file.write_text('preserve')
        for value in ('', str(file), str(file / 'child'), '/', str(self.base), str(self.checkout), str(self.checkout / 'Sources/build')):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.paths(value)
        self.assertEqual(file.read_text(), 'preserve')
        self.assertEqual(list(self.checkout.iterdir()), [])

    def test_derived_paths_stay_below_root_and_symlink_escape_is_rejected(self):
        root = self.base / 'work'
        paths = self.paths(str(root))
        for key, path in paths.items():
            if key != 'work_root':
                self.assertTrue(path.is_relative_to(root))
                self.assertNotEqual(path, root)
        root.mkdir()
        (root / 'agent-work').symlink_to(self.checkout, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.paths(str(root))

    def test_cli_json_and_exact_path_preserve_shell_metacharacters(self):
        value = str(self.base / 'work space $(touch NEVER); quote\'')
        env = dict(os.environ, ULTRACAM_WORK_ROOT=value, PYTHONDONTWRITEBYTECODE='1')
        result = subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)['work_root'], value)
        result = subprocess.run([sys.executable, str(SCRIPT), '--path', 'tmp_root'], env=env, capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, value + '/tmp\n')
        self.assertFalse(Path(value).exists())

    def test_cli_invalid_root_fails_cleanly(self):
        result = subprocess.run([sys.executable, str(SCRIPT)], env=dict(os.environ, ULTRACAM_WORK_ROOT='/'), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('work_paths:', result.stderr)
        self.assertNotIn('Traceback', result.stderr)


if __name__ == '__main__':
    unittest.main()
