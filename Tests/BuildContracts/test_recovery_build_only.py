"""Compile validation must never accidentally execute the recovery writer tool."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RecoveryBuildOnlyTests(unittest.TestCase):
    def test_build_only_does_not_launch_the_compiled_helper(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binaries = root / 'bin'
            binaries.mkdir()
            compiler = binaries / 'xcrun'
            compiler.write_text('#!' + sys.executable + '\n' + '''
import os, pathlib, sys
target = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
target.write_text('#!' + sys.executable + '\\nimport os, pathlib\\npathlib.Path(os.environ["LAUNCH_MARKER"]).write_text("launched")\\n')
target.chmod(0o755)
''')
            compiler.chmod(0o755)
            marker = root / 'launched'
            environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'],
                ULTRACAM_WORK_ROOT=str(root / 'work'), LAUNCH_MARKER=str(marker))
            command = ['/bin/bash', str(ROOT / 'scripts/recording-recovery-smoke.sh'), '--build-only']
            result = subprocess.run(command, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists(), 'Build-only mode launched the writer helper')
            result = subprocess.run(command[:-1] + ['--unknown'], env=environment,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
