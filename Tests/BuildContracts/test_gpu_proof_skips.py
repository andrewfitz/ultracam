"""Required GPU lane skips are fail-closed; no GPU/process build involved."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]

class GPUProofSkipChecks(unittest.TestCase):
    def run_gate(self, identity, strict=True, package=False, extra_env=None):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / 'tests.log'
            log.write_text("Test Suite 'All tests' started.\n" + f"Test Case '-[{identity}]' skipped (0.001 seconds).\n" + "Test Suite 'All tests' passed.\nExecuted 1 test, with 1 test skipped and 0 failures in 0.001 seconds\n")
            return subprocess.run([sys.executable, str(ROOT / 'scripts/check-gpu-proof-skips.py'),
                                   '--package' if package else '--app', str(log)],
                                  env=dict(os.environ, ULTRACAM_REQUIRE_GPU_PROOFS='1' if strict else '0', **(extra_env or {})),
                                  capture_output=True, text=True)

    def test_required_app_and_package_skip_fail_strict_lane(self):
        self.assertEqual(self.run_gate('CPUMemoryGPUIngestChecks testGPUOwnership').returncode, 1)
        self.assertEqual(self.run_gate('MonitorKitTests.Metal4Tests testGPUOutput', package=True).returncode, 1)

    def test_ordinary_run_reports_incomplete_coverage_but_is_permissive(self):
        result = self.run_gate('CPUMemoryGPUIngestChecks testGPUOwnership', strict=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('incomplete', result.stdout)

    def test_named_opt_in_benchmark_skip_is_allowed(self):
        result = self.run_gate('MonitorKitCoreTests.Perf01GuideGridTests testWideGridMicrobenchmark', package=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('optional', result.stdout)
        self.assertEqual(self.run_gate('MonitorKitCoreTests.Perf01GuideGridTests testWideGridMicrobenchmark', package=True, extra_env={'MONITORKIT_PERF01_GRID_BENCH': '1'}).returncode, 1)
        self.assertNotEqual(self.run_gate('MonitorKitCoreTests.Perf01GuideGridTests testNewGPUProof', package=True).returncode, 0)

    def test_opt_in_windows_and_shader_validation_are_not_required_by_default(self):
        cases = {
            'MonitorKitUITests.DisplayLinkTests testDisplayLinkDrawsAndPresents': 'MONITORKITUI_WINDOW_TESTS',
            'MonitorKitUITests.DisplayLinkTests testHostDrivenLinkOnARenderThread': 'MONITORKITUI_WINDOW_TESTS',
            'MonitorKitUITests.MeterLayerTests testLayersLandWhereTheViewSays': 'MONITORKITUI_WINDOW_TESTS',
            'MonitorKitUITests.MeterLayerTests testALiveMeterTicksOnlyOnScreen': 'MONITORKITUI_WINDOW_TESTS',
            'MonitorKitTests.PipelineArchiveValidationTests testAValidatedSessionBuildsAndWritesNothing': 'MTL_SHADER_VALIDATION',
        }
        for case, flag in cases.items():
            with self.subTest(case=case):
                result = self.run_gate(case, package=True, extra_env={flag: '0'})
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn('incomplete', result.stdout)
                self.assertEqual(self.run_gate(case, package=True, extra_env={flag: '1'}).returncode, 1)
        self.assertEqual(self.run_gate('MonitorKitUITests.DisplayLinkTests testNewRequiredGPUProof', package=True).returncode, 1)

    def test_shader_validation_request_matches_monitor_pipeline_predicate(self):
        source = (ROOT / 'Packages/MonitorKit/Sources/MonitorKit/MonitorPipelineArchive.swift').read_text()
        self.assertIn('environment["MTL_SHADER_VALIDATION"].map { $0 != "0" } ?? false', source)
        case = 'MonitorKitTests.PipelineArchiveValidationTests testAValidatedSessionBuildsAndWritesNothing'
        for value in ('1', '2', 'true', 'nonzero', ''):
            with self.subTest(value=value):
                self.assertEqual(self.run_gate(case, package=True, extra_env={'MTL_SHADER_VALIDATION': value}).returncode, 1)
        self.assertEqual(self.run_gate(case, package=True, extra_env={'MTL_SHADER_VALIDATION': '0'}).returncode, 0)
        with unittest.mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(self.run_gate(case, package=True).returncode, 0)

    def test_actual_hardware_entrypoint_and_both_logs_use_strict_gate(self):
        hardware = (ROOT / 'scripts/ci-vendor-checks.sh').read_text()
        self.assertIn('export ULTRACAM_REQUIRE_GPU_PROOFS=1', hardware.split('if [[ "$mode" == --hardware ]]', 1)[1])
        runner = (ROOT / 'scripts/test.sh').read_text()
        self.assertIn('Tests/DiagnosticContracts', runner)
        self.assertIn('check-gpu-proof-skips.py" --app "$test_log"', runner)
        self.assertIn('check-gpu-proof-skips.py" --package "$monitor_kit_test_log"', runner)

if __name__ == '__main__':
    unittest.main()
