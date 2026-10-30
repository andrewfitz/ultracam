#!/usr/bin/env python3
"""Explain lost frames after the fact.

  diagnose-capture.py take MOVIE   gaps in a take's video timeline, each with
                                   Ultracam's log lines from that moment
  diagnose-capture.py devices      what each UltraStudio reports now: signal
                                   lock, detected mode, link, temperature

`take` needs ffprobe (Homebrew ffmpeg) and reads the unified log, which keeps
Ultracam's notice lines for a few days. The capture log names a signal
dropout ("Signal back on … after a dropout"). Use --camera with the exact
capture feed ID to correlate only that camera. Unmatched gaps have unknown cause.
Only a sidecar declaring constant cadence supports inferred missing-frame counts;
VFR/unknown cadence uses packet durations to report uncovered intervals.
Read-only: neither command opens a capture input.
"""
import argparse
import datetime as dt
import json
import shutil
import subprocess
import sys
import re
import tempfile
from fractions import Fraction
from typing import NamedTuple
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# The vendor folder, or the older ThirdParty layout.
SDK = next((p for p in (ROOT / "Vendors/Blackmagic/SDK/include", ROOT / "ThirdParty/DeckLinkSDK/include")
            if (p / "DeckLinkAPI.h").is_file()), ROOT / "Vendors/Blackmagic/SDK/include")
SUBSYSTEM = "org.ultracam.app"
WINDOW = 3.0  # seconds of log either side of a gap
ENTRY = re.compile(r"\[org\.ultracam\.app:(?P<category>[^\]]+)\] (?P<message>.*)")


def run(args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw).stdout


class Gap(NamedTuple):
    at: float
    duration: float
    missing_frames: int | None


def recorded_rate(movie):
    """Use the output contract: a VFR source can explicitly be conformed to CFR."""
    try:
        metadata = json.loads(Path(str(movie) + ".ultracam.json").read_text())["metadata"]
        contract = metadata.get("outputContract") or metadata.get("sourceFormat") or {}
        rate = contract.get("rate", {})
        return rate if isinstance(rate, dict) else {}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {}


def movie_gaps(movie):
    """Return uncovered intervals; only a declared CFR contract implies frame loss."""
    if not shutil.which("ffprobe"):
        sys.exit("ffprobe is required: brew install ffmpeg")
    info = json.loads(run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=time_base,r_frame_rate,nb_frames:format_tags=creation_time", "-of", "json", str(movie)]))
    if not info.get("streams"):
        sys.exit("The movie has no video stream")
    stream = info["streams"][0]
    base = Fraction(stream["time_base"])
    rate = recorded_rate(movie)
    nominal = rate.get("nominal", {})
    try:
        # SourceFormat.ContractTime encodes normalized seconds as Rational.
        value = nominal["value"]
        frame_seconds = Fraction(value["numerator"], value["denominator"])
        if nominal.get("epoch", 0) != 0:
            raise ValueError("unsupported epoch")
        if frame_seconds <= 0:
            raise ValueError("invalid declared duration")
    except (KeyError, TypeError, ValueError, ZeroDivisionError):
        frame_seconds = None
    constant = rate.get("kind") == "constant" and frame_seconds is not None
    try:
        fps = float(Fraction(stream["r_frame_rate"]))
    except (KeyError, ValueError, ZeroDivisionError):
        fps = 0.0
    if frame_seconds:
        fps = float(1 / frame_seconds)
    created = info.get("format", {}).get("tags", {}).get("creation_time")
    packets = json.loads(run(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "packet=pts,duration", "-of", "json", str(movie)])).get("packets", [])
    timed = []
    for packet in packets:
        try:
            pts = int(packet["pts"])
        except (KeyError, TypeError, ValueError):
            continue
        try:
            duration = max(0, int(packet.get("duration", 0)))
        except (TypeError, ValueError):
            duration = 0
        timed.append((pts, duration))
    timed.sort()
    gaps = []
    origin = timed[0][0] if timed else 0
    covered_until = origin
    for index, (pts, duration) in enumerate(timed):
        if index:
            if constant:
                prior = timed[index - 1][0]
                missing = round((pts - prior) * base / frame_seconds) - 1
                if missing > 0:
                    gaps.append(Gap(float((prior - origin) * base),
                                    float(missing * frame_seconds), missing))
            elif pts > covered_until:
                # Missing sample durations do not establish an uncovered range.
                # Never substitute ffprobe's nominal rate for a VFR duration.
                prior, prior_duration = timed[index - 1]
                if prior_duration > 0:
                    gaps.append(Gap(float((covered_until - origin) * base),
                                    float((pts - covered_until) * base), None))
        covered_until = max(covered_until, pts + duration)
    start = dt.datetime.fromisoformat(created.replace("Z", "+00:00")).astimezone() if created else None
    return gaps, len(timed), start, fps


def log_lines(start, end):
    fmt = "%Y-%m-%d %H:%M:%S"
    out = run(["/usr/bin/log", "show", "--style", "compact", "--start", start.strftime(fmt), "--end", end.strftime(fmt),
        "--predicate", f'process == "Ultracam" AND subsystem == "{SUBSYSTEM}"'])
    lines = []
    for line in out.splitlines():
        try:
            when = dt.datetime.strptime(line[:23], "%Y-%m-%d %H:%M:%S.%f").astimezone()
        except ValueError:
            continue
        match = ENTRY.search(line, 24)
        if match:
            lines.append((when, match["category"], match["message"]))
    return lines


def capture_camera(message):
    """Extract the exact feed ID emitted as CaptureController.runLabel."""
    for pattern in (r"Signal back on (.+?) after a dropout:",
                    r"No video from (.+?) for [0-9.]+ s;",
                    r"Capture summary (.+?): .*signalDropouts=",
                    r"Live (.+?) fps="):
        match = re.match(pattern, message)
        if match:
            return match[1]
    return None


def gap_description(gap):
    if gap.missing_frames is None:
        return f"{gap.duration:.6f} s uncovered presentation interval (frame loss unknown)"
    m = gap.missing_frames
    return f"{m} frame{'s' if m != 1 else ''}"


def take(args):
    movie = Path(args.movie).expanduser()
    gaps, frames, start, fps = movie_gaps(movie)
    missing = sum(g.missing_frames or 0 for g in gaps)
    uncovered = sum(g.missing_frames is None for g in gaps)
    print(f"{movie.name}: {frames} frames at {fps:.3f} nominal fps, {missing} inferred missing frames in {len(gaps)} gaps"
          + (f", {uncovered} intervals with unknown frame loss" if uncovered else ""))
    if not gaps:
        return
    if start is None:
        print("No creation time in the movie, so its gaps can't be matched to the log.")
        for gap in gaps:
            print(f"  {gap.at:10.3f} s  {gap_description(gap)}")
        return
    end = start + dt.timedelta(seconds=max(g.at + g.duration for g in gaps) + 60)
    lines = log_lines(start - dt.timedelta(seconds=60), end)
    summaries = [text for _, _, text in lines if movie.name in text]
    # Current take metadata has no feed ID. Require the caller to supply the
    # exact capture feed ID rather than guessing from a filename or another run.
    camera = getattr(args, "camera", None)
    camera_lines = [(w, c, t) for w, c, t in lines
                    if camera is not None and c == "capture" and capture_camera(t) == camera]
    dropouts = 0
    for gap in gaps:
        wall = start + dt.timedelta(seconds=gap.at)
        gap_end = wall + dt.timedelta(seconds=gap.duration)
        near = [(w, c, t) for w, c, t in camera_lines
                if wall - dt.timedelta(seconds=WINDOW) <= w <= gap_end + dt.timedelta(seconds=WINDOW)
                and not t.startswith("Live ")]
        dropout = any("after a dropout" in t or "No video from" in t for _, _, t in near)
        dropouts += dropout
        # A movie gap alone cannot distinguish device, ingest or writer loss.
        kind = "signal dropout" if dropout else ("unknown: no camera ID; use --camera" if camera is None
                                                    else "unknown: no matching signal dropout")
        print(f"\n{gap.at:10.3f} s  {wall:%H:%M:%S.%f}"[:-3] + f"  {gap_description(gap)}  [{kind}]")
        for w, c, t in near[: args.lines]:
            print(f"    {w:%H:%M:%S.%f}"[:-3] + f"  {c:<9} {t[:200]}")
    print(f"\n{dropouts} of {len(gaps)} gaps line up with a logged signal dropout for this camera.")
    for text in summaries:
        print(f"Take summary: {text[:400]}")


PROBE = r'''
#import <Foundation/Foundation.h>
#include "DeckLinkAPI.h"
#include <cstdio>
static void i(IDeckLinkStatus *s, BMDDeckLinkStatusID id, const char *n) {
  int64_t v = 0; if (s->GetInt(id, &v) == S_OK) printf("  %-24s %lld (0x%llx)\n", n, v, v);
}
static void f(IDeckLinkStatus *s, BMDDeckLinkStatusID id, const char *n) {
  bool v = false; if (s->GetFlag(id, &v) == S_OK) printf("  %-24s %s\n", n, v ? "yes" : "no");
}
int main() { @autoreleasepool {
  IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
  if (!it) { printf("No DeckLink driver installed.\n"); return 1; }
  IDeckLink *d = nullptr; int count = 0;
  while (it->Next(&d) == S_OK) {
    count++;
    CFStringRef name = nullptr; d->GetDisplayName(&name);
    printf("%s\n", name ? [(__bridge NSString *)name UTF8String] : "?");
    if (name) CFRelease(name);
    IDeckLinkProfileAttributes *a = nullptr;
    if (d->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&a) == S_OK) {
      int64_t id = 0; if (a->GetInt(BMDDeckLinkPersistentID, &id) == S_OK) printf("  %-24s decklink:%016llx\n", "device ID", id);
      a->Release();
    }
    IDeckLinkStatus *s = nullptr;
    if (d->QueryInterface(IID_IDeckLinkStatus, (void **)&s) == S_OK) {
      f(s, bmdDeckLinkStatusVideoInputSignalLocked, "input signal locked");
      i(s, bmdDeckLinkStatusBusy, "busy (1 = capturing)");
      i(s, bmdDeckLinkStatusDetectedVideoInputMode, "detected mode");
      i(s, bmdDeckLinkStatusDetectedVideoInputFormatFlags, "detected format flags");
      i(s, bmdDeckLinkStatusDetectedVideoInputColorspace, "detected colorspace");
      i(s, bmdDeckLinkStatusPCIExpressLinkWidth, "PCIe link width");
      i(s, bmdDeckLinkStatusPCIExpressLinkSpeed, "PCIe link generation");
      s->Release();
    }
    IDeckLinkStatistics *st = nullptr;
    if (d->QueryInterface(IID_IDeckLinkStatistics, (void **)&st) == S_OK) {
      int64_t t = 0; if (st->GetInt(bmdDeckLinkStatisticDeviceTemperature, &t) == S_OK) printf("  %-24s %lld °C\n", "temperature", t);
      st->Release();
    }
    d->Release();
  }
  it->Release();
  if (!count) printf("No devices connected.\n");
}}
'''


def fourcc(value):
    try:
        return int(value).to_bytes(4, "big").decode("ascii")
    except (ValueError, OverflowError, UnicodeDecodeError):
        return None


def devices(_args):
    if not (SDK / "DeckLinkAPI.h").is_file():
        sys.exit(f"The DeckLink SDK headers are missing at {SDK}")
    with tempfile.TemporaryDirectory(prefix="ultracam-devices-") as work:
        source, binary = Path(work, "probe.mm"), Path(work, "probe")
        source.write_text(PROBE)
        run(["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-w", f"-I{SDK}", str(source),
            str(SDK / "DeckLinkAPIDispatch.cpp"), "-framework", "Foundation", "-o", str(binary)])
        for line in run([str(binary)]).splitlines():
            # Modes and colorspaces are four-character codes ('4k59', 'r709').
            if "(0x" in line and ("mode" in line or "colorspace" in line):
                code = fourcc(line.split()[-2])
                if code:
                    line = f"{line}  '{code}'"
            print(line)
    print("\nThunderbolt link (system_profiler):")
    report = run(["system_profiler", "SPThunderboltDataType"])
    for block in report.split("\n\n"):
        if "UltraStudio" in block or "Blackmagic" in block:
            for line in block.splitlines():
                if any(k in line for k in ("Device Name", "Firmware Version", "Speed", "Status", "Mode")):
                    print("  " + line.strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    t = sub.add_parser("take", help="gaps in a take, matched to the log")
    t.add_argument("movie")
    t.add_argument("--camera", help="exact capture feed ID used in Ultracam logs; required for causal attribution")
    t.add_argument("--lines", type=int, default=6, help="log lines to show per gap")
    t.set_defaults(func=take)
    sub.add_parser("devices", help="UltraStudio status now").set_defaults(func=devices)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
