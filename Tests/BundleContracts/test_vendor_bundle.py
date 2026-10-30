"""Vendor layout checks use realistic tool output; they never sign SDK binaries."""
import json
import shutil
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import validate_bundle as validator

class VendorBundleTests(unittest.TestCase):
    def test_rpath_first_existing_external_match_is_rejected(self):
        self.meta[self.host]['rpaths'] = [str(self.root / 'SDK'), '@executable_path/../Frameworks']
        with self.assertRaisesRegex(ValueError, 'dependency'):
            self.validate()
        (self.root / 'SDK/libCore.dylib').unlink()
        self.validate()
        self.binary(self.root / 'SDK/libCore.dylib', install='@rpath/libCore.dylib')
        self.meta[self.host]['rpaths'].reverse()
        self.validate()

    def test_rpath_external_match_precedes_shared_cache_match(self):
        external = self.binary(self.root / 'SDK/libSystem.B.dylib')
        self.meta[self.core]['dependencies'] = ['@rpath/libSystem.B.dylib']
        self.meta[self.core]['rpaths'] = [str(external.parent), '/usr/lib']
        with patch.object(validator, 'system_library_available',
                          side_effect=lambda p: str(p) == '/usr/lib/libSystem.B.dylib'):
            with self.assertRaisesRegex(ValueError, 'dependency'):
                self.validate()
            external.unlink()
            self.validate()
            self.binary(external)
            self.meta[self.core]['rpaths'].reverse()
            self.validate()

    def test_existing_unvalidated_candidate_blocks_later_bundled_code(self):
        folder = self.app / 'Contents/Frameworks/Invalid'
        folder.mkdir()
        (folder / 'libCore.dylib').write_text('not a Mach-O')
        self.meta[self.host]['rpaths'].insert(0, str(folder))
        with self.assertRaisesRegex(ValueError, 'Unvalidated dependency'):
            self.validate()

    def test_rpath_explicit_external_driver_policy_and_extension_boundary(self):
        folder = self.root / 'Driver'
        self.binary(folder / 'libDriver.dylib')
        self.manifests[0]['sdk']['externalDrivers'] = [str(folder)]
        self.meta[self.core]['dependencies'] = ['@rpath/libDriver.dylib']
        self.meta[self.core]['rpaths'] = [str(folder)]
        self.validate()
        self.meta[self.ext]['dependencies'] = ['@rpath/libDriver.dylib']
        self.meta[self.ext]['rpaths'] = [str(folder)]
        with self.assertRaisesRegex(ValueError, 'dependency'):
            self.validate()

    def test_system_rpath_does_not_prove_missing_library_exists(self):
        self.meta[self.core]['dependencies'] = ['@rpath/libDefinitelyMissingAudit.dylib']
        self.meta[self.core]['rpaths'] = ['/usr/lib']
        with self.assertRaisesRegex(ValueError, 'dependency'):
            self.validate()

    def test_real_shared_cache_system_rpath_is_supported(self):
        self.meta[self.core]['dependencies'] = ['@rpath/libSystem.B.dylib']
        self.meta[self.core]['rpaths'] = ['/usr/lib']
        self.validate()

    def test_top_level_signed_extension_requires_extracted_entitlements(self):
        host_entitlements = {'com.apple.security.files.user-selected.read-write': True,
                             'com.apple.security.cs.disable-library-validation': True,
                             'com.apple.security.app-sandbox': True,
                             'com.apple.developer.system-extension.install': True,
                             'com.apple.security.application-groups': ['group.org.ultracam.shared']}
        camera_entitlements = {'com.apple.security.app-sandbox': True, 'com.apple.security.application-groups': ['group.org.ultracam.shared']}
        for bundle, name, identifier, kind in [(self.app, 'Ultracam', 'org.ultracam.app', 'APPL'),
                (self.extension, 'Camera', 'org.ultracam.app.camera', 'SYSX')]:
            self.plist(bundle / 'Contents/Info.plist', dict(CFBundleExecutable=name,
                CFBundleIdentifier=identifier, CFBundlePackageType=kind,
                NSSystemExtensionUsageDescription='Camera',
                CMIOExtension={'CMIOExtensionMachServiceName': 'group.org.ultracam.shared.camera'}))
        self.plist(self.root / 'Config/Camera.entitlements', camera_entitlements)
        for name, shaders in [('MonitorKit_MonitorKit.bundle', ['MKLUT.msl', 'MKDecode.msl', 'MKMonitor.msl']),
                             ('MonitorKit_MonitorKitScopes.bundle', ['MKScopes.msl'])]:
            for shader in shaders:
                path = self.app / 'Contents/Resources' / name / 'Shaders' / shader
                path.parent.mkdir(parents=True, exist_ok=True); path.write_text('// fixture')
        for extraction_status in (0, 1):
            def extraction(args, **kwargs):
                if Path(args[-1]) == self.app:
                    return SimpleNamespace(returncode=0, stdout=plistlib.dumps(host_entitlements))
                return SimpleNamespace(returncode=extraction_status, stdout=b'')
            with self.subTest(status=extraction_status), patch.object(validator.subprocess, 'run', side_effect=extraction), \
                    patch.object(validator, 'validate_symbols'), patch.object(validator, 'validate_vendors'):
                with self.assertRaisesRegex(ValueError, 'entitlements'):
                    validator.validate(self.app, root=self.root, signed=True)
                validator.validate(self.app, root=self.root, signed=False)

    def test_top_level_core_capabilities_match_runtime(self):
        # Reuse the complete top-level fixture and exercise actual signed blobs.
        self.test_top_level_signed_extension_requires_extracted_entitlements()
        host = {'com.apple.security.files.user-selected.read-write': True,
                'com.apple.security.cs.disable-library-validation': True,
                'com.apple.security.app-sandbox': True,
                'com.apple.developer.system-extension.install': True,
                'com.apple.security.application-groups': ['group.org.ultracam.shared']}
        camera = {'com.apple.security.app-sandbox': True,
                  'com.apple.security.application-groups': ['group.org.ultracam.shared']}
        def extraction(args, **kwargs):
            return SimpleNamespace(returncode=0, stdout=plistlib.dumps(host if Path(args[-1]) == self.app else camera))
        with patch.object(validator.subprocess, 'run', side_effect=extraction), \
                patch.object(validator, 'validate_symbols'), patch.object(validator, 'validate_vendors'):
            validator.validate(self.app, root=self.root, signed=True)
            for values, key, replacement in [(host, 'com.apple.security.application-groups', []),
                    (host, 'com.apple.security.application-groups', ['group.other']),
                    (host, 'com.apple.developer.system-extension.install', False),
                    (host, 'com.apple.security.app-sandbox', False),
                    (camera, 'com.apple.security.app-sandbox', False),
                    (camera, 'com.apple.security.application-groups', ['group.other'])]:
                original = values[key]; values[key] = replacement
                with self.subTest(key=key, replacement=replacement), self.assertRaises(ValueError):
                    validator.validate(self.app, root=self.root, signed=True)
                values[key] = original
            for bundle in (self.app, self.extension):
                info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
                info['UltracamLocalDevelopmentBuild'] = True
                if bundle == self.extension:
                    info['CMIOExtension']['CMIOExtensionMachServiceName'] = 'group.org.ultracam.local.camera'
                self.plist(bundle / 'Contents/Info.plist', info)
            host['com.apple.security.application-groups'] = ['group.org.ultracam.local']
            camera['com.apple.security.application-groups'] = ['group.org.ultracam.local']
            validator.validate(self.app, root=self.root, signed=True)

    def test_universal_run_paths_are_slice_specific(self):
        for meta in self.meta.values():
            meta['architectures'] = ['arm64', 'x86_64']
        self.meta[self.host]['rpathsByArchitecture'] = {
            'arm64': [], 'x86_64': ['@executable_path/../Frameworks']}
        with self.assertRaisesRegex(ValueError, 'dependency'):
            self.validate()
        self.meta[self.host]['rpathsByArchitecture']['arm64'] = ['@executable_path/../Frameworks']
        self.validate()

    def test_universal_inherited_run_paths_are_slice_specific(self):
        for meta in self.meta.values():
            meta['architectures'] = ['arm64', 'x86_64']
        helper = self.binary(self.app / 'Contents/Frameworks/Helpers/libHelper.dylib', install='@rpath/libHelper.dylib')
        self.meta[helper]['architectures'] = ['arm64', 'x86_64']
        self.meta[self.core]['dependencies'] = ['@rpath/libHelper.dylib']
        self.meta[self.host]['rpathsByArchitecture'] = {
            'arm64': ['@executable_path/../Frameworks'],
            'x86_64': ['@executable_path/../Frameworks', '@executable_path/../Frameworks/Helpers']}
        with self.assertRaisesRegex(ValueError, 'dependency'):
            self.validate()
        self.meta[self.host]['rpathsByArchitecture']['arm64'].append('@executable_path/../Frameworks/Helpers')
        self.validate()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Ultracam.app'
        self.extension = self.app / 'Contents/Library/SystemExtensions/org.ultracam.app.camera.systemextension'
        self.meta = {}
        self.host = self.binary(self.app / 'Contents/MacOS/Ultracam')
        self.ext = self.binary(self.extension / 'Contents/MacOS/Camera')
        for bundle, name in [(self.app, 'Ultracam'), (self.extension, 'Camera')]:
            self.plist(bundle / 'Contents/Info.plist', {'CFBundleExecutable': name, 'NSLocalNetworkUsageDescription': 'Discover cameras'})
        self.entitlements = {'com.apple.security.network.client': True}
        self.plist(self.root / 'Config/App.entitlements', self.entitlements)
        self.manifests = [{'id': 'sony', 'capabilities': {'entitlements': ['com.apple.security.network.client'], 'infoPlist': ['NSLocalNetworkUsageDescription']},
            'embedLibraries': [], 'sdk': {'version': '2.2', 'enabledBuild': {'embedLibraries': [
                {'path': 'SDK/libCore.dylib', 'subfolder': ''}, {'path': 'SDK/Adapter/libRuntime.dylib', 'subfolder': 'Adapter'}]}}}]
        self.inventory = {'sony': {'available': True}}
        for relative in ['SDK/libCore.dylib', 'SDK/Adapter/libRuntime.dylib']:
            self.binary(self.root / relative, install='@rpath/' + Path(relative).name)
        self.core = self.binary(self.app / 'Contents/Frameworks/libCore.dylib', install='@rpath/libCore.dylib')
        self.runtime = self.binary(self.app / 'Contents/Frameworks/Adapter/libRuntime.dylib', install='@rpath/libRuntime.dylib')
        self.meta[self.host]['dependencies'] = ['@rpath/libCore.dylib']
        self.meta[self.host]['rpaths'] = ['@executable_path/../Frameworks']
        self.meta[self.runtime]['dependencies'] = ['@loader_path/../libCore.dylib', '/usr/lib/libSystem.B.dylib']

    def plist(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def binary(self, path, install=None):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'\xcf\xfa\xed\xfe' + b'\0' * 28)
        self.meta[path] = {'architectures': ['arm64'], 'install': install, 'dependencies': [], 'rpaths': [], 'signed': True}
        return path

    def runner(self, args, **kwargs):
        path = Path(args[-1]); meta = next((value for key, value in self.meta.items() if key.resolve() == path.resolve()), {})
        out = ''; rc = 0
        if args[0].endswith('lipo'):
            out = ' '.join(meta.get('architectures', []))
        elif args[0].endswith('otool'):
            if '-D' in args: out = str(path) + ':\n' + (meta.get('install') or '') + '\n'
            elif '-L' in args:
                arch = args[args.index('-arch') + 1] if '-arch' in args else None
                deps = ([meta['install']] if meta.get('install') else []) + meta.get('dependenciesByArchitecture', {}).get(arch, meta.get('dependencies', []))
                out = str(path) + ':\n' + ''.join('\t' + dep + ' (compatibility version 1.0.0, current version 1.0.0)\n' for dep in deps)
            elif '-l' in args:
                out = ''.join('Load command 1\n          cmd LC_RPATH\n      cmdsize 48\n         path ' + p + ' (offset 12)\n' for p in meta.get('rpathsByArchitecture', {}).get(args[args.index('-arch') + 1] if '-arch' in args else None, meta.get('rpaths', [])))
        elif args[0].endswith('codesign'):
            if '--entitlements' in args: out = plistlib.dumps(self.entitlements).decode()
            elif not meta.get('signed', True): rc = 1
        return SimpleNamespace(returncode=rc, stdout=out, stderr='fixture tool failure' if rc else '')

    def validate(self, **options):
        return validator.validate_vendors(self.app, root=self.root, manifests=self.manifests,
            inventory=self.inventory, runner=self.runner, **options)

    def test_unsigned_still_checks_runtime_adapters_and_dependencies(self):
        self.validate()
        self.meta[self.runtime]['dependencies'].append('@loader_path/missing.dylib')
        with self.assertRaisesRegex(ValueError, 'dependency'): self.validate()

    def test_enabled_embed_presence_architecture_and_install_name(self):
        self.runtime.unlink()
        with self.assertRaisesRegex(ValueError, 'Missing'): self.validate()
        self.binary(self.runtime, install='@rpath/libRuntime.dylib')
        self.meta[self.runtime]['architectures'] = ['x86_64']
        with self.assertRaisesRegex(ValueError, 'architecture'): self.validate()
        self.meta[self.runtime]['architectures'] = ['arm64']
        self.meta[self.runtime]['install'] = '/developer/SDK/libRuntime.dylib'
        with self.assertRaisesRegex(ValueError, 'install name'): self.validate()

    def test_extension_rejects_vendor_runtime_even_unlinked(self):
        self.binary(self.extension / 'Contents/Frameworks/libRuntime.dylib', install='@rpath/libRuntime.dylib')
        with self.assertRaisesRegex(ValueError, 'extension'): self.validate()

    def test_capabilities_must_exist_in_built_plist_and_entitlements(self):
        self.plist(self.app / 'Contents/Info.plist', {'CFBundleExecutable': 'Ultracam'})
        with self.assertRaisesRegex(ValueError, 'NSLocalNetworkUsageDescription'): self.validate()
        self.plist(self.app / 'Contents/Info.plist', {'CFBundleExecutable': 'Ultracam', 'NSLocalNetworkUsageDescription': 'Cameras'})
        self.entitlements = {}
        self.plist(self.root / 'Config/App.entitlements', {})
        with self.assertRaisesRegex(ValueError, 'network.client'): self.validate()

    def test_signed_checks_nested_code_and_requires_actual_entitlements(self):
        self.meta[self.runtime]['signed'] = False
        with self.assertRaisesRegex(ValueError, 'signature'): self.validate(signed=True)
        self.validate(signed=False)

    def test_disabled_sdk_does_not_require_embeds_but_rejects_stale_vendor_code(self):
        self.inventory['sony']['available'] = False
        with self.assertRaisesRegex(ValueError, 'disabled'): self.validate()
        self.runtime.unlink(); self.core.unlink()
        self.meta[self.host]['dependencies'] = []
        self.validate()

    def test_non_system_absolute_dependency_requires_explicit_driver_declaration(self):
        self.meta[self.core]['dependencies'] = ['/Library/Frameworks/Driver.framework/Driver']
        with self.assertRaisesRegex(ValueError, 'dependency'): self.validate()
        self.manifests[0]['sdk']['externalDrivers'] = ['/Library/Frameworks/Driver.framework']
        self.validate()

    def test_official_release_requires_sony_signature_and_evidence(self):
        with self.assertRaisesRegex(ValueError, 'signed'): self.validate(official_release=True)
        with self.assertRaisesRegex(ValueError, 'evidence'): self.validate(signed=True, official_release=True)
        self.inventory['sony']['available'] = False
        with self.assertRaisesRegex(ValueError, 'Sony'): self.validate(signed=True, official_release=True)

    def test_rpath_must_resolve_inside_bundle_and_dependency_architecture_matches(self):
        self.meta[self.core]['dependencies'] = ['@rpath/libOutside.dylib']
        self.meta[self.core]['rpaths'] = [str(self.root)]
        self.binary(self.root / 'libOutside.dylib', install='@rpath/libOutside.dylib')
        with self.assertRaisesRegex(ValueError, 'dependency'): self.validate()

    def test_transitive_loader_rpath_is_inherited_by_child(self):
        helper = self.binary(self.app / 'Contents/Frameworks/Helpers/libHelper.dylib', install='@rpath/libHelper.dylib')
        leaf = self.binary(self.app / 'Contents/Frameworks/Helpers/libLeaf.dylib', install='@rpath/libLeaf.dylib')
        self.meta[self.core]['dependencies'] = ['@rpath/libHelper.dylib']
        self.meta[self.core]['rpaths'] = ['@loader_path/Helpers']
        self.meta[helper]['dependencies'] = ['@rpath/libLeaf.dylib']
        self.validate()
        leaf.unlink()
        with self.assertRaisesRegex(ValueError, 'dependency'): self.validate()

    def test_unneeded_architecture_dependencies_are_not_inspected(self):
        self.meta[self.runtime]['architectures'] = ['arm64', 'x86_64']
        self.meta[self.runtime]['dependenciesByArchitecture'] = {'arm64': [], 'x86_64': ['/developer/x86-only.dylib']}
        self.validate()
        self.meta[self.host]['architectures'] = ['arm64', 'x86_64']
        self.meta[self.ext]['architectures'] = ['arm64', 'x86_64']
        self.meta[self.core]['architectures'] = ['arm64', 'x86_64']
        with self.assertRaisesRegex(ValueError, 'dependency'): self.validate()

    def test_signed_entitlements_cannot_fall_back_to_template(self):
        base_runner = self.runner
        def missing_entitlements(args, **kwargs):
            if '--entitlements' in args: return SimpleNamespace(returncode=1, stdout='', stderr='unsigned')
            return base_runner(args, **kwargs)
        with self.assertRaisesRegex(ValueError, 'entitlements'):
            validator.validate_vendors(self.app, root=self.root, manifests=self.manifests, inventory=self.inventory,
                runner=missing_entitlements, signed=True)

    def test_system_framework_vendor_without_sdk_is_supported(self):
        self.manifests.append({'id': 'uvc', 'capabilities': {'entitlements': [], 'infoPlist': []}, 'embedLibraries': []})
        self.inventory['uvc'] = {'available': False}
        self.validate()

    def test_sdkless_vendor_capabilities_and_unconditional_embeds_are_checked(self):
        self.manifests.append({'id': 'uvc', 'capabilities': {'entitlements': ['fixture.camera-access'], 'infoPlist': []},
            'embedLibraries': [{'path': 'SDK/libSystemHelper.dylib', 'subfolder': ''}]})
        self.inventory['uvc'] = {'available': False}
        self.binary(self.root / 'SDK/libSystemHelper.dylib', install='@rpath/libSystemHelper.dylib')
        with self.assertRaisesRegex(ValueError, 'fixture.camera-access'): self.validate()
        self.entitlements['fixture.camera-access'] = True
        with self.assertRaisesRegex(ValueError, 'Missing'): self.validate()
        self.binary(self.app / 'Contents/Frameworks/libSystemHelper.dylib', install='@rpath/libSystemHelper.dylib')
        self.validate()

    def test_official_evidence_binds_sdk_inventory_notices_and_artifact(self):
        for name in ['LICENSE', 'NOTICE', 'THIRD_PARTY_LICENSES.md']:
            notice = self.app / 'Contents/Resources' / name
            notice.parent.mkdir(parents=True, exist_ok=True)
            notice.write_text('Fixture legal evidence only')
        evidence = {'schemaVersion': 1, 'vendorID': 'sony', 'sdkVersion': '2.2', 'reviewedBy': 'Fixture reviewer',
            'reviewedAt': '2026-10-27', 'termsReference': 'fixture-only:terms', 'redistributionClauses': 'Fixture-only clause',
            'archiveName': 'fixture.tar', 'archiveSHA256': 'a' * 64, 'provenance': 'fixture-only',
            'runtimeInventory': ['libCore.dylib', 'Adapter/libRuntime.dylib'],
            'packagedNotices': ['Contents/Resources/LICENSE'], 'artifactSHA256': validator.bundle_digest(self.app)}
        record = self.root / 'evidence.json'
        record.write_text(json.dumps(evidence))
        base_runner = self.runner
        def signed_runner(args, **kwargs):
            if '--display' in args:
                return SimpleNamespace(returncode=0, stdout='', stderr='Authority=Fixture identity\nTeamIdentifier=FIXTURE\n')
            return base_runner(args, **kwargs)
        validator.validate_vendors(self.app, root=self.root, manifests=self.manifests, inventory=self.inventory,
            runner=signed_runner, signed=True, official_release=True, release_evidence=record)
        self.core.write_bytes(self.core.read_bytes() + b'changed')
        with self.assertRaisesRegex(ValueError, 'artifact'):
            validator.validate_vendors(self.app, root=self.root, manifests=self.manifests, inventory=self.inventory,
                runner=signed_runner, signed=True, official_release=True, release_evidence=record)

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'requires Apple Mach-O tools')
    def test_real_macho_dependency_and_runtime_adapter_inspection(self):
        source = self.root / 'fixture.c'
        source.write_text('int fixture(void) { return 0; }')
        subprocess.run(['clang', '-dynamiclib', str(source), '-install_name', '@rpath/libCore.dylib', '-o', str(self.core)], check=True, capture_output=True)
        shutil.copy2(self.core, self.root / 'SDK/libCore.dylib')
        source.write_text('extern int fixture(void); int adapter(void) { return fixture(); }')
        subprocess.run(['clang', '-dynamiclib', str(source), '-L' + str(self.core.parent), '-lCore',
            '-Wl,-rpath,@loader_path/..', '-install_name', '@rpath/libRuntime.dylib', '-o', str(self.runtime)], check=True, capture_output=True)
        shutil.copy2(self.runtime, self.root / 'SDK/Adapter/libRuntime.dylib')
        source.write_text('extern int fixture(void); int main(void) { return fixture(); }')
        subprocess.run(['clang', str(source), '-L' + str(self.core.parent), '-lCore',
            '-Wl,-rpath,@executable_path/../Frameworks', '-o', str(self.host)], check=True, capture_output=True)
        source.write_text('int main(void) { return 0; }')
        subprocess.run(['clang', str(source), '-o', str(self.ext)], check=True, capture_output=True)
        validator.validate_vendors(self.app, root=self.root, manifests=self.manifests, inventory=self.inventory)
        self.core.unlink()
        with self.assertRaisesRegex(ValueError, 'Missing'):
            validator.validate_vendors(self.app, root=self.root, manifests=self.manifests, inventory=self.inventory)

    @unittest.skipUnless(sys.platform == 'darwin' and (ROOT / 'Vendors/Sony/SDK/lib/libCr_Core.dylib').is_file(), 'requires installed Sony SDK')
    def test_actual_sony_runtime_inventory_with_real_otool(self):
        import vendors
        manifests, inventory = vendors.read_inventory(ROOT, sdk_present='sony')
        settings = vendors.build_settings(manifests, inventory)
        shutil.rmtree(self.app / 'Contents/Frameworks')
        for item in settings['embedLibraries']:
            destination = self.app / 'Contents/Frameworks' / item['subfolder'] / Path(item['path']).name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / item['path'], destination)
        source = self.root / 'fixture.c'
        source.write_text('int main(void) { return 0; }')
        for executable in [self.host, self.ext]:
            subprocess.run(['clang', str(source), '-Wl,-rpath,@executable_path/../Frameworks', '-o', str(executable)], check=True, capture_output=True)
        validator.validate_vendors(self.app, root=ROOT, manifests=manifests, inventory=inventory)
        adapter = self.app / 'Contents/Frameworks/CrAdapter/libusb-1.0.0.dylib'
        adapter.unlink()
        with self.assertRaisesRegex(ValueError, 'Missing'):
            validator.validate_vendors(self.app, root=ROOT, manifests=manifests, inventory=inventory)

if __name__ == '__main__': unittest.main()
