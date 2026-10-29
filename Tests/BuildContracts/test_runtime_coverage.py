"""A passing suite must actually execute every newly registered test method."""
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

class RuntimeCoverageTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('coverage_check', ROOT / 'scripts/check-test-coverage.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_counts_only_explicit_class_methods_and_ignores_literal_braces(self):
        source = '\n'.join([
            'final class FixtureChecks: XCTestCase {',
            '  func testAsync() async throws { let invalid = "{" }',
            '  func testSync() { /* } */ }', '}',
            'final class Helper { func testNotRegistered() {} }',
        ])
        self.assertEqual(self.module.class_test_methods(source, 'FixtureChecks'), ['testAsync', 'testSync'])

    def test_accepts_exact_runtime_counts(self):
        log = "Test Suite 'FixtureChecks' passed at today.\n\t Executed 3 tests, with 0 failures (0 unexpected) in 1 seconds\n"
        self.module.verify_coverage(log, {'FixtureChecks': 3})

    def test_rejects_missing_zero_or_partial_discovery(self):
        for log in ('', "Test Suite 'FixtureChecks' passed at today.\n Executed 0 tests, with 0 failures\n",
                    "Test Suite 'FixtureChecks' passed at today.\n Executed 2 tests, with 0 failures\n"):
            with self.subTest(log=log), self.assertRaises(ValueError):
                self.module.verify_coverage(log, {'FixtureChecks': 3})

if __name__ == '__main__':
    unittest.main()
