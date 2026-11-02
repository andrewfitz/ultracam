"""A report written before an abnormal exit must not make the app gate pass."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SelfTestExitStatusTests(unittest.TestCase):
    def test_report_does_not_hide_nonzero_app_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            binary = work / 'agent-work/ultracam/Ultracam.app/Contents/MacOS/Ultracam'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
(pathlib.Path(sys.argv[2]) / 'report.json').write_text(json.dumps(
    {'checks': [], 'passed': 1, 'failed': 0, 'pass': True}))
sys.exit(int(os.environ['APP_EXIT_STATUS']))
''')
            binary.chmod(0o755)
            for status in (7, 0):
                environment = dict(os.environ, ULTRACAM_WORK_ROOT=str(work),
                                   SKIP_BUILD='1', APP_EXIT_STATUS=str(status))
                result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/app-self-test.sh')],
                                        env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
