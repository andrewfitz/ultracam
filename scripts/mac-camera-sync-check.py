#!/usr/bin/env python3
"""Qualify two observed flash/click pairs on a recorded movie's presentation timeline."""

import argparse
import json
from fractions import Fraction


def evaluate(fps, first_video, first_audio, last_video, last_audio):
    if fps <= 0 or last_video <= first_video or last_audio <= first_audio:
        raise ValueError("FPS must be positive and the final cue must follow the first on both tracks.")
    initial = first_audio - first_video
    final = last_audio - last_video
    drift = final - initial
    period = 1 / fps
    interval = last_video - first_video
    return {
        "cue_interval_seconds": float(interval),
        "frame_period_ms": float(period * 1000),
        "initial_audio_minus_video_ms": float(initial * 1000),
        "final_audio_minus_video_ms": float(final * 1000),
        "accumulated_drift_ms": float(drift * 1000),
        "qualified": interval >= 600 and abs(initial) <= period and abs(drift) <= period,
    }


def rational(value):
    try:
        return Fraction(value)
    except (ValueError, ZeroDivisionError) as error:
        raise argparse.ArgumentTypeError("Supply a decimal or fraction with a nonzero denominator.") from error


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Use measured cue times in seconds on the same movie timeline. Space the flashes at least "
        "600 seconds apart. Positive offset means the click occurred after the flash."))
    parser.add_argument("--fps", type=rational, required=True)
    parser.add_argument("--first", nargs=2, metavar=("VIDEO", "AUDIO"), type=rational, required=True)
    parser.add_argument("--last", nargs=2, metavar=("VIDEO", "AUDIO"), type=rational, required=True)
    args = parser.parse_args()
    try:
        result = evaluate(args.fps, *args.first, *args.last)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["qualified"] else 1)
