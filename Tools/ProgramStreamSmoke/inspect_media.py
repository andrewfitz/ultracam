"""Decode the smoke fixture and verify its picture and tone at the receiver."""
from array import array
from itertools import groupby
import json
import math
import subprocess
from statistics import median


def output(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE, timeout=60)


def probe(path, *args):
    return json.loads(output("ffprobe", "-v", "error", "-of", "json", *args, str(path)))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def verify_recording(path, *, with_audio, require_black=True, check_tone_channels=False, flash_threshold=195,
                     worker_gaps=False, pressure=False, audio_continuity=False, media_loss=False, expected_codec="h264",
                     expected_width=1920, expected_height=1080, expected_fps=30, expected_pix_fmt="yuv420p",
                     expected_color=None, expected_profile=None, target_mbps=None, measure_throughput=False,
                     moving_bars=False, startup_epoch=False):
    streams = probe(path, "-show_streams")["streams"]
    video_tracks = [stream for stream in streams if stream["codec_type"] == "video"]
    require(len(video_tracks) == 1, f"Expected exactly one video track in {path}")
    video = video_tracks[0]
    require((video["codec_name"], video["width"], video["height"]) == (expected_codec, expected_width, expected_height),
            f"Expected {expected_codec} {expected_width}×{expected_height}, got {video} in {path}")
    require(video["pix_fmt"] == expected_pix_fmt, f"Expected {expected_pix_fmt}, got {video['pix_fmt']} in {path}")
    if expected_profile:
        require(video.get("profile") == expected_profile, f"Unexpected codec profile {video.get('profile')} in {path}")
    if expected_color is None:
        expected_color = {"color_range": "tv", "color_space": "bt709", "color_transfer": "bt709",
                          "color_primaries": "bt709"}
    actual_color = {key: video.get(key) for key in expected_color}
    require(actual_color == expected_color, f"Incorrect {expected_codec} color signaling {actual_color} in {path}")
    period = 1 / expected_fps
    frames = probe(path, "-select_streams", "v:0", "-show_packets",
                   "-show_entries", "packet=pts_time,dts_time,flags,size")["packets"]
    times = [float(f["pts_time"]) for f in frames]
    minimum_frames = 12 if measure_throughput else 60
    require(len(times) > minimum_frames, f"Insufficient video ({len(times)} frames) in {path}")
    require("K" in frames[0]["flags"], f"First decodable picture is not a keyframe in {path}")
    require(all(a < b for a, b in zip(times, times[1:])), f"Regressing video time in {path}")
    keys = [index for index, frame in enumerate(frames) if "K" in frame["flags"]]
    gaps = [(a, b) for a, b in zip(times, times[1:]) if b - a > .35]
    if worker_gaps:
        durations = [b - a for a, b in gaps]
        require(len(gaps) == 2 and abs(durations[0] - .7) < .10 and abs(durations[1] - 5) < .1,
                f"Expected measured gaps of 0.7s and 5s; saw {durations} in {path}")
    if pressure:
        require(len(gaps) == 1 and .35 < gaps[0][1] - gaps[0][0] < 1.2,
                f"Expected a single bounded pressure gap, saw {gaps} in {path}")
    if not (measure_throughput or worker_gaps or pressure):
        require(not gaps, f"Interrupted video delivery {gaps} in {path}")
    # The GOP interval applies while the source delivers frames. A 5s worker
    # pause deliberately has no packets. Remove only the measured pause time.
    def active_duration(a, b):
        return b - a - sum(end - start - period for start, end in gaps
                           if (worker_gaps or pressure) and a <= start and end <= b)
    key_limit = math.ceil(2 / period) * period + .001
    for start, next_key in zip(keys, keys[1:] + [len(times)]):
        # A dropped input can leave no picture at the deadline. The first new
        # picture must then be a keyframe. An intervening interframe still fails.
        require(active_duration(times[start], times[next_key - 1]) <= key_limit,
                f"Interframe arrived after the two-second keyframe deadline in {path}")
    cadence = median(b - a for a, b in zip(times, times[1:]))
    require(measure_throughput or abs(cadence - period) < .002, f"Unexpected video cadence {cadence} in {path}")
    span = times[-1] - times[0]
    metrics = {
        "codec": video["codec_name"], "profile": video.get("profile"), "pixel_format": video["pix_fmt"],
        "resolution": [video["width"], video["height"]], "color": actual_color,
        "requested_fps": round(expected_fps, 6), "delivered_fps": round((len(times) - 1) / span, 3),
        "delivered_percent": round(100 * (len(times) - 1) / span / expected_fps, 2),
        "payload_mbps": round(sum(int(f["size"]) for f in frames) * 8 / (span + period) / 1e6, 3),
        "received_video_seconds": round(span + period, 3),
        "maximum_video_interval_ms": round(max(b - a for a, b in zip(times, times[1:])) * 1000, 1),
    }
    if len(keys) > 1:
        metrics["maximum_keyframe_interval_ms"] = round(max(times[b] - times[a] for a, b in zip(keys, keys[1:])) * 1000, 1)
    composition_offsets = [pts - float(frame["dts_time"]) for pts, frame in zip(times, frames) if "dts_time" in frame]
    if composition_offsets:
        metrics["max_abs_pts_dts_offset_ms"] = round(max(map(abs, composition_offsets)) * 1000, 3)
    slots = [round((t - times[0]) / period) for t in times]
    if target_mbps is not None:
        # Millisecond FLV timestamps differentiate exact and fractional rates over
        # multiple seconds, even when the encoder skips individual input frames.
        error = max(abs((t - times[0]) - slot * period) for t, slot in zip(times, slots))
        require(error < .0021, f"PTS drifted {error:.4f}s from the {expected_fps} fps grid in {path}")
        require(all(a < b for a, b in zip(slots, slots[1:])), f"Multiple video packets in one frame slot in {path}")
        metrics.update(target_mbps=target_mbps, maximum_grid_error_ms=round(error * 1000, 2),
                       skipped_receiver_slots=slots[-1] + 1 - len(slots))

    columns = 7 if moving_bars else 1
    decoded = output("ffmpeg", "-v", "error", "-xerror", "-threads", "4", "-i", str(path), "-map", "0:v",
                     "-vf", f"scale={columns}:1:flags=area,format=gray", "-fps_mode", "passthrough",
                     "-f", "rawvideo", "-")
    require(len(decoded) == columns * len(times), f"Could not match timestamps to decoded pictures in {path}")
    pictures = [decoded[i:i + columns] for i in range(0, len(decoded), columns)]
    pixels = [sum(picture) / columns for picture in pictures]
    flashes = [times[i] for i in range(1, len(times)) if pixels[i] > flash_threshold >= pixels[i - 1]]
    require(flashes, f"White flash never arrived in {path}")
    require(any(45 < value < 175 for value in pixels), f"Source gray never arrived in {path}")
    if require_black:
        require(min(pixels) < 15, f"Timed black picture never arrived in {path}")
        for label, is_black in (("black", True), ("source", False)):
            intervals = [times[i] - times[i - 1] for i in range(1, len(times))
                         if (pixels[i] < 15) == is_black and (pixels[i - 1] < 15) == is_black]
            require(intervals and (measure_throughput or abs(median(intervals) - period) < .002),
                    f"Unexpected {label} frame pacing in {path}")
            metrics[f"{label}_median_interval_ms"] = round(median(intervals) * 1000, 1)
    if moving_bars:
        phase = None
        previous = None
        transitions = longest = 0
        for slot, picture, luma in zip(slots, pictures, pixels):
            if not 45 < luma < 175:
                previous = None
                transitions = 0
                continue
            bar = picture.index(max(picture))
            require(bar < 6 and picture[bar] - sorted(picture)[-2] >= 30,
                    f"Missing spatial motion marker in slot {slot} in {path}")
            if phase is None:
                phase = (bar - slot) % 6
            require((bar - slot) % 6 == phase, f"Wrong motion marker in slot {slot} in {path}")
            transitions = transitions + 1 if previous == slot - 1 else 0
            longest = max(longest, transitions)
            previous = slot
        require(longest >= 12, f"Only {longest} consecutive decoded motion transitions in {path}")
        metrics["consecutive_motion_transitions"] = longest
    audio = [s for s in streams if s["codec_type"] == "audio"]
    if not with_audio:
        require(not audio, f"Video Only published an audio track in {path}")
        return {"frames": len(times), "flashes": len(flashes), **metrics}
    require(len(audio) == 1, f"Expected exactly one audio track in {path}")
    track = audio[0]
    require((track["codec_name"], track["profile"], track["channels"], track["sample_rate"]) == ("aac", "LC", 2, "48000"),
            f"Unexpected audio format in {path}")
    packets = probe(path, "-select_streams", "a:0", "-show_packets",
                    "-show_entries", "packet=pts_time,dts_time")["packets"]
    pts = [float(p["pts_time"]) for p in packets]
    require(pts, f"No decoded audio packets in {path}")
    require(all(a < b for a, b in zip(pts, pts[1:])), f"Regressing audio time in {path}")
    if startup_epoch:
        # The fixture withholds the first six video frames on every connection while
        # audio advances against the common epoch. Independent track zeroes erase this gap.
        require(len(composition_offsets) == len(frames) and max(map(abs, composition_offsets)) <= .001,
                f"The low-latency fixture has a video composition offset in {path}")
        startup_delay = float(frames[0]["dts_time"]) - float(packets[0]["dts_time"])
        require(.17 <= startup_delay <= .235, f"Expected an audio lead of 200 ms, got {startup_delay:.3f}s in {path}")
        metrics["first_audio_lead_ms"] = round(startup_delay * 1000, 1)
    # Preserve transport gaps as silence and measure the resulting waveform in 5 ms bins.
    samples = array("f")
    samples.frombytes(output("ffmpeg", "-v", "error", "-xerror", "-copyts", "-i", str(path), "-map", "0:a",
                             "-af", "aresample=async=1:first_pts=0", "-f", "f32le", "-"))
    if media_loss:
        black_windows = []
        for is_black, pictures_in_run in groupby(zip(times, pixels), lambda picture: picture[1] < 15):
            if is_black:
                black_times = [pts for pts, _ in pictures_in_run]
                if black_times[-1] - black_times[0] >= 1 and all(b - a < period + .002 for a, b in zip(black_times, black_times[1:])):
                    black_windows.append((black_times[0], black_times[-1]))
        require(len(black_windows) == 1, f"Expected continuous timed black during source loss in {path}")
        lost_start, lost_end = black_windows[0]
        quiet = samples[round((lost_start + .15) * 48_000) * 2:round((lost_end - .15) * 48_000) * 2]
        require(quiet and max(map(abs, quiet)) < .05, f"Missing timed stereo silence during source loss in {path}")
        require(any(flash > lost_end + .05 for flash in flashes), f"Missing recovered source flash in {path}")
        metrics["timed_black_and_silence_seconds"] = round(lost_end - lost_start, 3)
    hop = 240
    tones = []
    was_on = False
    for i in range(0, len(samples) - hop * 2 + 1, hop * 2):
        left = samples[i:i + hop * 2:2]
        right = samples[i + 1:i + hop * 2:2]
        left_peak = max(abs(x) for x in left)
        on = left_peak > .12
        if on:
            # The quieter reference channel follows the left during AAC attack and decay.
            minimum_right = min(.07, left_peak * .25)
            require(max(abs(x) for x in right) > minimum_right, f"Right channel missing in {path}")
        if on and not was_on:
            tones.append(i / (2 * 48000))
        was_on = on
    require(tones, f"PCM tone never arrived in {path}")
    # Ignore a partial burst at the boundaries when the receiver drops the connection.
    complete_flashes = [flash for flash in flashes if times[0] + .15 < flash < times[-1] - .15]
    offsets = []
    unmatched_tones = tones.copy()
    for flash in complete_flashes:
        candidates = [tone for tone in unmatched_tones if abs(tone - flash) < .4]
        if candidates:
            tone = min(candidates, key=lambda t: abs(t - flash))
            offsets.append(tone - flash)
            unmatched_tones.remove(tone)
    require(offsets, f"No complete flash/tone pair arrived in {path}")
    if worker_gaps or pressure:
        require(sum(flash > gaps[-1][1] + .05 for flash in flashes) >= 2,
                f"Fewer than two decoded flash markers after the final pause in {path}")
    worst = max(abs(d) for d in offsets)
    all_matched = len(offsets) == len(complete_flashes)
    if target_mbps is not None:
        missing_pictures = sum(times[0] + .15 < tone < times[-1] - .15 for tone in unmatched_tones)
        metrics["unmatched_interior_tones"] = missing_pictures
        all_matched = all_matched and missing_pictures == 0 and len(offsets) >= 2
    if measure_throughput:
        metrics["av_within_50ms"] = all_matched and worst <= .0501
    else:
        require(all_matched, f"Incomplete flash/tone marker coverage in {path}")
        require(worst <= .0501, f"A/V flash-tone offset exceeded 50 ms ({offsets}) in {path}")
    continuity = {}
    if audio_continuity:
        # The left flash/tone sync identifies slot zero of the ten-packet right-channel
        # frequency sequence. Verify every interior slot, including those with no video.
        carriers = (600, 1980, 960, 3240, 1380, 2580, 1740, 3660, 2220, 2940)
        first_flash = complete_flashes[0]
        reference = min(tones, key=lambda onset: abs(onset - first_flash))
        start = round(reference * 48_000)
        first_slot = (round((times[0] + .2) * 48_000) - start) // 1600 + 1
        last_slot = (round((times[-1] - .2) * 48_000) - start) // 1600
        require(last_slot - first_slot > 210, f"Insufficient slot continuity coverage in {path}")
        for slot in range(first_slot, last_slot + 1):
            # Exclude AAC transition windows and allow one cycle of estimator quantization.
            begin = (start + slot * 1600 + 450) * 2
            band = samples[begin + 1:begin + 1 + 2 * 750:2]
            peak = max(abs(x) for x in band)
            frequency = sum(a <= 0 < b for a, b in zip(band, band[1:])) * 48_000 / len(band)
            expected = carriers[slot % len(carriers)]
            require(peak > .13 and abs(frequency - expected) <= 78,
                    f"Missing or repeated PCM slot {slot} (expected {expected} Hz, saw {frequency} Hz, peak {peak}) in {path}")
        skipped = [round((b - a) * 30) - 1 for a, b in zip(times, times[1:])]
        counts = {str(n): skipped.count(n) for n in (1, 2, 3)}
        require(min(counts.values()) >= 4, f"Missing recurring skipped video slots {counts} in {path}")
        continuity = {"identified_pcm_slots": last_slot - first_slot + 1, "video_omission_counts": counts}
    if check_tone_channels:
        # Measure the middle of a burst, beyond the AAC attack. Distinct channel
        # frequencies catch a swapped pair or unintended mono downmix.
        complete = [onset for onset in tones if onset > .1 and onset + .2 < times[-1]]
        require(complete, f"No complete stereo tone in {path}")
        start = round((complete[0] + .08) * 48_000)
        for channel, expected in enumerate((900, 1200)):
            wave = samples[start * 2 + channel:(start + 4800) * 2 + channel:2]
            crossings = sum(a <= 0 < b for a, b in zip(wave, wave[1:]))
            require(abs(crossings * 10 - expected) <= 15,
                    f"Wrong frequency on channel {channel + 1} in {path}")
    return {"frames": len(times), **metrics, **continuity, **({"pause_seconds": [round(b - a, 3) for a, b in gaps]}
                                    if worker_gaps or pressure else {}),
            "measured_flashes": len(offsets),
            "unmatched_flashes": len(complete_flashes) - len(offsets),
            "av_offset_ms": [round(d * 1000) for d in offsets]}
