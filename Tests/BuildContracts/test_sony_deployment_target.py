"""All standalone Sony native and Swift actions share the supported minimum."""
import os
from pathlib import Path
import re
import unittest

ROOT = Path(os.environ.get('SONY_DEPLOYMENT_FIXTURE_ROOT', str(Path(__file__).resolve().parents[2])))
RUNNERS = ('sony-credential-checks.sh', 'sony-plugin-checks.sh', 'sony-control-checks.sh', 'sony-conformance-checks.sh')

class SonyDeploymentTargetChecks(unittest.TestCase):
    def test_native_compile_and_link_inherit_explicit_supported_minimum(self):
        for runner in RUNNERS:
            with self.subTest(runner=runner):
                source = (ROOT / 'scripts' / runner).read_text()
                declaration = 'export MACOSX_DEPLOYMENT_TARGET=26.0'
                self.assertIn(declaration, source)
                self.assertLess(source.index(declaration), source.index('vendor_compile_native'))
                self.assertLess(source.index(declaration), source.index('xcrun swiftc'))
                if 'xcrun clang++' in source:
                    self.assertLess(source.index(declaration), source.index('xcrun clang++'))

    def test_every_swift_action_targets_same_arm64_minimum(self):
        for runner in RUNNERS:
            source = (ROOT / 'scripts' / runner).read_text().replace('\\\n', ' ')
            commands = re.findall(r'^\s*xcrun swiftc[^\n]+', source, re.MULTILINE)
            self.assertTrue(commands, runner)
            for command in commands:
                with self.subTest(runner=runner, command=command):
                    self.assertIn('-target arm64-apple-macos26.0', command)

if __name__ == '__main__':
    unittest.main()
