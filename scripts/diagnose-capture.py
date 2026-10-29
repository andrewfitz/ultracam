#!/usr/bin/env python3
"""Explain lost frames after the fact.

  diagnose-capture.py take MOVIE   gaps in a take's video timeline, each with
                                   Ultracam's log lines from that moment
  diagnose-capture.py devices      what each UltraStudio reports now: signal
                                   lock, detected mode, link, temperature

`take` needs ffprobe (Homebrew ffmpeg) and reads the unified log, which keeps
Ultracam's notice lines for a few days. The capture log names a signal
dropout ("Signal back on … after a dropout"); a gap without one is a device
skip. Read-only: neither command opens a capture input.
"""
import argparse
import datetime as dt
import json
import shutil
import subprocess
import sys
import re
import tempfile
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


def movie_gaps(movie):
    """(take seconds, missing frames) per gap, the frame duration and the start time."""
    if not shutil.which("ffprobe"):
        sys.exit("ffprobe is required: brew install ffmpeg")
    info = json.loads(run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=time_base,r_frame_rate,nb_frames:format_tags=creation_time", "-of", "json", str(movie)]))
    stream = info["streams"][0]
    base_num, base_den = (int(x) for x in stream["time_base"].split("/"))
    rate_num, rate_den = (int(x) for x in stream["r_frame_rate"].split("/"))
    frame = base_den * rate_den / (base_num * rate_num)  # ticks per frame
    created = info.get("format", {}).get("tags", {}).get("creation_time")
    pts = sorted(int(line) for line in run(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "packet=pts", "-of", "csv=p=0", str(movie)]).split() if line.strip().lstrip("-").isdigit())
    gaps = []
    for a, b in zip(pts, pts[1:]):
        missing = round((b - a) / frame) - 1
        if missing > 0:
            gaps.append(((a - pts[0]) * base_num / base_den, missing))
    start = dt.datetime.fromisoformat(created.replace("Z", "+00:00")).astimezone() if created else None
    return gaps, len(pts), start, rate_num / rate_den


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


def take(args):
    movie = Path(args.movie).expanduser()
    gaps, frames, start, fps = movie_gaps(movie)
    missing = sum(m for _, m in gaps)
    print(f"{movie.name}: {frames} frames at {fps:.3f} fps, {missing} missing in {len(gaps)} gaps")
    if not gaps:
        return
    if start is None:
        print("No creation time in the movie, so its gaps can't be matched to the log.")
        for at, m in gaps:
            print(f"  {at:10.3f} s  {m} frame{'s' if m != 1 else ''}")
        return
    end = start + dt.timedelta(seconds=gaps[-1][0] + 60)
    lines = log_lines(start - dt.timedelta(seconds=60), end)
    summaries = [text for _, _, text in lines if movie.name in text]
    # Builds before dropout logging can't tell a dropout from a device skip.
    tells = any("signalDropouts=" in text for _, category, text in lines if category == "capture")
    dropouts = 0
    for at, m in gaps:
        wall = start + dt.timedelta(seconds=at)
        near = [(w, c, t) for w, c, t in lines
                if abs((w - wall).total_seconds()) <= WINDOW and not t.startswith("Live ") and c != "lut"]
        dropout = any("after a dropout" in t or "No video from" in t for _, _, t in near)
        dropouts += dropout
        kind = "signal dropout" if dropout else ("device skip" if tells else "unknown: this build doesn't log dropouts")
        print(f"\n{at:10.3f} s  {wall:%H:%M:%S.%f}"[:-3] + f"  {m} frame{'s' if m != 1 else ''}  [{kind}]")
        for w, c, t in near[: args.lines]:
            print(f"    {w:%H:%M:%S.%f}"[:-3] + f"  {c:<9} {t[:200]}")
    print(f"\n{dropouts} of {len(gaps)} gaps line up with a logged signal dropout.")
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
    t.add_argument("--lines", type=int, default=6, help="log lines to show per gap")
    t.set_defaults(func=take)
    sub.add_parser("devices", help="UltraStudio status now").set_defaults(func=devices)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
