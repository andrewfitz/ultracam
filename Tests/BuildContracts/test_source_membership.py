"""All compilers consume DeviceAPI; standalone vendor groups use live core APIs."""
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

class SourceMembershipTests(unittest.TestCase):
    def test_all_app_compile_paths_include_device_api(self):
        for name in ('test.sh', 'ui-typecheck.sh', 'ui-verify.sh',
                     'monitor-app-integration.sh', 'monitor-feed-host-checks.sh'):
            with self.subTest(script=name):
                self.assertIn('/Sources/DeviceAPI/*.swift', (ROOT / 'scripts' / name).read_text())
                self.assertIn('vendor-build.sh', (ROOT / 'scripts' / name).read_text())

    def test_test_compile_is_strict_and_enables_fixtures(self):
        source = (ROOT / 'scripts/test.sh').read_text()
        self.assertIn('-strict-concurrency=complete -warnings-as-errors', source)
        self.assertIn('-D ULTRACAM_TEST_SUPPORT', source)

    def test_sony_tools_support_build_only_and_use_manifest_reader(self):
        self.assertIn('--build-only', (ROOT / 'scripts/sony-hardware-smoke.sh').read_text())
        for name in ('sony-control-checks.sh', 'sony-credential-checks.sh',
                     'sony-hardware-smoke.sh', 'sony-sandbox-ui-check.sh'):
            with self.subTest(script=name):
                text = (ROOT / 'scripts' / name).read_text()
                self.assertIn('vendor-build.sh', text)
                self.assertNotIn('Sources/DeckLinkBackend/', text)

    def test_standalone_groups_exercise_live_generic_contract(self):
        spec = importlib.util.spec_from_file_location('vendors', ROOT / 'scripts/vendors.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest = next(m for m in module.load_manifests(ROOT) if m['id'] == 'sony')
        for name in ('control', 'sandbox', 'credentials'):
            with self.subTest(group=name):
                sources = manifest['testGroups'][name]['swiftSources']
                self.assertIn('Sources/App/CameraControlCredentials.swift', sources)
                self.assertIn('Vendors/Sony/Sources/SonyControlPlugin.swift', sources)
                self.assertNotIn('Sources/App/SonyCameraCredentials.swift', sources)
                if name != 'credentials':
                    self.assertIn('Sources/App/CameraControlStore.swift', sources)
                    self.assertIn('Sources/App/UIControlPresentation.swift', sources)

    def test_mac_camera_uses_the_same_sources_in_the_app_and_test_compilers(self):
        spec = importlib.util.spec_from_file_location('vendors', ROOT / 'scripts/vendors.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifests, inventory = module.read_inventory(ROOT)
        manifest = next(m for m in manifests if m['id'] == 'maccamera')
        self.assertNotIn('sdk', manifest)
        self.assertFalse(inventory['maccamera']['available'])
        self.assertEqual(manifest['kinds'], ['capture'])
        self.assertIn('AVFoundation', module.build_settings(manifests, inventory, vendor='maccamera')['frameworks'])
        self.assertCountEqual(manifest['capabilities']['entitlements'],
                              ['com.apple.security.device.camera', 'com.apple.security.device.audio-input'])
        self.assertCountEqual(manifest['capabilities']['infoPlist'],
                              ['NSCameraUsageDescription', 'NSMicrophoneUsageDescription',
                               'NSCameraUseContinuityCameraDeviceType'])
        app = set(module.source_paths(manifests, membership='app', vendor='maccamera'))
        test = set(module.source_paths(manifests, membership='test', vendor='maccamera'))
        self.assertIn('Vendors/MacCamera/Sources/MacCameraCapturePlugin.swift', app)
        self.assertLess(app, test)
        self.assertIn('Vendors/MacCamera/Tests/MacCameraReusableConformanceChecks.swift', test - app)
        with tempfile.TemporaryDirectory() as work:
            subprocess.run(
                ['bash', '-eu', '-c', 'source scripts/vendor-build.sh\n'
                 'vendor_configure app maccamera\n'
                 '[[ -z "$vendor_sdk_root" && -z "$vendor_bridge" ]]'],
                cwd=ROOT, env=dict(os.environ, task_root=str(ROOT), check_root=work, test_root=''),
                check=True, capture_output=True)

    def test_generator_isolates_fakes_and_shares_format_with_extension(self):
        source = (ROOT / 'scripts/generate_project.py').read_text()
        self.assertIn('Sources/DeviceAPI', source)
        self.assertIn('Fake', source)
        self.assertIn('Sources/Shared/SourceFormat.swift', source)

if __name__ == '__main__':
    unittest.main()
