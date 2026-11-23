"""A report written before an abnormal exit must not make the app gate pass."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SelfTestExitStatusTests(unittest.TestCase):
    def test_timeout_larger_than_bash_integer_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                ['/bin/bash', str(ROOT / 'scripts/app-self-test.sh')],
                env=dict(os.environ, ULTRACAM_WORK_ROOT=temporary, SKIP_BUILD='1',
                         SELF_TEST_TIMEOUT='18446744073709551617'),
                capture_output=True, text=True, timeout=5,
            )
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('SELF_TEST_TIMEOUT', result.stderr)

    def test_timeout_reaps_an_app_that_ignores_termination(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            binary = work / 'agent-work/ultracam/Ultracam.app/Contents/MacOS/Ultracam'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!' + sys.executable + '\n' + '''
import os, pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
(pathlib.Path(sys.argv[2]) / 'app.pid').write_text(str(os.getpid()))
time.sleep(60)
''')
            binary.chmod(0o755)
            environment = dict(os.environ, ULTRACAM_WORK_ROOT=str(work), SKIP_BUILD='1', SELF_TEST_TIMEOUT='2')
            result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/app-self-test.sh')],
                                    env=environment, capture_output=True, text=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('timed out', result.stderr)
            pid = int((work / 'agent-work/build/ultracam/app-self-test/latest/app.pid').read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_exit_checks_process_status_and_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            binary = work / 'agent-work/ultracam/Ultracam.app/Contents/MacOS/Ultracam'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!' + sys.executable + '\n' + '''
import os, pathlib, sys
(pathlib.Path(sys.argv[2]) / 'report.json').write_text(os.environ['TEST_REPORT'])
sys.exit(int(os.environ['APP_EXIT_STATUS']))
''')
            binary.chmod(0o755)
            valid = {'checks': [{'name': 'fixture', 'detail': '', 'pass': True}],
                     'passed': 1, 'failed': 0, 'pass': True}
            for status, report, expected, diagnostic in (
                (7, valid, 7, 'app exited with status 7'),
                (0, valid, 0, '1 passed, 0 failed'),
                (0, dict(valid, passed=2), 1, 'summary disagrees'),
                (0, dict(valid, passed=True), 1, 'summary disagrees'),
                (0, dict(valid, checks=[{'pass': True}]), 1, 'invalid check results'),
            ):
                with self.subTest(app_status=status, report=report):
                    environment = dict(os.environ, ULTRACAM_WORK_ROOT=str(work), SKIP_BUILD='1',
                                       APP_EXIT_STATUS=str(status), TEST_REPORT=json.dumps(report))
                    result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/app-self-test.sh')],
                                            env=environment, capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                    self.assertIn(diagnostic, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
