"""Exercise build preflight without compiling, signing or touching real SDKs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SignedReleasePolicyTests(unittest.TestCase):
    def run_build(self, arguments, sony=False, verification_failure=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts'
            scripts.mkdir()
            (scripts / 'build.sh').write_bytes((ROOT / 'scripts/build.sh').read_bytes())
            (scripts / 'vendors.py').write_text(
                'import os\ndef read_inventory(*args, **kwargs):\n'
                ' return [], {"sony": {"available": os.environ.get("TEST_SONY") == "yes"}}\n')
            (scripts / 'vendor-sdk.py').write_text(
                'import os, sys\nassert sys.argv[1:] == ["verify", "sony"]\n'
                'raise SystemExit(2 if os.environ.get("TEST_VERIFY_FAIL") else 0)\n')
            (scripts / 'work_paths.py').write_text('raise SystemExit(77)\n')
            env = dict(os.environ, DEVELOPMENT_TEAM='TEST_ONLY', TEST_SONY='yes' if sony else 'no')
            if verification_failure:
                env['TEST_VERIFY_FAIL'] = 'yes'
            return subprocess.run(['bash', str(scripts / 'build.sh'), *arguments],
                                  env=env, capture_output=True, text=True)

    def test_signed_release_refuses_disabled_sony_before_build(self):
        result = self.run_build(['--signed'])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Signed Release builds require the Sony SDK enabled', result.stderr)

    def test_signed_release_with_sony_reaches_local_build_without_official_evidence(self):
        self.assertEqual(self.run_build(['--signed'], sony=True).returncode, 77)

    def test_signed_release_refuses_failed_sdk_verification(self):
        self.assertEqual(self.run_build(['--signed'], sony=True, verification_failure=True).returncode, 2)

    def test_unsigned_release_and_signed_debug_allow_sdk_absence(self):
        for arguments in ([], ['--signed', '--debug']):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_build(arguments).returncode, 77)
