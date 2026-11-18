import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CanonicalGenerationTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('canonical', ROOT / 'scripts/check-canonical-generation.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in self.module.GENERATED:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('canonical')

    def generate_fixture(self, command):
        output = Path(command[command.index('--output-dir') + 1]).parent
        for name in self.module.GENERATED:
            path = output / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('canonical')
        return output

    def test_canonical_environment_discards_local_sdk_and_cache_selection(self):
        observed = {}
        def runner(command, **kwargs):
            self.generate_fixture(command)
            observed.update(kwargs['env'])
        self.module.verify_canonical(self.root, runner=runner, environ={
            'PATH': '/bin', 'ULTRACAM_SDK_INVENTORY': 'local.json',
            'ULTRACAM_WORK_ROOT': '/external/cache', 'AUTO_SWITCHER_LIB_DIR': '/local/lib'})
        self.assertEqual(observed, {'PATH': '/bin'})

    def test_changed_generated_file_is_a_failure(self):
        def runner(command, **kwargs):
            output = self.generate_fixture(command)
            (output / self.module.GENERATED[-1]).write_text('changed')
        with self.assertRaisesRegex(ValueError, 'generate_project.py'):
            self.module.verify_canonical(self.root, runner=runner, environ={})
        self.assertEqual((self.root / self.module.GENERATED[-1]).read_text(), 'canonical')


if __name__ == '__main__':
    unittest.main()
