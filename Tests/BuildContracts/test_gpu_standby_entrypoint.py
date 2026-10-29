"""Portable proof entrypoint must compile strictly and preserve build-only isolation."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GPUStandbyEntryPointTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        binaries = self.root / 'bin'
        binaries.mkdir()
        compiler = binaries / 'xcrun'
        compiler.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
pathlib.Path(os.environ['COMPILE_MARKER']).write_text(json.dumps(sys.argv))
target = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
target.write_text('#!' + sys.executable + '\\n' + "import json, os, pathlib, sys\\npathlib.Path(os.environ['LAUNCH_MARKER']).write_text('launched')\\npathlib.Path(sys.argv[sys.argv.index('--output') + 1]).write_text(json.dumps({'schemaVersion':1,'status':os.environ.get('PROOF_STATUS','passed'),'slots':[]}))\\nsys.exit(int(os.environ.get('PROOF_EXIT','0')))\\n")
target.chmod(0o755)
''')
        compiler.chmod(0o755)
        self.marker = self.root / 'launched'
        self.compile = self.root / 'compile.json'
        self.environment = dict(os.environ,
            PATH=str(binaries) + os.pathsep + os.environ['PATH'],
            ULTRACAM_WORK_ROOT=str(self.root / 'work root'),
            LAUNCH_MARKER=str(self.marker), COMPILE_MARKER=str(self.compile))

    def run_script(self, *arguments):
        return subprocess.run(['/bin/bash', str(ROOT / 'scripts/check-gpu-standby.sh'), *arguments],
            env=self.environment, capture_output=True, text=True)

    def test_build_only_is_strict_and_never_launches_the_proof(self):
        result = self.run_script('--build-only')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.marker.exists())
        command = json.loads(self.compile.read_text())
        for flag in ('-swift-version', '-strict-concurrency=complete', '-warnings-as-errors'):
            self.assertIn(flag, command)
        self.assertEqual(command[command.index('-swift-version') + 1], '6')
        self.assertTrue(any(path.endswith('/DerivedOutputAdmission.swift') for path in command))
        self.assertEqual(self.run_script('--unknown').returncode, 2)

    def test_default_runs_once_and_keeps_machine_readable_evidence_in_work_root(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        evidence = list((self.root / 'work root').rglob('evidence.json'))
        self.assertEqual(len(evidence), 1)
        self.assertEqual(json.loads(evidence[0].read_text())['status'], 'passed')

    def test_unsupported_hardware_keeps_evidence_and_nonzero_result(self):
        self.environment.update(PROOF_STATUS='unsupported', PROOF_EXIT='7')
        result = self.run_script()
        self.assertEqual(result.returncode, 7)
        evidence = list((self.root / 'work root').rglob('evidence.json'))
        self.assertEqual(len(evidence), 1)
        self.assertEqual(json.loads(evidence[0].read_text())['status'], 'unsupported')
        self.assertIn('failed or unsupported', result.stderr)


if __name__ == '__main__':
    unittest.main()
