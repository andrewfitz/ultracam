"""Exercise the actual test compiler's argument construction without a build."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AppTestCompilerMembershipTests(unittest.TestCase):
    def test_real_app_model_is_compiled_without_either_executable_main(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            checkout = base / 'checkout with spaces'
            for path in ('Sources/App/AppModel.swift', 'Sources/App/Ordinary.swift',
                         'Sources/App/UltracamApp.swift', 'Sources/CameraExtension/main.swift'):
                file = checkout / path
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('// fixture\n')
            binaries = base / 'bin'
            binaries.mkdir()
            compiler = binaries / 'xcrun'
            compiler.write_text('#!' + sys.executable + '\n' +
                'import json, os, pathlib, sys\n' +
                'pathlib.Path(os.environ["COMPILER_ARGUMENTS"]).write_text(json.dumps(sys.argv[1:]))\n')
            compiler.chmod(0o755)
            source = (ROOT / 'scripts/test.sh').read_text()
            fragment = source.split('vendor_compile_native "$compile_log"\n', 1)[1]
            fragment = fragment.split('>> "$compile_log" 2>&1 || {', 1)[0]
            prefix = '''set -euo pipefail
task_root="$FIXTURE_CHECKOUT"
test_root="$FIXTURE_OUTPUT"
compile_log="$FIXTURE_OUTPUT/compile.log"
vendor_bridge=fixture.h
frameworks=frameworks
libraries=libraries
auto_switcher_lib=rust
monitor_kit_link_args=(-I fixture)
vendor_swift_native_args=()
vendor_swift_sources=()
vendor_native_objects=()
vendor_link_args=()
'''
            arguments = base / 'arguments.json'
            environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'],
                FIXTURE_CHECKOUT=str(checkout), FIXTURE_OUTPUT=str(base),
                COMPILER_ARGUMENTS=str(arguments))
            result = subprocess.run(['/bin/bash', '-c', prefix + fragment], env=environment,
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            actual = json.loads(arguments.read_text())
            self.assertIn(str(checkout / 'Sources/App/AppModel.swift'), actual)
            self.assertIn(str(checkout / 'Sources/App/Ordinary.swift'), actual)
            self.assertNotIn(str(checkout / 'Sources/App/UltracamApp.swift'), actual)
            self.assertNotIn(str(checkout / 'Sources/CameraExtension/main.swift'), actual)


if __name__ == '__main__':
    unittest.main()
