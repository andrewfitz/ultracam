"""Input permissions belong only to the host."""
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

    def test_host_declares_camera_permissions_and_continuity_opt_in(self):
        info = plistlib.loads((ROOT / 'Config/App-Info.plist').read_bytes())
        entitlements = plistlib.loads((ROOT / 'Config/App.entitlements').read_bytes())
        self.assertTrue(info.get('NSCameraUsageDescription', '').strip())
        self.assertIs(info.get('NSCameraUseContinuityCameraDeviceType'), True)
        self.assertIs(entitlements.get('com.apple.security.device.camera'), True)

    def test_camera_extension_does_not_acquire_host_input_permissions(self):
        info = plistlib.loads((ROOT / 'Config/Camera-Info.plist').read_bytes())
        entitlements = plistlib.loads((ROOT / 'Config/Camera.entitlements').read_bytes())
        self.assertNotIn('NSMicrophoneUsageDescription', info)
        self.assertNotIn('NSCameraUsageDescription', info)
        self.assertNotIn('NSCameraUseContinuityCameraDeviceType', info)
        self.assertNotIn('NSBonjourServices', info)
        self.assertNotIn('com.apple.security.device.audio-input', entitlements)
        self.assertNotIn('com.apple.security.device.camera', entitlements)
