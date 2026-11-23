from array import array
import importlib.util
import math
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch


source = Path(__file__).resolve().parents[2] / 'Tools/ProgramStreamAppSmoke/verify.py'
spec = importlib.util.spec_from_file_location('app_stream_smoke', source)
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class ProgramAudioIdentityTests(unittest.TestCase):
    def verify_pair(self, right_hz, left_level=.36, right_level=.125):
        stereo = array('f')
        for sample in range(960 * 16):
            phase = 2 * math.pi * sample / 48_000
            stereo.extend((left_level * math.sin(phase * 900), right_level * math.sin(phase * right_hz)))

        with patch.object(verify, 'output', return_value=stereo.tobytes()):
            return verify.verify_audio_identity('fixture')

    def test_selected_pair_at_fixture_levels(self):
        self.assertGreater(self.verify_pair(900), 12)

    def test_wrong_right_channel_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Cutaway audio'):
            self.verify_pair(2000)

    def test_silent_right_channel_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'tone was missing'):
            self.verify_pair(0)

    def test_swapped_channels_are_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'level balance'):
            self.verify_pair(900, left_level=.125, right_level=.36)

    def test_duplicated_channel_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'level balance'):
            self.verify_pair(900, right_level=.36)


class ProgramSmokeEvidenceTests(unittest.TestCase):
    def test_missing_reconnect_recording_reports_qualification_failure(self):
        with tempfile.TemporaryDirectory() as work:
            folder = Path(work)
            app = Mock()
            app.poll.side_effect = [None] + [0] * 4
            listener = Mock()
            listener.poll.return_value = 0
            connections = [(folder / 'first.flv', listener), (folder / 'never-opened.flv', listener)]
            with (patch.object(verify, 'receive', side_effect=connections),
                  patch.object(verify.subprocess, 'Popen', return_value=app),
                  patch.object(verify.time, 'sleep'),
                  self.assertRaisesRegex(RuntimeError, 'No receiver captured media')):
                verify.run('fixture', folder, 18)

    def test_invalid_video_pts_reports_track_and_file(self):
        for invalid in ({}, {'pts_time': 'N/A'}, {'pts_time': 'inf'}):
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(RuntimeError, 'invalid video presentation time in received.flv'):
                    verify.presentation_times([{'pts_time': '0.033'}, invalid], 'video', 'received.flv')
