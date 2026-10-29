"""The final project and every compiler entry point share one vendor inventory."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ManifestActivationTests(unittest.TestCase):
    def test_manifest_inventory_and_generated_bridge_exist(self):
        for vendor, identity in (('Blackmagic', 'decklink'), ('Sony', 'sony')):
            manifest = json.loads((ROOT / 'Vendors' / vendor / 'vendor.json').read_text())
            self.assertEqual(manifest['id'], identity)
        header = (ROOT / 'Sources/DeviceAPI/GeneratedBridgingHeader.h').read_text()
        self.assertIn('DeviceAPI.h', header)
        self.assertIn('Vendors/Blackmagic/Sources/DeckLinkBackend.h', header)
        self.assertIn('Vendors/Sony/Sources/SonyCameraControl.h', header)
        self.assertFalse((ROOT / 'Sources/DeckLinkBackend/BridgingHeader.h').exists())

    def test_all_build_entry_points_use_shared_manifest_reader(self):
        for name in ('generate_project.py', 'test.sh', 'ui-typecheck.sh', 'ui-verify.sh',
                     'monitor-app-integration.sh', 'monitor-feed-host-checks.sh',
                     'sony-control-checks.sh', 'sony-credential-checks.sh',
                     'sony-hardware-smoke.sh', 'sony-sandbox-ui-check.sh'):
            with self.subTest(script=name):
                text = (ROOT / 'scripts' / name).read_text()
                self.assertTrue('vendor-build.sh' in text or 'from vendors import' in text)
                self.assertNotIn('Sources/DeckLinkBackend/', text)
                self.assertNotIn('ThirdParty/SonyCameraRemoteSDK', text)

    def test_canonical_project_is_optional_sdk_absent_and_guarded(self):
        project = (ROOT / 'Ultracam.xcodeproj/project.pbxproj').read_text()
        self.assertNotIn('ULTRACAM_SONY_SDK=1', project)
        self.assertNotIn('-lCr_Core', project)
        self.assertIn('Check Vendor Inputs', project)
        self.assertIn('GeneratedBridgingHeader.h', project)
        self.assertNotIn('Sources/DeckLinkBackend/', project)

if __name__ == '__main__':
    unittest.main()
