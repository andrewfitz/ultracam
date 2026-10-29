import importlib.util
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

    def fixture(self, *, register_vendor=True, skipped=False, required=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'Tests').mkdir()
            (root / 'Tests/MonitorKitHost').mkdir()
            (root / 'Tests/MonitorKitHost/MonitorFeedHostChecks.swift').write_text('')
            shutil.copy(ROOT / 'scripts/check-test-coverage.py', root / 'scripts')
            vendor = root / 'VendorChecks.swift'
            vendor.write_text('class VendorChecks: XCTestCase {\n func testProof() {}\n}\n')
            (root / 'scripts/vendors.py').write_text('print(' + repr(str(vendor)) + ')')
            (root / 'Tests/main.swift').write_text(
                'suite.addTest(XCTestSuite(forTestCaseClass: VendorChecks.self))'
                if register_vendor else '')
            log = root / 'runtime.log'
            log.write_text(("Test Case '-[main.VendorChecks testProof]' skipped (0.0 seconds).\n"
                            if skipped else '') +
                           "Test Suite 'VendorChecks' passed\n Executed 1 test\n")
            script = (ROOT / 'scripts/test.sh').read_text()
            body = script.split("<<'PY_COVERAGE'\n", 1)[1].split('\nPY_COVERAGE', 1)[0]
            env = dict(os.environ, ULTRACAM_REQUIRE_GPU_PROOFS='1' if required else '0')
            return subprocess.run([sys.executable, '-c', body, str(root), str(log)],
                                  env=env, text=True, capture_output=True)

    def test_vendor_suite_requires_registration(self):
        result = self.fixture(register_vendor=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('unregistered', result.stderr)

    def test_registered_vendor_suite_passes(self):
        result = self.fixture()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('VendorChecks=1', result.stdout)

    def test_skipped_proof_is_qualified_and_required_lane_refuses(self):
        result = self.fixture(skipped=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('VendorChecks testProof', result.stdout)
        self.assertIn('coverage is incomplete', result.stdout)
        self.assertNotEqual(self.fixture(skipped=True, required=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
