"""The recorder must never drive the hardware HEVC encoder with the VBR property.

With kVTCompressionPropertyKey_VariableBitRate (macOS 26) the hardware HEVC encoder accepted
every frame and then never returned from VTCompressionSessionCompleteFrames, so a take could
not end. Ending the stuck process panicked the kernel in the video encoder's driver
(dart-ave1, three times on macOS 27.0.1 on an M4 Max). A runtime test for this would hang
and take the Mac down with it, so the rule is checked in the source instead.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
FORBIDDEN = ('kVTCompressionPropertyKey_VariableBitRate', 'kVTCompressionPropertyKey_VBVMaxBitRate')


def code(text):
    """Swift source without its line comments, where the property may be named to explain."""
    return '\n'.join(re.sub(r'//.*$', '', line) for line in text.splitlines())


class EncoderBitratePropertyTests(unittest.TestCase):
    def test_no_source_sets_the_variable_bitrate_property(self):
        offenders = []
        for folder in ('Sources', 'Tools', 'Vendors'):
            for path in sorted((ROOT / folder).rglob('*.swift')):
                source = code(path.read_text(encoding='utf-8', errors='replace'))
                offenders += [f'{path.relative_to(ROOT)}: {key}' for key in FORBIDDEN if key in source]
        self.assertEqual(offenders, [], 'Use kVTCompressionPropertyKey_AverageBitRate for a target bitrate.')

    def test_target_bitrate_uses_the_average_bitrate_property(self):
        writer = code((ROOT / 'Sources/Recording/AVAssetSourceRecordingWriter.swift').read_text(encoding='utf-8'))
        target = writer.index('configuration.targetVideoBitrate')
        self.assertIn('kVTCompressionPropertyKey_AverageBitRate', writer[target:target + 400])


if __name__ == '__main__':
    unittest.main()
