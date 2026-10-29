"""Security and reproducibility constraints for the versioned vendor schema."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

class VendorManifestTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('vendors', ROOT / 'scripts/vendors.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.vendor = self.root / 'Vendors/Example'
        self.vendor.mkdir(parents=True)
        (self.vendor / 'Source.swift').write_text('// fixture')

    def manifest(self):
        return {'schemaVersion': 1, 'id': 'example', 'kinds': ['capture'],
                'sources': [{'path': 'Source.swift', 'membership': ['app', 'test']}],
                'publicHeaders': [], 'headerSearchPaths': [], 'frameworks': [],
                'libraries': [], 'defines': [], 'embedLibraries': [],
                'tests': [], 'capabilities': {'entitlements': [], 'infoPlist': []}}

    def test_accepts_typed_membership_and_stable_digest(self):
        result = self.module.validate_manifest(self.manifest(), self.vendor / 'vendor.json', self.root)
        self.assertEqual(result['id'], 'example')
        self.assertEqual(self.module.input_digest([result], {'b': False, 'a': True}),
                         self.module.input_digest([dict(reversed(list(result.items())))], {'a': True, 'b': False}))

    def test_rejects_escape_extension_and_shell_flags(self):
        for mutate in (
            lambda m: m['sources'][0].update(path='../../../outside.swift'),
            lambda m: m['sources'][0].update(membership=['extension']),
            lambda m: m.update(linkFlags=['-Xlinker', '$(touch /tmp/pwn)']),
            lambda m: m.update(schemaVersion=900),
        ):
            value = self.manifest()
            mutate(value)
            with self.assertRaises(ValueError):
                self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)

    def test_sdk_inventory_is_explicit_and_canonical_absence_is_relocatable(self):
        value = self.manifest()
        value['sdk'] = {'policy': 'local', 'version': '1.2', 'requiredFiles': ['SDK/core.dylib']}
        value['headerSearchPaths'] = ['SDK/include']
        value['embedLibraries'] = [{'path': 'SDK/core.dylib', 'subfolder': 'CrAdapter'}]
        result = self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)
        self.assertEqual(result['sdk']['requiredFiles'], ['Vendors/Example/SDK/core.dylib'])
        absent = self.module.resolve_sdk_inventory([result], {}, self.root)
        self.assertFalse(absent['example']['available'])
        with self.assertRaises(ValueError):
            self.module.resolve_sdk_inventory([result], {'example': True}, self.root)
        (self.vendor / 'SDK').mkdir()
        (self.vendor / 'SDK/core.dylib').write_bytes(b'fixture')
        self.assertFalse(self.module.resolve_sdk_inventory([result], {}, self.root)['example']['available'])
        self.assertTrue(self.module.resolve_sdk_inventory([result], {'example': True}, self.root)['example']['available'])

    def test_required_vendored_sdk_and_conditional_build_settings(self):
        (self.vendor / 'SDK').mkdir()
        (self.vendor / 'SDK/Required.h').write_text('// required')
        value = self.manifest()
        value['sdk'] = {'policy': 'vendored', 'optional': False, 'version': '2',
                        'requiredFiles': ['SDK/Required.h'],
                        'enabledBuild': {'defines': ['EXAMPLE_SDK=1'], 'libraries': ['Example']}}
        result = self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)
        self.assertTrue(self.module.resolve_sdk_inventory([result], {}, self.root)['example']['available'])
        self.assertEqual(result['sdk']['enabledBuild']['defines'], ['EXAMPLE_SDK=1'])
        with self.assertRaises(ValueError):
            self.module.resolve_sdk_inventory([result], {'example': False}, self.root)
        value['sdk']['enabledBuild']['linkFlags'] = ['$(touch /tmp/pwn)']
        with self.assertRaises(ValueError):
            self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)

    def test_vendor_asset_catalog_has_explicit_membership(self):
        (self.vendor / 'Resources/Example.xcassets').mkdir(parents=True)
        value = self.manifest()
        value['resources'] = [{'path': 'Resources/Example.xcassets', 'membership': ['app']}]
        result = self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)
        self.assertEqual(result['resources'][0]['path'], 'Vendors/Example/Resources/Example.xcassets')
        value['resources'][0]['membership'] = ['extension']
        with self.assertRaises(ValueError):
            self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)

    def test_sdk_dispatch_source_requires_explicit_external_cache(self):
        cache = tempfile.TemporaryDirectory()
        self.addCleanup(cache.cleanup)
        cached = Path(cache.name)
        (cached / 'Dispatch.cpp').write_text('// SDK fixture')
        (self.vendor / 'SDK').symlink_to(cached, target_is_directory=True)
        value = self.manifest()
        value['sources'] = [{'path': 'SDK/Dispatch.cpp', 'membership': ['app', 'test']}]
        with self.assertRaises(ValueError):
            self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)
        result = self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root, sdk_roots=(cached,))
        self.assertEqual(result['sources'][0]['path'], str((cached / 'Dispatch.cpp').resolve()))

    def test_typed_test_groups_and_test_only_flags(self):
        value = self.manifest()
        value['testBuild'] = {'defines': ['EXAMPLE_TESTING=1']}
        value['testGroups'] = {'control': {'swiftSources': ['Source.swift'], 'nativeSources': [], 'sdk': False}}
        result = self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)
        self.assertEqual(result['testBuild']['defines'], ['EXAMPLE_TESTING=1'])
        self.assertEqual(result['testGroups']['control']['swiftSources'], ['Vendors/Example/Source.swift'])
        value['testGroups']['control']['command'] = 'touch /tmp/pwn'
        with self.assertRaises(ValueError):
            self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)

    def test_sdk_pin_rejects_same_version_replacement(self):
        import hashlib
        (self.vendor / 'SDK').mkdir()
        binary = self.vendor / 'SDK/core.dylib'
        binary.write_bytes(b'approved')
        value = self.manifest()
        value['sdk'] = {'policy': 'local', 'version': '2.2.0', 'requiredFiles': ['SDK/core.dylib'],
                        'fileSHA256': {'SDK/core.dylib': hashlib.sha256(b'approved').hexdigest()}}
        result = self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)
        self.assertIsNone(result['sdk']['sha256'], 'A file pin is not an archive checksum')
        self.assertTrue(self.module.resolve_sdk_inventory([result], {'example': True}, self.root)['example']['available'])
        binary.write_bytes(b'replaced')
        self.assertFalse(self.module.resolve_sdk_inventory([result], {}, self.root)['example']['available'])
        with self.assertRaises(ValueError):
            self.module.resolve_sdk_inventory([result], {'example': True}, self.root)

    def test_sdk_archive_layout_and_external_driver_roots_are_data(self):
        value = self.manifest()
        value['sdk'] = {'policy': 'local', 'version': '2', 'requiredFiles': ['SDK/a.h'],
            'archiveLayout': {'nestedArchive': 'SimpleCli.zip', 'mappings': [
                {'prefix': 'app/CRSDK/', 'destination': 'include', 'flatten': True}]},
            'externalDrivers': ['/Library/Frameworks/DeckLinkAPI.framework']}
        result = self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)
        self.assertEqual(result['sdk']['archiveLayout']['nestedArchive'], 'SimpleCli.zip')
        value['sdk']['archiveLayout']['mappings'][0]['destination'] = '../escape'
        with self.assertRaises(ValueError):
            self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)
        value['sdk']['archiveLayout']['mappings'][0]['destination'] = 'include'
        value['sdk']['externalDrivers'] = ['/Library']
        with self.assertRaises(ValueError):
            self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)

    def test_rejects_symlink_escape(self):
        (self.vendor / 'Escape.swift').symlink_to('/etc/passwd')
        value = self.manifest()
        value['sources'][0]['path'] = 'Escape.swift'
        with self.assertRaises(ValueError):
            self.module.validate_manifest(value, self.vendor / 'vendor.json', self.root)

if __name__ == '__main__':
    unittest.main()
