from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import prepare_local_build as stage


class PreparationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.source = self.root / 'input.app'
        self.destination = self.root / 'staged.app'
        self.make_app(self.source, False)

    def make_app(self, path, marked):
        contents = path / 'Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': stage.APP_ID, stage.LOCAL_MARKER: marked,
            'CFBundleExecutable': 'Ultracam',
        }))

    def run_stage(self):
        with patch.object(sys, 'argv', ['stage', str(self.source), str(self.destination)]), \
             patch.object(stage, 'validate'):
            stage.main()

    def test_source_at_destination_symbols_is_preserved(self):
        self.source = self.source.rename(self.root / 'staged.app.dSYM')
        with self.assertRaisesRegex(SystemExit, 'separate'):
            self.run_stage()
        self.assertTrue((self.source / 'Contents/Info.plist').exists())

    def test_unrelated_symbols_directory_is_preserved(self):
        existing = self.root / 'staged.app.dSYM'
        existing.mkdir()
        (existing / 'user-file').touch()
        with self.assertRaisesRegex(SystemExit, 'without their staged'):
            self.run_stage()
        self.assertTrue((existing / 'user-file').exists())
        self.assertFalse(self.destination.exists())

    def test_signing_failure_preserves_previous_bundle(self):
        self.make_app(self.destination, True)
        sentinel = self.destination / 'old'
        sentinel.touch()
        with patch.object(stage.subprocess, 'run') as lsof, \
             patch.object(stage, 'sign_and_validate', side_effect=ValueError('test failure')):
            lsof.return_value.returncode = 1
            lsof.return_value.stdout = b''
            with self.assertRaisesRegex(ValueError, 'test failure'):
                self.run_stage()
        self.assertTrue(sentinel.exists())
