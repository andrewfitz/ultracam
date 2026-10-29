"""Focused boundary fixtures: python3 -m unittest discover -s Tests/BoundaryContracts."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/check-vendor-boundaries.py'

class VendorBoundaryChecks(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('vendor_boundaries', SCRIPT)
        self.checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.checker)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, path, text):
        dest = self.root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)
        return path

    def audit(self, manifests=(), targets=None):
        return '\n'.join(self.checker.audit(self.root, manifests, targets or {}))

    def test_new_unbranded_plugin_type_and_call_are_discovered(self):
        source = self.write('Vendors/Acme/Sources/Plugin.swift', 'struct FreshDevice {}\nfunc freshDeviceStart() {}\n')
        self.write('Sources/App/New.swift', 'let device = FreshDevice()\nfreshDeviceStart()\n')
        result = self.audit([{'id': 'acme', 'sources': [{'path': source, 'membership': ['app']}], 'publicHeaders': []}])
        self.assertIn('plugin-symbol', result)
        self.assertIn('FreshDevice', result)
        self.assertIn('freshDeviceStart', result)

    def test_brand_names_imports_and_native_sdk_symbols_fail(self):
        self.write('Sources/App/New.swift', 'import DeckLinkAPI\nlet device: IDeckLinkInput?\nlet label = "Sony FX3"\n')
        result = self.audit()
        self.assertIn('vendor-name', result)
        self.assertIn('vendor-import', result)
        self.assertIn('sdk-symbol', result)

    def test_registry_registration_is_narrow(self):
        source = self.write('Vendors/Sony/Sources/Plugin.swift', 'struct SonyControlPlugin {}\nstruct SonySecret {}\n')
        manifest = {'id': 'sony', 'sources': [{'path': source, 'membership': ['app']}], 'publicHeaders': []}
        self.write('Sources/DeviceAPI/VendorRegistry.swift', 'static let control: [any CameraControlPlugin] = [SonyControlPlugin()]\n')
        self.assertEqual(self.audit([manifest]), '')
        self.write('Sources/DeviceAPI/VendorRegistry.swift', 'let bad = SonySecret()\n')
        self.assertIn('plugin-symbol', self.audit([manifest]))

    def test_color_lut_migration_and_preview_exceptions_are_token_scoped(self):
        self.write('Sources/Shared/Presets.swift', 'let profile = "sony-slog3-sgamut3cine"\nlet mode = SonySLog3FalseColor.profileID\n')
        self.write('Sources/App/UIContext.swift', 'let name = "UltraStudio Mini Recorder 12G"\nlet lut = "FX3_SLog3_to_709.cube"\n')
        self.write('Sources/App/VendorSettingsStore.swift', 'let key = "decklink:advertiseHDRToCameras"\n')
        self.assertEqual(self.audit(), '')
        self.write('Sources/Shared/Presets.swift', 'let profile = "sony-slog3-sgamut3cine"; SonySecret()\n')
        self.assertIn('vendor-name', self.audit())
        self.write('Sources/App/VendorSettingsStore.swift', 'let key = "decklink:advertiseHDRToCameras"; DeckLinkCapturePlugin()\n')
        self.assertIn('vendor-name', self.audit())

    def test_config_exceptions_do_not_exempt_whole_file(self):
        self.write('Config/App-Info.plist', '<string>Discover and control Sony cameras over Wi-Fi while video arrives over HDMI.</string>\n')
        self.assertEqual(self.audit(), '')
        self.write('Config/App-Info.plist', '<string>Sony secret feature</string>\n')
        self.assertIn('vendor-name', self.audit())

    def test_vendor_to_app_type_and_import_are_rejected_shared_values_allowed(self):
        self.write('Sources/App/Controller.swift', 'final class CaptureController {}\n')
        self.write('Sources/Shared/VideoContract.swift', 'enum VideoContract {}\n')
        source = self.write('Vendors/Acme/Sources/Plugin.swift', 'import App\nlet controller: CaptureController?\nlet duration = VideoContract.fastDuration\n')
        manifest = {'id': 'acme', 'sources': [{'path': source, 'membership': ['app']}], 'publicHeaders': []}
        result = self.audit([manifest])
        self.assertIn('core-import', result)
        self.assertIn('core-symbol', result)
        self.assertNotIn('VideoContract', result)

    def test_generated_bridge_must_match_validated_headers_exactly(self):
        path = 'Sources/DeviceAPI/GeneratedBridgingHeader.h'
        self.write(path, self.checker.vendors.render_bridge([]))
        self.assertEqual(self.audit(), '')
        self.write(path, self.checker.vendors.render_bridge([]) + '#import "DeckLinkAPI.h"\n')
        self.assertIn('generated-bridge', self.audit())

    def test_fake_definitions_and_references_need_positive_test_guard(self):
        self.write('Sources/DeviceAPI/FakeCapturePlugin.swift', '#if ULTRACAM_TEST_SUPPORT\nstruct FakeCapturePlugin {}\n#endif\n')
        self.write('Sources/App/AppHardwareSyntheticFixture.swift', '#if ULTRACAM_TEST_SUPPORT\nclass AppHardwareSyntheticFixture { let plugin = FakeCapturePlugin() }\n#endif\n')
        self.assertEqual(self.audit(), '')
        self.write('Sources/App/New.swift', '#if !ULTRACAM_TEST_SUPPORT\nlet fixture = AppHardwareSyntheticFixture()\n#endif\n')
        self.assertIn('test-guard', self.audit())
        self.write('Sources/App/New.swift', '#if ULTRACAM_TEST_SUPPORT || DEBUG\nlet fake = FakeCapturePlugin()\n#endif\n')
        self.assertIn('test-guard', self.audit())

    def test_extension_membership_isolated_and_fake_excluded_from_shipping(self):
        vendor = self.write('Vendors/Acme/Sources/Plugin.swift', 'struct FreshDevice {}\n')
        fake = self.write('Sources/DeviceAPI/FakeCapturePlugin.swift', '#if ULTRACAM_TEST_SUPPORT\nstruct FakeCapturePlugin {}\n#endif\n')
        result = self.audit(targets={'camera': [vendor, 'Sources/App/Controller.swift'], 'app': [fake]})
        self.assertIn('extension-isolation', result)
        self.assertIn('shipping-fake', result)

    def test_unbranded_native_header_function_and_import_are_discovered(self):
        header = self.write('Vendors/Acme/Sources/Transport.h', 'void freshTransportStart(void);\n')
        self.write('Sources/App/New.mm', '#import "Transport.h"\nvoid use() { freshTransportStart(); }\n')
        manifest = {'id': 'acme', 'sources': [{'path': header, 'membership': ['app']}], 'publicHeaders': [header]}
        result = self.audit([manifest])
        self.assertIn('vendor-import', result)
        self.assertIn('plugin-symbol: freshTransportStart', result)

    def test_nested_common_names_are_not_global_plugin_symbols(self):
        source = self.write('Vendors/Acme/Sources/Plugin.swift', 'struct AcmePlugin {\n  struct State {}\n}\n')
        self.write('Sources/App/New.swift', 'struct State {}\nlet state = State()\n')
        manifest = {'id': 'acme', 'sources': [{'path': source, 'membership': ['app']}], 'publicHeaders': []}
        self.assertEqual(self.audit([manifest]), '')

    def test_actual_pbx_sources_framework_and_copy_phases_are_inspected(self):
        project = {'objects': {
            'camera': {'isa': 'PBXNativeTarget', 'name': 'UltracamCamera', 'buildPhases': ['sources', 'frameworks', 'copy']},
            'app': {'isa': 'PBXNativeTarget', 'name': 'Ultracam', 'buildPhases': []},
            'sources': {'isa': 'PBXSourcesBuildPhase', 'files': ['source-build']},
            'frameworks': {'isa': 'PBXFrameworksBuildPhase', 'files': ['package-build']},
            'copy': {'isa': 'PBXCopyFilesBuildPhase', 'files': ['copy-build']},
            'source-build': {'fileRef': 'source'}, 'source': {'path': 'Sources/App/New.swift'},
            'package-build': {'productRef': 'package'}, 'package': {'productName': 'MonitorKit'},
            'copy-build': {'fileRef': 'library'}, 'library': {'path': 'Vendors/Acme/SDK/libCamera.dylib'},
        }}
        targets = self.checker.project_targets(project)
        result = self.audit(targets=targets)
        self.assertIn('Sources/App/New.swift', result)
        self.assertIn('MonitorKit', result)
        self.assertIn('libCamera.dylib', result)

    def test_blackmagic_color_profile_tokens_do_not_exempt_plugin_code(self):
        self.write('Sources/Shared/SourceFormat.swift', 'case blackmagicWideGamutGen5, blackmagicFilmGen5')
        self.write('Sources/Shared/FormatDisplayIdentity.swift', 'case .blackmagicFilmGen5: "Blackmagic Film Gen 5"')
        self.write('Sources/App/SourceColorSpaceCatalog.swift', 'entry("blackmagic-film-gen5-widegamut", "Blackmagic Wide Gamut / Film Gen 5", .blackmagicWideGamutGen5, .blackmagicFilmGen5)')
        self.assertEqual(self.audit(), '')
        self.write('Sources/Shared/SourceFormat.swift', 'case blackmagicFilmGen5; BlackmagicSDK.start()')
        self.assertIn('vendor-name', self.audit())

    def test_localized_vendor_variant_group_resolves_children_and_rejects_extension(self):
        project = {'objects': {
            'app': {'isa': 'PBXNativeTarget', 'name': 'Ultracam', 'buildPhases': []},
            'camera': {'isa': 'PBXNativeTarget', 'name': 'UltracamCamera', 'buildPhases': ['resources']},
            'resources': {'isa': 'PBXResourcesBuildPhase', 'files': ['build']},
            'build': {'fileRef': 'variant'},
            'variant': {'isa': 'PBXVariantGroup', 'name': 'SonyControl.strings', 'children': ['english']},
            'english': {'isa': 'PBXFileReference', 'path': 'Vendors/Sony/Resources/en.lproj/SonyControl.strings'},
        }}
        targets = self.checker.project_targets(project)
        self.assertEqual(targets['camera'], ['Vendors/Sony/Resources/en.lproj/SonyControl.strings'])
        self.assertIn('extension-isolation', self.audit(targets=targets))
        project['objects']['variant']['children'] = ['variant']
        with self.assertRaises(ValueError):
            self.checker.project_targets(project)

if __name__ == '__main__':
    unittest.main()
