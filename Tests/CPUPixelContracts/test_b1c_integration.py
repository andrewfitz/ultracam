"""B1c resource-budget integration contracts for the CPU-access hook."""
from pathlib import Path
import importlib.util
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/check-cpu-pixel-access.py'
spec = importlib.util.spec_from_file_location('cpu_pixel_access_b1c', SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class B1cResourceLintIntegrationChecks(unittest.TestCase):
    def test_budget_and_lease_sources_have_no_unclassified_cpu_pixel_access(self):
        hits = checker.scan(ROOT)
        budget_paths = {
            'Sources/App/CaptureAdmissionBudget.swift',
            'Sources/App/AppResourceUsage.swift',
            'Sources/Recording/SourceRecording.swift',
            'Sources/Recording/AVAssetSourceRecordingWriter.swift',
            'Sources/Recording/RecordingPixelConverter.swift',
            'Sources/Shared/FeedRuntime.swift',
        }
        unresolved = [hit for hit in hits
                      if hit['classification'] == 'unclassified' and hit['path'] in budget_paths]
        self.assertEqual(unresolved, [])

    def test_cpu_hook_discovers_budget_sources_without_file_allowlist(self):
        hook = (ROOT / 'scripts/test.sh').read_text()
        self.assertIn('python3 "$task_root/scripts/check-cpu-pixel-access.py"', hook)
        checker_text = SCRIPT.read_text()
        self.assertNotIn('CaptureAdmissionBudget.swift', checker_text)
        self.assertNotIn('SourceRecording.swift', checker_text)

    def test_budget_sources_are_on_the_production_scan_surfaces(self):
        surfaces = ('Sources', 'Packages/MonitorKit/Sources', 'Vendors')
        self.assertTrue(all((ROOT / surface).exists() for surface in surfaces))
        for path in ('Sources/App/CaptureAdmissionBudget.swift',
                     'Sources/Recording/SourceRecording.swift'):
            self.assertTrue((ROOT / path).is_file())

    def test_hook_fails_when_new_budget_file_contains_video_cpu_access(self):
        # Exercise the same checker contract in a temporary source path by
        # writing a synthetic B1c budget file into a scanned surface.
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'Sources/Recording/NewRetentionBudget.swift'
            source.parent.mkdir(parents=True)
            source.write_text('func admit() { CVPixelBufferGetBaseAddress(image) }')
            self.assertEqual(len([hit for hit in checker.scan(root)
                                  if hit['classification'] == 'unclassified']), 1)


if __name__ == '__main__':
    unittest.main()
