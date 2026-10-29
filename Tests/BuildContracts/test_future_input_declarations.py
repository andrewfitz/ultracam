"""Planned source permissions are declarations, not proof of new SDK support."""
from pathlib import Path
import plistlib
import unittest
ROOT = Path(__file__).resolve().parents[2]

class FutureInputDeclarationTests(unittest.TestCase):
    def test_host_declares_audio_and_planned_network_discovery(self):
        info = plistlib.loads((ROOT / 'Config/App-Info.plist').read_bytes())
        entitlements = plistlib.loads((ROOT / 'Config/App.entitlements').read_bytes())
        self.assertTrue(info.get('NSMicrophoneUsageDescription', '').strip())
        self.assertIn('_ndi._tcp', info.get('NSBonjourServices', []))
        self.assertTrue(info.get('NSLocalNetworkUsageDescription', '').strip())
        self.assertIs(entitlements.get('com.apple.security.device.audio-input'), True)

    def test_camera_extension_does_not_acquire_host_input_permissions(self):
        info = plistlib.loads((ROOT / 'Config/Camera-Info.plist').read_bytes())
        entitlements = plistlib.loads((ROOT / 'Config/Camera.entitlements').read_bytes())
        self.assertNotIn('NSMicrophoneUsageDescription', info)
        self.assertNotIn('NSBonjourServices', info)
        self.assertNotIn('com.apple.security.device.audio-input', entitlements)
