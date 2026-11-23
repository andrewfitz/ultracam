import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CompleteGateTests(unittest.TestCase):
    def test_rust_behavior_tests_are_in_non_compile_gate(self):
        script = (ROOT / 'scripts/test.sh').read_text()
        self.assertIn('cargo test', script)
        self.assertIn('--release --locked', script)

    def fixture(self, *, register_vendor=True, skipped=False, required=False,
                missing_source=False, duplicate_registration=False, extension=False,
                runtime_count=1, failed=False, extra_source='', extra_registration=''):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'Tests').mkdir()
            (root / 'Tests/MonitorKitHost').mkdir()
            (root / 'Tests/MonitorKitHost/MonitorFeedHostChecks.swift').write_text('')
            shutil.copy(ROOT / 'scripts/check-test-coverage.py', root / 'scripts')
            vendor = root / 'VendorChecks.swift'
            vendor.write_text('' if missing_source else 'class VendorChecks: XCTestCase {\n func testProof() {}\n}\n')
            (root / 'Tests/Comments.swift').write_text(extra_source)
            if extension:
                (root / 'Tests/ExtensionChecks.swift').write_text(
                    'extension VendorChecks {\n func testExtension() {}\n}\n'
                    'extension VendorChecks {\n func testAnotherExtension() {}\n}\n')
            (root / 'scripts/vendors.py').write_text('print(' + repr(str(vendor)) + ')')
            (root / 'Tests/main.swift').write_text(
                ('suite.addTest(XCTestSuite(forTestCaseClass: VendorChecks.self))' *
                 (2 if duplicate_registration else 1) if register_vendor else '') + '\n' + extra_registration)
            log = root / 'runtime.log'
            log.write_text(("Test Case '-[main.VendorChecks testProof]' skipped (0.0 seconds).\n"
                            if skipped else '') +
                           f"Test Suite 'VendorChecks' {'failed' if failed else 'passed'}\n Executed {runtime_count} tests\n")
            env = dict(os.environ, ULTRACAM_REQUIRE_GPU_PROOFS='1' if required else '0')
            return subprocess.run([sys.executable, str(root / 'scripts/check-test-coverage.py'),
                                   str(log), '--root', str(root)],
                                  env=env, text=True, capture_output=True)

    def test_vendor_suite_requires_registration(self):
        result = self.fixture(register_vendor=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('unregistered', result.stderr)

    def test_registered_vendor_suite_passes(self):
        result = self.fixture()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('VendorChecks=1', result.stdout)

    def test_registered_suite_requires_compiled_source(self):
        result = self.fixture(missing_source=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing from compiled sources', result.stderr)

    def test_duplicate_registration_is_rejected(self):
        result = self.fixture(duplicate_registration=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Duplicate XCTest suite registration', result.stderr)

    def test_commented_examples_do_not_declare_or_register_suites(self):
        result = self.fixture(extra_source='// class ExampleChecks: XCTestCase {}',
                              extra_registration='// XCTestSuite(forTestCaseClass: VendorChecks.self)')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_extensions_are_included_in_runtime_count(self):
        result = self.fixture(extension=True, runtime_count=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('VendorChecks=3', result.stdout)
        self.assertNotEqual(self.fixture(extension=True).returncode, 0)

    def test_partial_runtime_suite_is_rejected(self):
        self.assertNotEqual(self.fixture(runtime_count=0).returncode, 0)

    def test_failed_runtime_suite_is_rejected(self):
        self.assertNotEqual(self.fixture(failed=True).returncode, 0)

    def test_skipped_proof_is_qualified_and_required_lane_refuses(self):
        result = self.fixture(skipped=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('VendorChecks testProof', result.stdout)
        self.assertIn('coverage is incomplete', result.stdout)
        self.assertNotEqual(self.fixture(skipped=True, required=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
