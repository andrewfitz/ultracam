"""Exercise recovery smoke orchestration without launching an encoder."""
from contextlib import redirect_stdout
import importlib.util
from io import StringIO
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

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


class RecoveryOwnerExitTests(unittest.TestCase):
    def setUp(self):
        source = ROOT / 'Tools/RecordingRecoverySmoke/verify_owner_exit.py'
        spec = importlib.util.spec_from_file_location('verify_owner_exit', source)
        self.verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.verifier)

    def test_readiness_message_may_arrive_in_multiple_reads(self):
        with open(os.devnull, 'rb') as stream:
            with patch.object(self.verifier.select, 'select', return_value=([stream], [], [])), \
                 patch.object(self.verifier.os, 'read', side_effect=[b'RE', b'AD', b'Y\n']) as read:
                self.verifier.wait_for_ready(stream)
                self.assertEqual([call.args[1] for call in read.call_args_list], [6, 4, 2])

    def test_owner_exit_closes_the_control_pipe(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            writer = root / 'writer'
            writer.write_text('#!' + sys.executable + '\n' + '''
import os
import signal

os.write(1, b'READY\\n')
if os.read(0, 1) == b'':
    signal.raise_signal(signal.SIGKILL)
''')
            writer.chmod(0o755)
            with redirect_stdout(StringIO()) as output:
                self.verifier.verify_owner_exit(writer, root)
            self.assertIn('RECOVERY PASS owner exit', output.getvalue())


if __name__ == '__main__':
    unittest.main()
