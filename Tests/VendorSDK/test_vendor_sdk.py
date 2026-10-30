"""Fixture-only SDK installations; never touch a developer's SDK."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import stat
import subprocess
import os
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))


class VendorSDKTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('vendor_sdk', ROOT / 'scripts/vendor-sdk.py')
        self.sdk = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.sdk)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.vendor = self.root / 'Vendors/Fixture'
        self.vendor.mkdir(parents=True)
        self.files = {'include/api.h': b'// SDK 1.2 licence\n', 'lib/runtime.dylib': b'fixture binary'}
        self.manifest = {'id': 'fixture', 'sdk': {'root': 'Vendors/Fixture/SDK', 'policy': 'local', 'optional': True,
            'version': '1.2', 'requiredFiles': ['Vendors/Fixture/SDK/include/api.h'],
            'fileSHA256': {'Vendors/Fixture/SDK/' + p: hashlib.sha256(v).hexdigest() for p, v in self.files.items()}}}

    def archive(self, files=None, name='sdk.zip'):
        path = self.root / name
        with zipfile.ZipFile(path, 'w') as output:
            for name, data in (self.files if files is None else files).items():
                output.writestr(name, data)
        return path

    def test_missing_optional_status_explains_source_build_and_required_verify_fails(self):
        status = self.sdk.status(self.manifest, self.root)
        self.assertFalse(status['available'])
        self.assertIn('source build', status['reason'])
        with self.assertRaises(ValueError):
            self.sdk.verify(self.manifest, self.root)

    def test_install_verify_version_stamp_and_no_source_changes(self):
        archive = self.archive()
        result = self.sdk.install(self.manifest, self.root, archive)
        self.assertTrue(result['available'])
        installed = self.vendor / 'SDK'
        stamp = json.loads((installed / '.ultracam-sdk.json').read_text())
        self.assertEqual(stamp['version'], '1.2')
        self.assertEqual(stamp['archiveSHA256'], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertTrue(self.sdk.verify(self.manifest, self.root)['available'])
        self.assertEqual((installed / 'include/api.h').read_bytes(), self.files['include/api.h'])
        with self.assertRaises(ValueError):
            self.sdk.install(self.manifest, self.root, archive)

    def test_install_preserves_committed_readme_only_tree(self):
        destination = self.vendor / 'SDK'
        destination.mkdir()
        readme = destination / 'README.md'
        readme.write_bytes(b'proprietary SDK installation instructions\n')
        result = self.sdk.install(self.manifest, self.root, self.archive())
        self.assertTrue(result['available'])
        self.assertEqual(readme.read_bytes(), b'proprietary SDK installation instructions\n')
        with self.assertRaises(ValueError):
            self.sdk.install(self.manifest, self.root, self.archive())

    def test_publication_failure_restores_readme_tree_and_allows_retry(self):
        destination = self.vendor / 'SDK'
        destination.mkdir()
        (destination / 'README.md').write_bytes(b'keep user instructions')
        archive = self.archive()
        link = self.sdk.os.link
        count = 0
        def fail_after_directory_creation(source, target):
            nonlocal count
            count += 1
            if count == 2:
                raise OSError('injected publication failure')
            return link(source, target)
        with patch.object(self.sdk.os, 'link', side_effect=fail_after_directory_creation):
            with self.assertRaisesRegex(OSError, 'publication failure'):
                self.sdk.install(self.manifest, self.root, archive)
        self.assertEqual([p.name for p in destination.iterdir()], ['README.md'])
        self.assertEqual((destination / 'README.md').read_bytes(), b'keep user instructions')
        self.assertTrue(self.sdk.install(self.manifest, self.root, archive)['available'])

    def test_publication_rollback_preserves_unrelated_new_directory_contents(self):
        destination = self.vendor / 'SDK'
        destination.mkdir()
        (destination / 'README.md').write_text('keep')
        def fail_with_unrelated_file(source, target):
            if target.parent != destination:
                (target.parent / 'user-notes.txt').write_text('do not delete')
                raise OSError('publication stopped')
            return link(source, target)
        link = self.sdk.os.link
        with patch.object(self.sdk.os, 'link', side_effect=fail_with_unrelated_file):
            with self.assertRaisesRegex(OSError, 'publication stopped'):
                self.sdk.install(self.manifest, self.root, self.archive())
        self.assertEqual((destination / 'include/user-notes.txt').read_text(), 'do not delete')
        self.assertEqual((destination / 'README.md').read_text(), 'keep')

    def test_checksum_missing_file_and_wrong_version_fail_before_install(self):
        for files in ({'include/api.h': b'wrong'}, {'include/api.h': self.files['include/api.h']},
                      dict(self.files, **{'.ultracam-sdk.json': json.dumps({'version': '9.0'}).encode()})):
            with self.subTest(files=files), self.assertRaises(ValueError):
                self.sdk.install(self.manifest, self.root, self.archive(files))
            self.assertFalse((self.vendor / 'SDK').exists())
        self.manifest['sdk']['sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            self.sdk.install(self.manifest, self.root, self.archive())

    def test_archive_traversal_duplicates_and_symlinks_fail(self):
        for bad in ('../escape', '/absolute', 'a/../../escape', 'C:/windows', 'a\\escape'):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.sdk.install(self.manifest, self.root, self.archive(dict(self.files, **{bad: b'x'})))
        archive = self.archive()
        with zipfile.ZipFile(archive, 'a') as output:
            entry = zipfile.ZipInfo('link')
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            output.writestr(entry, '../outside')
        with self.assertRaises(ValueError):
            self.sdk.install(self.manifest, self.root, archive)
        archive = self.archive(dict(self.files, **{'INCLUDE/API.H': b'collision'}))
        with self.assertRaises(ValueError):
            self.sdk.install(self.manifest, self.root, archive)

    def test_verify_detects_tamper_and_version_change(self):
        self.sdk.install(self.manifest, self.root, self.archive())
        file = self.vendor / 'SDK/include/api.h'
        file.write_bytes(b'tampered')
        self.assertFalse(self.sdk.status(self.manifest, self.root)['available'])
        file.write_bytes(self.files['include/api.h'])
        (self.vendor / 'SDK/.ultracam-sdk.json').write_text('{"version":"wrong"}')
        with self.assertRaises(ValueError):
            self.sdk.verify(self.manifest, self.root)

    def test_allowed_root_and_symlink_escape(self):
        self.manifest['sdk']['root'] = '../escape'
        with self.assertRaises(ValueError):
            self.sdk.install(self.manifest, self.root, self.archive())
        self.manifest['sdk']['root'] = 'Vendors/Fixture/SDK'
        (self.vendor / 'SDK').symlink_to(self.root / 'outside', target_is_directory=True)
        with self.assertRaises(ValueError):
            self.sdk.install(self.manifest, self.root, self.archive())

    def test_none_and_vendored_policy(self):
        self.assertTrue(self.sdk.status({'id': 'uvc'}, self.root)['available'])
        self.manifest['sdk']['policy'] = 'vendored'
        with self.assertRaises(ValueError):
            self.sdk.install(self.manifest, self.root, self.archive())

    def test_install_system_vendor_has_explanatory_error(self):
        with self.assertRaisesRegex(ValueError, 'no SDK'):
            self.sdk.install({'id': 'uvc'}, self.root, self.archive())

    def test_cli_missing_optional_status_and_unknown_vendor(self):
        raw = dict(schemaVersion=1, id='fixture', kinds=['control'], sources=[],
                   sdk=dict(self.manifest['sdk']))
        raw['sdk']['root'] = 'SDK'
        raw['sdk']['requiredFiles'] = ['SDK/include/api.h']
        raw['sdk']['fileSHA256'] = {'SDK/' + name: hashlib.sha256(data).hexdigest()
                                    for name, data in self.files.items()}
        (self.vendor / 'vendor.json').write_text(json.dumps(raw))
        command = [sys.executable, str(ROOT / 'scripts/vendor-sdk.py'), '--checkout-root', str(self.root), '--json']
        result = subprocess.run(command + ['status'], capture_output=True, text=True,
                                env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('source build', json.loads(result.stdout)[0]['reason'])
        result = subprocess.run(command + ['install', 'fixture', str(self.archive())], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)[0]['available'])
        result = subprocess.run(command + ['verify', 'unknown'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Traceback', result.stderr)

    def test_manifest_driven_nested_layout(self):
        self.manifest['sdk']['archiveLayout'] = {'nestedArchive': 'SimpleCli.zip', 'mappings': [
            {'prefix': 'app/CRSDK/', 'destination': 'include', 'flatten': True},
            {'prefix': 'external/crsdk/', 'destination': 'lib', 'flatten': False}]}
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, 'w') as output:
            output.writestr('app/CRSDK/api.h', self.files['include/api.h'])
            output.writestr('external/crsdk/runtime.dylib', self.files['lib/runtime.dylib'])
        result = self.sdk.install(self.manifest, self.root, self.archive({'SimpleCli.zip': inner.getvalue()}))
        self.assertTrue(result['available'])


if __name__ == '__main__':
    unittest.main()
