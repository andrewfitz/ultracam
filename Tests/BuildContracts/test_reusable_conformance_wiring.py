import json
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]

class ReusableConformanceWiringTests(unittest.TestCase):
    def test_sony_manifest_invokes_actual_adapter_shared_oracle(self):
        manifest = json.loads((ROOT / 'Vendors/Sony/vendor.json').read_text())
        group = manifest['testGroups']['reusable-conformance']
        self.assertIn('../../Tests/ControlPluginConformanceHarness.swift', group['swiftSources'])
        self.assertIn('Tests/SonyReusableConformance.swift', group['swiftSources'])
        self.assertNotIn('Tests/SonyPluginChecks.swift', group['swiftSources'])
        self.assertFalse(group['sdk'])
        self.assertIn('../../scripts/sony-conformance-checks.sh', manifest['tests'])

    def test_decklink_actual_adapter_oracle_is_test_only_member(self):
        manifest = json.loads((ROOT / 'Vendors/Blackmagic/vendor.json').read_text())
        entry = next(e for e in manifest['sources'] if e['path'] == 'Tests/DeckLinkReusableConformanceChecks.swift')
        self.assertEqual(entry['membership'], ['test'])
