from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from publish_build import publish


class BuildPublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.artifacts = self.directory / 'artifacts'
        self.artifacts.mkdir()
        self.app = self.artifacts / 'Ultracam.app'
        self.symbols = self.artifacts / 'Ultracam.app.dSYM'

    def build(self, name, *, has_symbols=True):
        app = self.directory / name / 'Ultracam.app'
        app.mkdir(parents=True)
        if has_symbols:
            app.with_name(app.name + '.dSYM').mkdir()
        return app

    def test_debug_replaces_release_and_clears_its_symbols_alias(self):
        release = self.build('release')
        debug = self.build('debug', has_symbols=False)
        publish(release, self.artifacts)
        self.assertEqual(self.symbols.readlink(), release.with_name(self.symbols.name))
        publish(debug, self.artifacts)
        self.assertEqual(self.app.readlink(), debug)
        self.assertFalse(self.symbols.is_symlink())

    def test_failed_local_stage_preserves_the_published_pair(self):
        first = self.build('first')
        replacement = self.build('replacement')
        publish(first, self.artifacts)
        with (patch('publish_build.subprocess.run', side_effect=subprocess.CalledProcessError(1, 'stage')),
              self.assertRaises(subprocess.CalledProcessError)):
            publish(replacement, self.artifacts, local_development=True)
        self.assertEqual(self.app.readlink(), first)
        self.assertEqual(self.symbols.readlink(), first.with_name(self.symbols.name))

    def test_regular_symbols_directory_blocks_both_alias_changes(self):
        first = self.build('first', has_symbols=False)
        replacement = self.build('replacement')
        publish(first, self.artifacts)
        self.symbols.mkdir()
        with self.assertRaisesRegex(ValueError, 'non-symlink'):
            publish(replacement, self.artifacts)
        self.assertEqual(self.app.readlink(), first)
        self.assertTrue(self.symbols.is_dir())
        self.assertFalse(self.symbols.is_symlink())
