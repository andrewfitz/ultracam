"""Drive an isolated AppModel and decode its published pictures, fixed audio and ISO files."""
from array import array
import json
import math
from pathlib import Path
from contextlib import ExitStack
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ProgramStreamSmoke"))
from inspect_media import output, presentation_times, probe, require, verify_recording
from run_receiver import free_port, receive, stop_process

PROFILES = {
    "legacy": ("h264", 1920, 1080, 30),
    "maccamera-1080": ("h264", 1920, 1080, 30),
    "uhd60-hevc": ("hevc", 3840, 2160, 60),
    "720p2997-av1": ("av1", 1280, 720, 30000 / 1001),
}


def window(path, output_path, start, profile="legacy"):
    args = ["ffmpeg", "-v", "error"]
    if start:
        args += ["-ss", str(start)]
    args += ["-i", str(path), "-t", "7", "-map", "0:v", "-map", "0:a", "-c", "copy", str(output_path)]
    subprocess.run(args, check=True, timeout=40)
    codec, width, height, fps = PROFILES[profile]
    return verify_recording(output_path, with_audio=True, require_black=False, flash_threshold=235,
                            expected_codec=codec, expected_width=width, expected_height=height, expected_fps=fps)


def verify_audio_identity(path):
    pcm = array("f")
    pcm.frombytes(output("ffmpeg", "-v", "error", "-xerror", "-i", str(path), "-map", "0:a",
                         "-f", "f32le", "-"))
    # Each 20 ms window holds exactly 18 cycles of the selected 900 Hz signal or
    # 40 cycles of the cutaway's 2 kHz tone. Compare their spectral power directly.
    def power(block, frequency):
        coefficient = 2 * math.cos(2 * math.pi * frequency / 48_000)
        previous = before_previous = 0.0
        for sample in block:
            current = sample + coefficient * previous - before_previous
            before_previous, previous = previous, current
        return previous**2 + before_previous**2 - coefficient * previous * before_previous

    selected_blocks = 0
    window_frames = 960
    stereo_samples = 2 * window_frames
    # AAC burst edges put a little energy in adjacent frequency bins. A 1.5%
    # full-scale sinusoid yields this power in a 20 ms window.
    floor = (window_frames * .015 / 2) ** 2
    selected_floors = [(window_frames * level / 2) ** 2 for level in (.12, .07)]
    for i in range(0, len(pcm) - stereo_samples + 1, stereo_samples):
        selected_powers = []
        for channel in range(2):
            block = pcm[i + channel:i + stereo_samples:2]
            selected = power(block, 900)
            cutaway = power(block, 2000)
            require(cutaway < max(floor, .05 * selected),
                    f"Cutaway audio leaked into channel {channel + 1} of the fixed embedded track")
            selected_powers.append(selected)
        left, right = selected_powers
        if left > selected_floors[0] and right > selected_floors[1]:
            # The fixture sends about 0.36 on the left and 0.125 on the right.
            # Allow for AAC variation while rejecting swapped or duplicated channels.
            require(2.25 * right <= left <= 25 * right,
                    "Unexpected left/right level balance in the selected stereo pair")
            selected_blocks += 1
    require(selected_blocks > 12, "Selected feed's tone was missing from the stereo pair")
    return selected_blocks


def run(executable, folder, seconds, profile="legacy"):
    codec, width, height, expected_fps = PROFILES[profile]
    port = free_port()
    with ExitStack() as stack:
        first, receiver = receive(stack, folder, port, 1, seconds=11)
        time.sleep(.3)
        log = stack.enter_context((folder / "app.log").open("wb"))
        app = subprocess.Popen([executable, f"rtmps://127.0.0.1:{port}/live", folder, str(seconds), profile],
                               stdout=log, stderr=log)
        stack.callback(stop_process, app)
        deadline = time.monotonic() + seconds + 65
        rss = []
        last_sample = 0.

        def sample_rss():
            nonlocal last_sample
            now = time.monotonic()
            if now - last_sample >= 1:
                last_sample = now
                measured = subprocess.run(["ps", "-o", "rss=", "-p", str(app.pid)], capture_output=True, text=True)
                sample = measured.stdout.strip()
                if sample.isdigit() and int(sample) > 0:
                    rss.append(int(sample))

        while receiver.poll() is None and app.poll() is None and time.monotonic() < deadline:
            sample_rss()
            time.sleep(.25)
        require(app.poll() is None and receiver.poll() == 0, f"First receiver failed. See {folder}/app.log")
        second, receiver = receive(stack, folder, port, 2)
        recordings = [first, second]
        while app.poll() is None and time.monotonic() < deadline:
            if receiver.poll() is not None:
                # An FFmpeg listener accepts one publisher. Keep the endpoint available
                # for subsequent attempts while preserving every connection's recording.
                path, receiver = receive(stack, folder, port, len(recordings) + 1)
                recordings.append(path)
            sample_rss()
            time.sleep(1)
        require(app.poll() == 0, f"App failed. See {folder}/app.log")
        if recordings[-1].exists():
            receiver.wait(timeout=10)
            require(receiver.returncode == 0, "Last receiver failed")
        else:
            recordings.pop()  # Listener opened just after clean Stop; no publisher attached.
    require(len(recordings) >= 2, "No receiver captured media after the planned disconnect")
    durations = [float(probe(path, "-show_format")["format"]["duration"]) for path in recordings]
    media_length = sum(durations[1:])
    interruptions = json.loads((folder / "interruption-seconds.json").read_text())
    require(len(interruptions) == len(recordings) - 1, "Publisher/receiver connection counts disagree")
    results = {"profile": profile, "video": [codec, width, height, expected_fps],
               "connection_seconds": durations, "planned_interruption_seconds": interruptions[0],
               "unplanned_interruption_seconds": interruptions[1:],
               "largest_interruption_seconds": max(interruptions)}
    rates = []
    for part, path in enumerate(recordings, 1):
        packets = probe(path, "-select_streams", "v:0", "-show_packets", "-show_entries", "packet=pts_time").get("packets", [])
        require(len(packets) >= 2, f"Receiver {part} captured fewer than two video packets")
        times = presentation_times(packets, "Program video", path)
        rates.append((len(times) - 1) / (times[-1] - times[0]))
        results[f"connection_{part}_fps"] = round(rates[-1], 3)
        # A 29.97 setting silently rounded to 30 would slip a full ten milliseconds in ten
        # seconds. Compare all packet timestamps to the exact target grid, allowing dropped slots.
        elapsed = [t - times[0] for t in times]
        errors = sorted(abs(t - round(t * expected_fps) / expected_fps) for t in elapsed)
        results[f"connection_{part}_grid_error_p95_ms"] = round(errors[int(.95 * len(errors))] * 1000, 3)
    results["post_reconnect_seconds"] = media_length
    require(rss, "Could not sample the app process RSS")
    results["process_rss_mib"] = {"first": rss[0] // 1024, "last": rss[-1] // 1024, "max": max(rss) // 1024}
    results["iso_recordings"] = json.loads((folder / "iso-results.json").read_text())
    # Preserve transport measurements even when a later picture or audio assertion fails.
    report = folder / "qualification.json"
    report.write_text(json.dumps(results, indent=2))
    for key, path, start in [("first", first, 1), ("reconnected", second, 1),
                             ("final", recordings[-1], max(0, durations[-1] - 8))]:
        results[key] = window(path, folder / f"window-{key}.mkv", start, profile)
    # Inspect the final connection after cut automation has started.
    pictures = output("ffmpeg", "-v", "error", "-xerror", "-threads", "4",
                      "-i", str(folder / "window-final.mkv"), "-map", "0:v",
                      "-vf", "scale=1:1,format=gray", "-fps_mode", "passthrough", "-f", "rawvideo", "-")
    require(any(35 < p < 100 for p in pictures) and any(150 < p < 210 for p in pictures),
            "Decoded cuts did not include both camera pictures")
    if profile == "uhd60-hevc":
        frames = probe(folder / "window-final.mkv", "-threads", "4", "-select_streams", "v:0", "-show_frames",
                       "-show_entries", "frame=best_effort_timestamp_time")["frames"]
        times = [float(frame["best_effort_timestamp_time"]) for frame in frames]
        require(len(times) == len(pictures), "Could not match high-rate markers to their timestamps")
        longest = consecutive = 0
        for i in range(1, len(times)):
            left, right = pictures[i - 1], pictures[i]
            alternating = 140 < min(left, right) < 180 and 185 < max(left, right) < 218
            consecutive = consecutive + 1 if alternating and .014 < times[i] - times[i - 1] < .020 else 0
            longest = max(longest, consecutive)
        results["consecutive_60fps_marker_transitions"] = longest
        require(longest >= 12, f"Decoded UHD motion only alternated for {longest} consecutive 60 fps transitions")
    results["selected_audio_blocks"] = verify_audio_identity(folder / "window-final.mkv")
    originals = list(folder.rglob("*.mov"))
    expected_names = {take["name"] for take in results["iso_recordings"].values()}
    require(len(originals) == 2 and {path.name for path in originals} == expected_names,
            "Expected one baseline and one simultaneous original recording")
    for original in originals:
        streams = probe(original, "-show_streams")["streams"]
        video_tracks = [stream for stream in streams if stream["codec_type"] == "video"]
        audio_tracks = [stream for stream in streams if stream["codec_type"] == "audio"]
        require(len(video_tracks) == len(audio_tracks) == 1, f"Expected one ISO video and one ISO audio track in {original}")
        video, audio = video_tracks[0], audio_tracks[0]
        # The codec resolver selects HEVC Main for the native 8-bit 420v input.
        iso_format = ("hevc", 1920, 1080) if profile == "maccamera-1080" else ("prores", 3840, 2160)
        require((video["codec_name"], video["width"], video["height"]) == iso_format,
                f"ISO capture format changed in {original}")
        if profile == "maccamera-1080":
            require(video["r_frame_rate"] == "30000/1001", f"ISO capture cadence changed in {original}")
        require((audio["sample_rate"], audio["channels"]) == ("48000", 4), f"ISO source audio changed in {original}")
    if seconds >= 1800:
        require(len(rss) >= 900, "Insufficient process RSS samples for the steady-state check")
        early = statistics.median(rss[300:600])
        late = statistics.median(rss[-300:])
        results["steady_state_rss_change_mib"] = round((late - early) / 1024, 1)
    report.write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))
    require(media_length > seconds - 14, "Receiver lost too much of the run")
    require(results.get("steady_state_rss_change_mib", 0) <= 128, "Steady-state process RSS grew over 128 MiB")
    for part, fps in enumerate(rates, 1):
        require(.99 * expected_fps <= fps <= expected_fps + .01, f"Receiver averaged {fps:.3f} fps for connection {part}")
        require(results[f"connection_{part}_grid_error_p95_ms"] <= 2.,
                f"Receiver timestamps drifted from the {expected_fps:.4f} fps grid on connection {part}")


if __name__ == "__main__":
    run(Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else "legacy")
