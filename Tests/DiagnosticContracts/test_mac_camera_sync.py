from fractions import Fraction
import importlib.util
from pathlib import Path
import unittest


script = Path(__file__).resolve().parents[2] / "scripts/mac-camera-sync-check.py"
spec = importlib.util.spec_from_file_location("mac_camera_sync", script)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class MacCameraSyncTests(unittest.TestCase):
    def test_constant_quarter_second_lag_fails_even_without_drift(self):
        result = sync.evaluate(Fraction(30), 0, Fraction(1, 4), 600, Fraction(2401, 4))
        self.assertEqual(result["initial_audio_minus_video_ms"], 250)
        self.assertEqual(result["accumulated_drift_ms"], 0)
        self.assertFalse(result["qualified"])

    def test_drift_in_either_direction_is_independent_of_initial_offset(self):
        for offset in (Fraction(-1, 20), Fraction(1, 20)):
            self.assertFalse(sync.evaluate(Fraction(30), 0, 0, 600, 600 + offset)["qualified"])

    def test_exact_fractional_frame_and_ten_minute_bounds(self):
        rate = Fraction(30000, 1001)
        period = 1 / rate
        self.assertTrue(sync.evaluate(rate, 1, 1 - period, 601, 601)["qualified"])
        self.assertFalse(sync.evaluate(rate, 1, 1, 600, 600)["qualified"])
