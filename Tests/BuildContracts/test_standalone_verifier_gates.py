"""Exercise shell runners with fake compilers; never execute UI or GPU code."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class StandaloneVerifierGates(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for folder in ('scripts', 'Sources/App', 'Tools/UIVerify', 'Tools/auto-switcher/src',
                       'Packages/MonitorKit/Sources', 'Vendors', 'Config/Assets.xcassets', 'bin'):
            (self.root / folder).mkdir(parents=True)
        for name in ('ui-verify.sh', 'monitor-app-integration.sh', 'monitor-feed-host-checks.sh', 'check-gpu-proof-skips.py'):
            shutil.copyfile(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        self.write('scripts/work_paths.py', 'print(' + repr(str(self.root / 'work')) + ')')
        self.write('scripts/vendors.py', 'print("fixture")')
        self.write('scripts/monitor-kit-package.sh', 'monitor_kit_link_args=(-I /fake); monitor_kit_package_build() { :; }')
        self.write('scripts/vendor-build.sh', 'vendor_configure() { :; }; vendor_compile_native() { :; }; vendor_bridge=/dev/null')
        self.write('Sources/App/Fixture.swift', '// fixture')
        self.write('Packages/MonitorKit/Package.swift', '// fixture')
        self.write('Tools/auto-switcher/src/lib.rs', '// fixture')
        self.write('Tools/auto-switcher/Cargo.toml', '# fixture')
        self.write('Tools/auto-switcher/Cargo.lock', '# fixture')
        self.write('bin/rustup', '#!/bin/bash\nexit 0\n', True)
        self.write('bin/xcode-select', '#!/bin/bash\necho /fake\n', True)
        executable = """#!/bin/bash\necho executed >> "$RUN_RECEIPT"\nprintf '%s\\n' "$FAKE_TEST_OUTPUT"\n"""
        self.write('bin/xcrun', '#!/usr/bin/env python3\nimport pathlib, sys\nout = pathlib.Path(sys.argv[sys.argv.index("-o") + 1])\nout.write_text(' + repr(executable) + ')\nout.chmod(0o755)\n', True)
        self.env = dict(os.environ, PATH=str(self.root / 'bin') + ':' + os.environ['PATH'],
                        RUN_RECEIPT=str(self.root / 'receipt'), FAKE_TEST_OUTPUT='PASS', FORCE='0',
                        UI_PERF_ONLY='0', ULTRACAM_REQUIRE_GPU_PROOFS='0')

    def write(self, name, text, executable=False):
        path = self.root / name
        path.write_text(text)
        if executable:
            path.chmod(0o755)

    def run_script(self, name='ui-verify.sh', **env):
        return subprocess.run(['bash', str(self.root / 'scripts' / name)],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def passes(self, **env):
        result = self.run_script(**env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def count(self):
        return len((self.root / 'receipt').read_text().splitlines())

    def test_performance_and_full_requests_do_not_share_cache(self):
        self.passes(UI_PERF_ONLY='1')
        self.passes()
        self.assertEqual(self.count(), 2)
        self.passes(UI_PERF_ONLY='1')
        self.assertEqual(self.count(), 3)

    def test_rust_production_inputs_invalidate_full_cache(self):
        self.passes()
        self.passes()
        self.assertEqual(self.count(), 1)
        for name in ('src/lib.rs', 'Cargo.toml', 'Cargo.lock', 'build.rs', '.cargo/config.toml'):
            with self.subTest(name=name):
                path = self.root / 'Tools/auto-switcher' / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('changed')
                before = self.count()
                self.passes()
                self.assertEqual(self.count(), before + 1)

    def test_standalone_skip_policy(self):
        for script in ('monitor-app-integration.sh', 'monitor-feed-host-checks.sh'):
            for identity in ('MonitorAppIntegrationChecks testEveryCameraRestoredBeforeAutomaticStartDrawsItsLUT', 'UnknownChecks testNewProof'):
                with self.subTest(script=script, identity=identity):
                    output = "Test Case '-[" + identity + "]' skipped (0.001 seconds)."
                    ordinary = self.run_script(script, FAKE_TEST_OUTPUT=output)
                    self.assertEqual(ordinary.returncode, 0, ordinary.stdout + ordinary.stderr)
                    self.assertIn('incomplete', ordinary.stdout)
                    strict = self.run_script(script, FAKE_TEST_OUTPUT=output, ULTRACAM_REQUIRE_GPU_PROOFS='1')
                    self.assertNotEqual(strict.returncode, 0, strict.stdout + strict.stderr)

if __name__ == '__main__':
    unittest.main()
