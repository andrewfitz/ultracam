"""Generate against synthetic SDK files; no proprietary SDK or compiler needed."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GenerationModeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for directory in ('scripts', 'Config/Assets.xcassets', 'Packages/MonitorKit',
                          'Sources/App', 'Sources/Shared', 'Sources/Recording',
                          'Sources/DeviceAPI', 'Sources/CameraExtension'):
            (self.root / directory).mkdir(parents=True)
        for name in ('vendors.py', 'generate_project.py', 'work_paths.py'):
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        for name in ('App.entitlements', 'App-Info.plist'):
            shutil.copy2(ROOT / 'Config' / name, self.root / 'Config' / name)
        self.write('Packages/MonitorKit/Package.swift')
        self.write('Sources/App/App.swift')
        self.write('Sources/DeviceAPI/DeviceAPI.h')
        self.write('Sources/DeviceAPI/Neutral.swift')
        self.write('Sources/DeviceAPI/FakeFixture.swift')
        self.write('Sources/CameraExtension/Camera.swift')
        for name in ('VideoContract', 'VideoBufferLayout', 'SourceFormat', 'DerivedOutputAdmission', 'GPUStandbyProducer', 'GPUStandbyLifecycle',
                     'VirtualCameraRegistry', 'VirtualCameraRegistryTransport'):
            self.write('Sources/Shared/' + name + '.swift')
        for folder, identity, optional in (('Blackmagic', 'decklink', False), ('Sony', 'sony', True)):
            base = 'Vendors/' + folder + '/'
            for path in ('Sources/Plugin.swift', 'Sources/Native.mm', 'Sources/Public.h',
                         'SDK/include/SDK.h', 'SDK/lib/libCr_Core.dylib',
                         'Resources/Assets.xcassets/Contents.json'):
                self.write(base + path)
            manifest = dict(schemaVersion=1, id=identity, kinds=['control' if optional else 'capture'],
                sources=[dict(path='Sources/' + name, membership=['app', 'test'])
                         for name in ('Plugin.swift', 'Native.mm', 'Public.h')],
                publicHeaders=['Sources/Public.h'],
                resources=[dict(path='Resources/Assets.xcassets', membership=['app'])],
                sdk=dict(root='SDK', policy='local' if optional else 'vendored', optional=optional,
                    version='fixture', requiredFiles=['SDK/include/SDK.h', 'SDK/lib/libCr_Core.dylib'],
                    enabledBuild=dict(headerSearchPaths=['SDK/include'], librarySearchPaths=['SDK/lib'],
                        defines=['ULTRACAM_SONY_SDK=1'] if optional else [],
                        libraries=['Cr_Core'] if optional else [],
                        embedLibraries=[dict(path='SDK/lib/libCr_Core.dylib', subfolder='CrAdapter')] if optional else [])))
            self.write(base + 'vendor.json', json.dumps(manifest))
        self.environment = dict(os.environ)
        self.environment.pop('ULTRACAM_SDK_INVENTORY', None)
        self.environment.pop('ULTRACAM_SDK_CACHE', None)
        self.environment.pop('AUTO_SWITCHER_LIB_DIR', None)
        self.environment.pop('ULTRACAM_WORK_ROOT', None)

    def write(self, relative, text='// fixture\n'):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def run_generator(self, inventory=None):
        command = [sys.executable, str(self.root / 'scripts/generate_project.py')]
        if inventory is not None:
            self.write('inventory.json', json.dumps(inventory))
            command += ['--sdk-inventory', str(self.root / 'inventory.json')]
        subprocess.run(command, cwd=self.root, env=self.environment, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return (self.root / 'Ultracam.xcodeproj/project.pbxproj').read_text()

    def test_asset_catalogs_share_one_resources_phase(self):
        self.run_generator()
        objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-',
            str(self.root / 'Ultracam.xcodeproj/project.pbxproj')]))['objects']
        target = next(value for value in objects.values()
                      if value['isa'] == 'PBXNativeTarget' and value['name'] == 'Ultracam')
        phases = [objects[phase] for phase in target['buildPhases']
                  if objects[phase]['isa'] == 'PBXResourcesBuildPhase']
        self.assertEqual(len(phases), 1, 'Multiple resource phases duplicate asset compiler outputs')
        self.assertEqual(len(phases[0]['files']), 3)

    def test_objective_c_implementation_is_compiled_only_in_app(self):
        self.write('Vendors/Sony/Sources/Native.m')
        path = self.root / 'Vendors/Sony/vendor.json'
        manifest = json.loads(path.read_text())
        manifest['sources'].append(dict(path='Sources/Native.m', membership=['app', 'test']))
        path.write_text(json.dumps(manifest))
        self.run_generator()
        objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-',
            str(self.root / 'Ultracam.xcodeproj/project.pbxproj')]))['objects']
        identity, source = next((key, value) for key, value in objects.items()
                                if value.get('path') == 'Vendors/Sony/Sources/Native.m')
        self.assertEqual(source['lastKnownFileType'], 'sourcecode.c.objc')
        for target in objects.values():
            if target['isa'] != 'PBXNativeTarget': continue
            refs = [objects[build]['fileRef'] for phase in target['buildPhases']
                    if objects[phase]['isa'] == 'PBXSourcesBuildPhase' for build in objects[phase]['files']]
            self.assertEqual(refs.count(identity), 1 if target['name'] == 'Ultracam' else 0)

    def test_localized_vendor_strings_use_variant_group_and_keep_locale(self):
        self.write('Vendors/Sony/Resources/en.lproj/SonyControl.strings', '"key" = "Label";\n')
        path = self.root / 'Vendors/Sony/vendor.json'
        manifest = json.loads(path.read_text())
        manifest['resources'].append(dict(path='Resources/en.lproj/SonyControl.strings', membership=['app']))
        path.write_text(json.dumps(manifest))
        self.run_generator()
        objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-',
            str(self.root / 'Ultracam.xcodeproj/project.pbxproj')]))['objects']
        groups = [(key, value) for key, value in objects.items()
                  if value['isa'] == 'PBXVariantGroup' and value.get('name') == 'SonyControl.strings']
        self.assertEqual(len(groups), 1, 'Localized strings must not become a flat Swift/resource reference')
        identity, group = groups[0]
        child = objects[group['children'][0]]
        self.assertEqual(child['name'], 'en')
        self.assertEqual(child['path'], 'Vendors/Sony/Resources/en.lproj/SonyControl.strings')
        self.assertEqual(child['lastKnownFileType'], 'text.plist.strings')
        target = next(value for value in objects.values() if value['isa'] == 'PBXNativeTarget' and value['name'] == 'Ultracam')
        refs = [objects[build]['fileRef'] for phase in target['buildPhases']
                if objects[phase]['isa'] == 'PBXResourcesBuildPhase' for build in objects[phase]['files']]
        self.assertIn(identity, refs)
        self.assertNotIn(group['children'][0], refs)

    def test_optional_absence_is_canonical_even_if_files_exist_or_disappear(self):
        first = self.run_generator()
        self.assertFalse('ULTRACAM_SONY_SDK=1' in first)
        self.assertFalse('-lCr_Core' in first)
        (self.root / 'Vendors/Sony/SDK/include/SDK.h').unlink()
        (self.root / 'Vendors/Sony/SDK/lib/libCr_Core.dylib').unlink()
        self.assertEqual(first, self.run_generator())

    def test_present_sdk_embeds_only_in_app_and_never_compiles_fakes(self):
        project = self.run_generator({'sony': True})
        self.assertTrue('ULTRACAM_SONY_SDK=1' in project)
        self.assertTrue('-lCr_Core' in project)
        self.assertTrue('CrAdapter' in project)
        objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-',
            str(self.root / 'Ultracam.xcodeproj/project.pbxproj')]))['objects']
        for target in objects.values():
            if target['isa'] != 'PBXNativeTarget':
                continue
            paths = [objects[objects[build]['fileRef']]['path']
                     for phase in target['buildPhases'] if objects[phase]['isa'] == 'PBXSourcesBuildPhase'
                     for build in objects[phase]['files']]
            self.assertFalse(any('Fake' in path for path in paths))
            if target['name'] == 'UltracamCamera':
                self.assertIn('Sources/Shared/DerivedOutputAdmission.swift', paths)
                self.assertIn('Sources/Shared/GPUStandbyProducer.swift', paths)
                self.assertIn('Sources/Shared/GPUStandbyLifecycle.swift', paths)
                for configuration in objects[target['buildConfigurationList']]['buildConfigurations']:
                    self.assertIn('Metal', objects[configuration]['buildSettings']['OTHER_LDFLAGS'])
                self.assertFalse(any(path.startswith('Vendors/') for path in paths))
                self.assertFalse(any(objects[phase].get('dstSubfolderSpec') == 10 for phase in target['buildPhases']))

    def test_stale_manifest_fails_with_regeneration_instructions(self):
        project = self.run_generator()
        digest = re.search(r'--expected-digest ([0-9a-f]{64})', project).group(1)
        command = [sys.executable, str(self.root / 'scripts/vendors.py'), 'check-generated',
                   '--expected-digest', digest]
        subprocess.run(command, cwd=self.root, env=self.environment, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        path = self.root / 'Vendors/Sony/vendor.json'
        manifest = json.loads(path.read_text())
        manifest['sdk']['version'] = 'changed'
        path.write_text(json.dumps(manifest))
        result = subprocess.run(command, cwd=self.root, env=self.environment,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('generate_project.py', result.stderr)


if __name__ == '__main__':
    unittest.main()
