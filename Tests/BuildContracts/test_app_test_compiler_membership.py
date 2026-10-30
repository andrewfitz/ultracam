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
                         'Sources/App/UltracamApp.swift', 'Sources/CameraExtension/main.swift',
                         'Sources/Program/ProgramScalingPolicy.swift'):
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
            self.assertIn(str(checkout / 'Sources/Program/ProgramScalingPolicy.swift'), actual)
            self.assertIn(str(checkout / 'Sources/App/AppModel.swift'), actual)
            self.assertIn(str(checkout / 'Sources/App/Ordinary.swift'), actual)
            self.assertNotIn(str(checkout / 'Sources/App/UltracamApp.swift'), actual)
            self.assertNotIn(str(checkout / 'Sources/CameraExtension/main.swift'), actual)

    def test_integration_compiler_arguments_include_program(self):
        for runner in ('ui-verify.sh', 'monitor-app-integration.sh', 'monitor-feed-host-checks.sh'):
            with self.subTest(runner=runner), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                source = base / 'Sources/Program/ProgramScalingPolicy.swift'
                source.parent.mkdir(parents=True)
                source.write_text('// fixture')
                binary = base / 'xcrun'
                binary.write_text('#!' + sys.executable + '\nimport json,os,sys\nopen(os.environ["ARGS"],"w").write(json.dumps(sys.argv[1:]))\n')
                binary.chmod(0o755)
                text = (ROOT / 'scripts' / runner).read_text()
                fragment = 'xcrun swiftc' + text.split('xcrun swiftc', 1)[1].split('>> "$test_root/compile.log"', 1)[0]
                prefix = 'set -euo pipefail\ntask_root="$FIXTURE_ROOT"\ntest_root="$FIXTURE_ROOT"\nvendor_bridge=fixture\nframeworks=f\nlibraries=l\nauto_switcher_lib=r\nmonitor_kit_link_args=(-I fixture)\nvendor_swift_native_args=()\nvendor_swift_sources=()\nvendor_native_objects=()\nvendor_link_args=()\napp_sources=(fixture.swift)\n'
                shell = base / 'invocation.sh'
                shell.write_text(prefix + fragment)
                output = base / 'args.json'
                result = subprocess.run(['/bin/bash', str(shell)], capture_output=True, text=True,
                    env=dict(os.environ, PATH=str(base) + os.pathsep + os.environ['PATH'], FIXTURE_ROOT=str(base), ARGS=str(output)))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(str(source), json.loads(output.read_text()))


if __name__ == '__main__':
    unittest.main()
