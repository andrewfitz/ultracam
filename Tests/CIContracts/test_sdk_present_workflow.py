"""Guard the real-SDK CI lane against fixture substitution and publication."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SDKPresentWorkflowTests(unittest.TestCase):
    def test_real_sdk_lane_installs_verifies_and_builds_without_publishing(self):
        text = (ROOT / '.github/workflows/vendor-contracts.yml').read_text()
        self.assertIn('licensed-sony-unsigned-build:', text)
        lane = text.split('  licensed-sony-unsigned-build:', 1)[1].split('\n  synthetic-metal4-integration:', 1)[0]
        for required in ('vars.ULTRACAM_SONY_SDK_CI', "github.event_name != 'pull_request'",
                         'secrets.ULTRACAM_SONY_SDK_ARCHIVE_URL',
                         'vendor-sdk.py install sony', 'vendor-sdk.py verify sony',
                         'bash scripts/build.sh --sdk-inventory', 'bash scripts/ui-typecheck.sh'):
            self.assertIn(required, lane)
        for forbidden in ('upload-artifact', '--signed', '--official-release', 'fixture'):
            self.assertNotIn(forbidden, lane)
