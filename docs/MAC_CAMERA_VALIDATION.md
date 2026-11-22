# Mac Camera qualification

Evidence applies to the source and consumer contracts exercised by each test. Hardware qualification is per camera, macOS version, capture mode, microphone and consumer.

## Local hardware inventory

Ran the probe on Mac Studio with macOS 27.0.1 (26A434). AVFoundation reported camera authorization as authorized. The probe opened no session during inventory.

| Device | Inventory result |
| --- | --- |
| OBS Virtual Camera | AVFoundation and CoreMediaIO returned the same UID. The advertised mode was 1920×1080 BGRA at 60 fps. |
| Blackmagic UltraStudio Mini Recorder 12G | The Blackmagic AVFoundation device and CoreMediaIO returned the same UID. It advertised SD, HD, UHD and DCI modes. No session was opened to avoid interfering with the DeckLink input. |
| Ultracam legacy, Program and per-feed outputs | No Ultracam output was present in CoreMediaIO or AVFoundation. The installed-output UID comparison remains open. |
| Built-in FaceTime, USB webcam, Continuity Camera and Desk View | No matching device was available. Port identity, idle wake behavior, first-use authorization and physical sample delivery remain open. |

The standalone probe opened OBS Virtual Camera at 1920×1080 BGRA with both durations set to 1/60, held the device lock over startup, and read back the selected format and duration. All eight samples contained 1920×1080 BGRA IOSurface-backed buffers. The listed color attachments were absent. Delivered durations varied from 6.26 to 26.70 ms, with a 1.748 s PTS gap. The short, idle OBS run during concurrent builds averaged 3.83 fps. This verifies sample delivery for the installed virtual source. Stable 60 fps delivery remains unverified.

The hardware smoke opened the same OBS device through the Mac Camera plugin using a saved 1920×1080 BGRA, 60 fps selection with microphone Off. Both cycles delivered ten ordered video frames and native IOSurface backing on the first frame. The first cycle stayed on its fixed declaration. The second moved to a variable-rate declaration. The selected mode read back in Hardware settings, no device drops were reported, and stop released the device claim without further callbacks.

| OBS microphone selection | Early shipping-source smoke result |
| --- | --- |
| ZoomAudioDevice | Both cycles delivered independent stereo Float32 PCM at 48 kHz and stopped cleanly. The cycles delivered 45 and 11 packets, totaling 22,576 and 5,632 sample frames. First video PTS was zero in both cycles while first PCM PTS was about 176,873 s. This exposed a startup clock mismatch. |
| Universal Audio Thunderbolt | One attempt refused the session-to-host clock mapping after four video frames. An instrumented retry delivered seven 48 kHz, eight-channel Float32 packets totaling 3,584 sample frames in the first cycle. The second cycle encountered the clock mapping refusal again. |

Raw AVFoundation traces identified a zero-PTS video sample during startup on both microphone pairings. The next video and PCM samples were close to the callback's host time when mapped through the session clock. Both pairs remain unqualified for synchronized recording.

The follow-up after the timestamp fix passed both start/stop cycles for each configuration. Each cycle kept one epoch and reported zero confirmed device drops.

| Microphone | Video frames | PCM packets | First mapped sample ages at callback |
| --- | --- | --- | --- |
| Off | 9 and 10 | None | Video 31.3 and 4.3 ms |
| ZoomAudioDevice | 10 and 11 | 19 and 20, stereo Float32 at 48 kHz | Video 138.0 and 22.0 ms. PCM 74.2 and 53.1 ms. |
| Universal Audio Thunderbolt | 8 and 9 | 17 and 17, eight-channel Float32 at 48 kHz | Video 55.1 and 1.0 ms. PCM 50.0 and 20.2 ms. |

The mapped sample ages measure callback timing. Synchronized recording qualification uses visible and audible cues in the saved movie.

A longer OBS and Universal Audio run used two 20-second cycles. The first delivered 1,142 video frames and 1,883 PCM packets in one fixed-rate epoch with four clock mapping updates. The second delivered 444 video frames and 1,902 PCM packets across four epochs and seven mapping updates. It changed to variable cadence and widened its bounds twice. The Hardware status reported that delivery differed from the requested 60 fps. Video and PCM PTS advanced within each epoch. Neither cycle reported a confirmed device drop or delivered a callback after stop.

After the cadence change to require sustained timing evidence, the first 20-second cycle delivered 1,172 video frames and 1,883 PCM packets in one fixed-rate epoch. The second delivered 545 video frames and 1,876 PCM packets across two epochs. It made one variable-rate transition on sustained 8.35 ms samples and did not widen its bounds again. Both cycles had five clock mapping updates and again reported zero confirmed device drops and no callbacks after stop.

An off-main-thread repeat passed both 20-second cycles. It delivered 1,147 and 475 video frames, 1,888 and 1,878 PCM packets, and five clock mapping updates in each cycle. The first cycle stayed fixed. The second transitioned once to variable cadence at 8.37 ms. Both stopped without further callbacks and reported zero confirmed device drops.

## Repeat the hardware checks

Run inventory from a local login session. It lists AVFoundation devices, formats and exact duration ranges alongside the CoreMediaIO UIDs. To test first-use discovery, run inventory before granting Camera access and rerun with --request-access for the post-grant inventory. Compare the listed UID across reconnects and USB ports. Observe the phone during inventory to check for wake or camera activation.

```sh
scripts/mac-camera-probe.sh
scripts/mac-camera-probe.sh --capture "$camera_uid" "$avfoundation_format_index" "$frame_duration" 120 native
scripts/mac-camera-probe.sh --expect-feed "$enabled_nondefault_feed_id"
scripts/mac-camera-hardware-smoke.sh --formats "$camera_uid"
scripts/mac-camera-hardware-smoke.sh --capture "$camera_uid" "$plugin_format_id" "$exact_fps"
```

The capability probe opens the explicitly selected non-Ultracam device. Use its AVFoundation format index and an exact frame duration, such as 1/30 for 30 fps. Repeat in normal and low light. Compare requested and active modes after startup, then inspect each sample's media subtype, pixel type, dimensions, duration, PTS spacing, IOSurface backing and color attachments. The last argument can request a fallback FourCC, such as 420v, for a separate conversion run. The output UID check requires the legacy feed, Program and a named non-default feed to be published and visible in both APIs.

The hardware smoke compiles the shipping Mac Camera vendor sources and exercises two capture/stop cycles using an explicit device UID and a saved format/rate pair. Its format list uses the plugin's deduplicated catalog, with stable format IDs, exact FPS intervals and presets. Use an ID from that list and an FPS such as 60/1 or 30000/1001 within an advertised interval. The smoke checks declarations, frame delivery, settings readback and callback quiescence after stop. The microphone defaults to Off. Use --audio-inputs to list available microphone UIDs, then pass the chosen UID after the FPS to verify independent PCM format, timing and sample counts. First-sample host-clock checks catch large timebase errors. Set ULTRACAM_MAC_CAMERA_SMOKE_SECONDS to sample each cycle for longer and observe periodic clock mapping updates.

For synchronized recording, record a visible and audible cue at the start and approximately ten minutes into a fixed-rate take. Measure the video and audio cue timestamps at both points and evaluate them with [mac-camera-sync-check.py](../scripts/mac-camera-sync-check.py). Report initial offset and accumulated drift in milliseconds. Keep these measurements with the camera and microphone identities, selected and delivered formats, mode and consumer results.

## Synthetic route coverage

The typed host fixture in SourceFormatRouteChecks submits 1280×720 and 1920×1080 at exactly 30 fps with 420v, 420f and 2vuy, crossed with Float32 mono PCM at 44.1 and 48 kHz. It checks source identity and timing at recording admission, independent PCM admission, the monitor source handoff, the owned live bypass preview and the local extension catalog decision. At these sizes and centered Rec.709, 420v has a published native contract. 420f and 2vuy require an Effects output color format for this route.

The focused Metal checks verified pixel-exact, independently owned bypass copies for all six size and FourCC combinations. They also verified the live GPU refusal for ordinary buffers without IOSurface backing. The Fit checks verified a centered 640×480 picture on a 1280×720 canvas in both feed and Program output, expanding to 960×720 with upscaling enabled.

The offscreen Mac Camera GUI fixture passed 37 checks. It verified the Hardware access and navigation controls, saved per-device modes and microphones after relaunch, and Sync isolation. It verified a saved 1080p60 source take while live Effects delivered 720p30 4:2:2, then verified pixel and color fidelity after restoring 420v bypass.

The host matrix ends at the typed monitor handoff, recording admission callbacks and local extension catalog. Dedicated MonitorKit scopes tests cover scope rendering, and focused Program tests cover normalization and Fit. The GUI fixture verifies a source movie at 1080p60. Full matrix evidence through scopes, Program, a network stream, and a finalized recording for every input combination remains open.

## Callback performance baseline

The initial optimized synthetic callback fixture on an M4 Max measured median process CPU costs of 20.6 µs for steady 1080p30 video, 67.0 µs when alternating 1080p and 720p formats, and 26.6–27.7 µs for 10 ms Float32 PCM packets. The retention fixture verified a six-buffer maximum, recovery after draining and no delivery after stop. Concurrent builds made wall-clock timings unsuitable for setting latency budgets. The fixture covers software callbacks. Record live hardware and end-to-end latency separately.

## Remaining hardware checks

Installed virtual-camera clients, physical recording sync, replug and sleep behavior, low-light cadence and Continuity interruptions require local hardware runs.
