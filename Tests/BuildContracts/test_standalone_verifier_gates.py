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
        self.root = Path(self.temp.name) / "ultracam"
        for folder in ('scripts', 'Sources/App', 'Tools/UIVerify', 'Apps/AutoSwitcher/src', 'Apps/AutoSwitcher/include',
                       '../MonitorKit/Sources', 'Vendors', 'Config/Assets.xcassets', 'bin'):
            (self.root / folder).mkdir(parents=True)
        for name in ('ui-verify.sh', 'monitor-app-integration.sh', 'monitor-feed-host-checks.sh',
                     'program-stream-app-smoke.sh', 'program-stream-link.sh',
                     'check-gpu-proof-skips.py', 'auto_switcher_source.py'):
            shutil.copyfile(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        self.write('scripts/work_paths.py', 'print(' + repr(str(self.root / 'work')) + ')')
        self.write('scripts/vendors.py', 'print("fixture")')
        self.write('scripts/monitor-kit-package.sh', 'monitor_kit_link_args=(-I /fake); monitor_kit_package_build() { :; }')
        self.write('scripts/vendor-build.sh', 'vendor_configure() { :; }; vendor_compile_native() { :; }; vendor_bridge=/dev/null')
        self.write('Sources/App/Fixture.swift', '// fixture')
        self.write('../MonitorKit/Package.swift', '// fixture')
        self.write('Apps/AutoSwitcher/src/lib.rs', '// fixture')
        self.write('Apps/AutoSwitcher/Cargo.toml', '# fixture')
        self.write('Apps/AutoSwitcher/Cargo.lock', '# fixture')
        self.write('Apps/AutoSwitcher/include/auto_switcher.h', '// fixture')
        self.write('bin/rustup', '#!/bin/bash\nexit 0\n', True)
        self.write('bin/xcode-select', '#!/bin/bash\necho /fake\n', True)
        executable = """#!/bin/bash\necho executed >> "$RUN_RECEIPT"\nprintf '%s\\n' "$FAKE_TEST_OUTPUT"\n"""
        self.write('bin/xcrun', '#!/usr/bin/env python3\nimport pathlib, sys\nout = pathlib.Path(sys.argv[sys.argv.index("-o") + 1])\nout.write_text(' + repr(executable) + ')\nout.chmod(0o755)\n', True)
        self.env = dict(os.environ, PATH=str(self.root / 'bin') + ':' + os.environ['PATH'],
                        RUN_RECEIPT=str(self.root / 'receipt'), FAKE_TEST_OUTPUT='PASS', FORCE='0',
                        UI_MAC_CAMERA_ONLY='0', UI_PERF_ONLY='0', UI_PERF_CAMERAS='2,4', UI_PERF_METERS='live,fixed',
                        UI_PERF_IDLE='4', UI_PERF_PROFILE_INSPECTOR='0', RENDER_INSPECTOR='0',
                        ULTRACAM_REQUIRE_GPU_PROOFS='0')
        self.env.pop('UI_VERIFY_TIMING', None)

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

    def test_reduced_performance_selections_do_not_share_full_cache(self):
        for override in ({'UI_PERF_CAMERAS': '2'}, {'UI_PERF_METERS': 'fixed'}):
            with self.subTest(override=override):
                self.passes(**override)
                before = self.count()
                self.passes()
                self.assertEqual(self.count(), before + 1)
                self.passes(**override)
                self.assertEqual(self.count(), before + 2)
                (self.root / 'work/agent-work/build/ultracam/ui-verify/last-pass').unlink()

    def test_rust_production_inputs_invalidate_full_cache(self):
        self.passes()
        self.passes()
        self.assertEqual(self.count(), 1)
        for name in ('src/lib.rs', 'Cargo.toml', 'Cargo.lock', 'build.rs', '.cargo/config.toml'):
            with self.subTest(name=name):
                path = self.root / 'Apps/AutoSwitcher' / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('changed')
                before = self.count()
                self.passes()
                self.assertEqual(self.count(), before + 1)

    def test_failed_input_hash_does_not_run_or_replace_full_proof(self):
        self.passes()
        proof = self.root / 'work/agent-work/build/ultracam/ui-verify/last-pass'
        original_proof = proof.read_text()
        (self.root / 'Tools/UIVerify').rmdir()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Tools/UIVerify', result.stderr)
        self.assertEqual(self.count(), 1)
        self.assertEqual(proof.read_text(), original_proof)

    def test_rust_build_failure_reports_diagnostic_and_status(self):
        self.write('bin/rustup', '#!/bin/bash\nif [[ "$1" == run ]]; then echo "Rust build failed" >&2; exit 7; fi\n', True)
        result = self.run_script(UI_PERF_ONLY='1')
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertIn('Rust build failed', result.stderr)
        self.assertFalse((self.root / 'receipt').exists())

    def test_diagnostic_requests_do_not_reuse_or_replace_default_result(self):
        self.passes()
        proof = self.root / 'work/agent-work/build/ultracam/ui-verify/last-pass'
        original_proof = proof.read_text()
        self.passes(RENDER_INSPECTOR='1')
        self.passes(UI_VERIFY_TIMING='')
        self.passes(UI_MAC_CAMERA_ONLY='1')
        self.passes()
        self.assertEqual(self.count(), 4)
        self.assertEqual(proof.read_text(), original_proof)

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

    def test_monitor_runners_reject_partial_source_listing(self):
        self.write('bin/rg', '#!/bin/bash\nprintf "%s\\n" "$2/Fixture.swift"\nexit 7\n', True)
        for script in ('monitor-app-integration.sh', 'monitor-feed-host-checks.sh'):
            with self.subTest(script=script):
                result = self.run_script(script)
                self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
                self.assertFalse((self.root / 'receipt').exists())

    def test_stream_app_smoke_rejects_invalid_duration_before_build(self):
        for duration in ('bad', '17', '24.5'):
            with self.subTest(duration=duration):
                result = subprocess.run(['bash', str(self.root / 'scripts/program-stream-app-smoke.sh'),
                                         'missing-products', duration], env=self.env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('at least 18 seconds', result.stderr)

    def test_program_stream_link_uses_products_relative_to_the_caller(self):
        build = self.root / 'App Build'
        products = build / 'Products/Release'
        products.mkdir(parents=True)
        for product in ('Logboard.o', 'HaishinKit.o', 'RTMPHaishinKit.o', 'ProgramAV1.o', 'CProgramAV1.o', 'libaom.a'):
            (products / product).touch()
        module_map = build / 'Intermediates.noindex/GeneratedModuleMaps/CProgramAV1.modulemap'
        module_map.parent.mkdir(parents=True)
        module_map.touch()
        alternate = self.root / 'Other Build'
        (alternate / 'Products/Release').mkdir(parents=True)
        result = subprocess.run(['bash', '-euc', 'source "$1"\nprogram_stream_link_args Products/Release\n'
                                 'printf "%s\\n" "${stream_link_args[@]}"', 'program-stream-link',
                                 str(self.root / 'scripts/program-stream-link.sh')], cwd=build,
                                env=dict(self.env, CDPATH=str(alternate)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines()[:2], ['-I', str(products.resolve())])

if __name__ == '__main__':
    unittest.main()
