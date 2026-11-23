import contextlib
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('diagnose_capture', Path(__file__).resolve().parents[2] / 'scripts/diagnose-capture.py')
diag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diag)


class CaptureDiagnosticTests(unittest.TestCase):
    def test_failed_tool_diagnostic_reaches_cli(self):
        for stdout, stderr in [('', 'Invalid movie'), ('No DeckLink driver installed.', '')]:
            failure = subprocess.CalledProcessError(1, ['probe'], output=stdout, stderr=stderr)
            with self.subTest(stdout=stdout, stderr=stderr):
                with (patch.object(sys, 'argv', ['diagnose', 'take', 'take.mov']),
                      patch.object(diag, 'movie_gaps', side_effect=failure),
                      contextlib.redirect_stderr(io.StringIO()) as message,
                      self.assertRaises(SystemExit) as caught):
                    diag.main()
                self.assertEqual(caught.exception.code, 1)
                self.assertIn(stderr or stdout, message.getvalue())

    def analyze(self, pts, durations, kind, source_kind=None, creation_time=None):
        with tempfile.TemporaryDirectory() as folder:
            movie = Path(folder) / 'take.mov'
            if kind:
                Path(str(movie) + '.ultracam.json').write_text(json.dumps({'metadata': {
                    'outputContract': {'rate': {'kind': kind, 'nominal': {'value': {'numerator': 1, 'denominator': 30}, 'epoch': 0}}},
                    'sourceFormat': {'rate': {'kind': source_kind or kind}}}}))
            info = {'streams': [{'time_base': '1/30', 'r_frame_rate': '30/1'}],
                    'format': {'tags': {'creation_time': creation_time}}}
            packets = {'packets': [{'pts': p, 'duration': d} for p, d in zip(pts, durations)]}
            def run(args):
                return json.dumps(packets) if 'packet=pts,duration' in args else json.dumps(info)
            with patch.object(diag.shutil, 'which', return_value='/mock/ffprobe'), patch.object(diag, 'run', side_effect=run):
                return diag.movie_gaps(movie)

    def test_complete_vfr_has_no_loss(self):
        self.assertEqual(self.analyze([0, 1, 3, 4], [1, 2, 1, 1], 'variable')[0], [])

    def test_cfr_loss_remains_visible(self):
        gaps = self.analyze([0, 1, 3, 4], [1, 1, 1, 1], 'constant')[0]
        self.assertEqual(len(gaps), 1)
        self.assertEqual(gaps[0].missing_frames, 1)

    def test_cfr_gap_starts_at_first_missing_frame(self):
        gap, = self.analyze([90, 91, 94], [1, 1, 1], 'constant')[0]
        self.assertEqual(gap.missing_frames, 2)
        self.assertAlmostEqual(gap.at, 2 / 30)
        self.assertAlmostEqual(gap.at + gap.duration, 4 / 30)

    def test_vfr_uncovered_interval_has_no_invented_frame_count(self):
        gaps = self.analyze([0, 1, 3, 4], [1, 1, 1, 1], 'variable')[0]
        self.assertEqual(len(gaps), 1)
        self.assertIsNone(gaps[0].missing_frames)
        self.assertAlmostEqual(gaps[0].duration, 1/30)

    def test_unknown_cadence_uses_duration_without_guessing_frame_count(self):
        self.assertEqual(self.analyze([0, 1, 3, 4], [1, 2, 1, 1], None)[0], [])
        gap = self.analyze([0, 1, 3, 4], [1, 1, 1, 1], None)[0][0]
        self.assertIsNone(gap.missing_frames)

    def test_missing_duration_cannot_establish_vfr_loss(self):
        self.assertEqual(self.analyze([0, 1, 3, 4], [None, None, None, None], 'variable')[0], [])

    def test_invalid_creation_time_leaves_gaps_available(self):
        gaps, _, start, _ = self.analyze([0, 2], [1, 1], 'constant', creation_time='unknown')
        self.assertEqual(gaps[0].missing_frames, 1)
        self.assertIsNone(start)

    def test_missing_video_timestamps_are_reported(self):
        with self.assertRaisesRegex(SystemExit, 'no video packets with presentation timestamps'):
            self.analyze([None, 'N/A'], [1, 1], 'constant')

    def test_conformed_vfr_uses_recorded_constant_output(self):
        gap = self.analyze([0, 1, 3, 4], [1, 2, 1, 1], 'constant', source_kind='variable')[0][0]
        self.assertEqual(gap.missing_frames, 1)

    def test_camera_matching_is_exact(self):
        self.assertNotIn('[signal dropout]', self.output('A', 'AA'))

    def output(self, camera, dropout_camera, logged_at=0, duration_ms=1000):
        start = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        recovered = start + dt.timedelta(seconds=logged_at)
        lines = [(start, 'capture', f'Capture summary {dropout_camera}: signalDropouts=1'),
                 (recovered, 'capture', f'Signal back on {dropout_camera} after a dropout: 1 frame lost ({duration_ms} ms without video).')]
        gap = diag.Gap(0, 1/30, 1)
        with patch.object(diag, 'movie_gaps', return_value=([gap], 3, start, 30)), patch.object(diag, 'log_lines', return_value=lines):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                diag.take(SimpleNamespace(movie='take.mov', lines=6, camera=camera))
            return output.getvalue()

    def test_other_camera_does_not_supply_cause(self):
        self.assertNotIn('[signal dropout]', self.output('A', 'B'))

    def test_matching_camera_supplies_cause(self):
        self.assertIn('[signal dropout]', self.output('A', 'A'))

    def test_later_recovery_can_establish_an_earlier_outage(self):
        self.assertIn('[signal dropout]', self.output('A', 'A', logged_at=10, duration_ms=11_000))
        self.assertNotIn('[signal dropout]', self.output('A', 'A', logged_at=10, duration_ms=1_000))

    def test_unknown_camera_does_not_supply_cause(self):
        self.assertNotIn('[signal dropout]', self.output(None, 'B'))


if __name__ == '__main__':
    unittest.main()
