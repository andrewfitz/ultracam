"""The Blackmagic adapter, native fixtures, SDK and assets have one owner."""
import unittest
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class BlackmagicLayoutTests(unittest.TestCase):
    def test_localization_table_is_explicit_app_only_resource(self):
        manifest = json.loads((ROOT / 'Vendors/Blackmagic/vendor.json').read_text())
        entries = [entry for entry in manifest['resources']
                   if entry['path'] == 'Resources/en.lproj/BlackmagicCapture.strings']
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['membership'], ['app'])

    def test_owned_allocator_include_is_explicit_app_and_test_dependency(self):
        manifest = json.loads((ROOT / 'Vendors/Blackmagic/vendor.json').read_text())
        entries = [entry for entry in manifest['sources'] if entry['path'] == 'Sources/OwnedCaptureAllocator.inc']
        self.assertEqual(len(entries), 1)
        self.assertEqual(set(entries[0]['membership']), {'app', 'test'})
        self.assertIn('#include "OwnedCaptureAllocator.inc"',
                      (ROOT / 'Vendors/Blackmagic/Sources/DeckLinkBackend.mm').read_text())

    def test_vendor_paths_replace_temporary_capture_boundary(self):
        for relative in (
            'Sources/DeckLinkBackend.h', 'Sources/DeckLinkBackend.mm',
            'Sources/DeckLinkCapturePlugin.swift', 'Tests/BackendTestSupport.inc',
            'Tests/DeckLinkChecks.swift', 'Tests/DeckLinkChecksAudioMetering.swift',
            'Tests/DeckLinkChecksAudioOvers.swift', 'Tests/DeckLinkAdapterContractChecks.swift',
            'SDK/include/DeckLinkAPI.h', 'SDK/include/DeckLinkAPIDispatch.cpp',
            'Resources/Assets.xcassets/BlackmagicLogo.imageset/Contents.json',
        ):
            with self.subTest(path=relative):
                self.assertTrue((ROOT / 'Vendors/Blackmagic' / relative).is_file())
        self.assertFalse((ROOT / 'Sources/DeckLinkBackend').exists())
        self.assertFalse((ROOT / 'Sources/DeviceAPI/DeckLinkCaptureAdapter.swift').exists())
        self.assertFalse((ROOT / 'ThirdParty/DeckLinkSDK').exists())

    def test_native_name_and_attachment_constant_have_single_owner(self):
        native = ROOT / 'Vendors/Blackmagic/Sources'
        header = (native / 'DeckLinkBackend.h').read_text()
        implementation = (native / 'DeckLinkBackend.mm').read_text()
        self.assertIn('NS_SWIFT_NAME(DeckLinkBackend)', header)
        self.assertIn('@interface UCDeckLinkBackend', header)
        self.assertNotIn('UltracamBackend', header + implementation)
        self.assertNotIn('NSString *const UltracamCaptureHostTimeAttachmentKey =', implementation)
        self.assertIn('static NSString *const UltracamCaptureHostTimeAttachmentKey =',
                      (ROOT / 'Sources/DeviceAPI/DeviceAPI.h').read_text())


if __name__ == '__main__':
    unittest.main()
