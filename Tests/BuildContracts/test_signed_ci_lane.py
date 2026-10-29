"""The credentialed lane must build and validate, with explicit trust gates."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]

class SignedCILaneChecks(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / '.github/workflows/signed-validation.yml').read_text()

    def test_lane_is_manual_main_branch_and_repository_environment_gated(self):
        for text in ('workflow_dispatch:', "github.ref == 'refs/heads/main'", "vars.ULTRACAM_SIGNED_CI == 'enabled'", 'environment: signed-validation', 'contents: read', 'persist-credentials: false'):
            self.assertIn(text, self.workflow)
        self.assertNotIn('pull_request:', self.workflow)
        self.assertNotIn('self-hosted', self.workflow)

    def test_actual_signed_build_and_explicit_signature_validation(self):
        for text in ('vendor-sdk.py install sony', 'vendor-sdk.py verify sony', 'scripts/build.sh --signed --sdk-inventory', 'scripts/validate_bundle.py', 'codesign --verify --deep --strict', 'ULTRACAM_SDK_INVENTORY:', 'ULTRACAM_WORK_ROOT:'):
            self.assertIn(text, self.workflow)
        self.assertNotIn('--official-release', self.workflow)
        self.assertNotIn('/Volumes/', self.workflow)
        self.assertNotIn('upload-artifact', self.workflow)

    def test_secrets_are_step_scoped_and_ephemeral_material_is_cleaned(self):
        for text in ('if: always()', 'security delete-keychain', 'profiles-installed.txt', 'ULTRACAM_SIGNING_P12_BASE64', 'ULTRACAM_SIGNING_P12_PASSWORD', 'ULTRACAM_APP_PROFILE_BASE64', 'ULTRACAM_CAMERA_PROFILE_BASE64', 'ULTRACAM_SONY_SDK_ARCHIVE_URL', 'umask 077'):
            self.assertIn(text, self.workflow)
        self.assertNotIn('set -x', self.workflow)
        self.assertNotIn('${{ secrets.', self.workflow.split('    steps:')[0])

    def test_shell_steps_and_embedded_python_parse_without_executing(self):
        lines = self.workflow.splitlines()
        scripts = []
        for index, line in enumerate(lines):
            if line == '        run: |':
                body = []
                for following in lines[index + 1:]:
                    if following and not following.startswith('          '):
                        break
                    body.append(following[10:])
                scripts.append('\n'.join(body) + '\n')
        self.assertEqual(len(scripts), 4)
        for script in scripts:
            result = subprocess.run(['/bin/bash', '-n'], input=script, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            parts = script.split("<<'PY'\n")[1:]
            for part in parts:
                compile(part.split('\nPY\n')[0], '<workflow-python>', 'exec')

if __name__ == '__main__':
    unittest.main()
