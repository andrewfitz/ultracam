# Auto Switcher

Auto Switcher runs as a macOS application or a headless Rust executable. One director owns the media clock, pending decision, on-air route and switching profile for each session. Route IDs are opaque strings. A host decides how to apply a cut and acknowledges its decision ID. The same director powers the private UltraCam worker, the broadcast server, the stdin CLI and offline processing.

## Run

This repository builds independently of UltraCam. For an UltraCam development checkout, place the repositories beside one another as `ultracam/` and `auto-switcher/`. From this directory, build the CLI with `cargo build --release --locked`. Build the menu-bar application with `./macos/build.sh`, then open `build/Auto Switcher.app`. The app opens a control panel and adds a menu-bar icon. Choose a profile and clock before starting. The journal folder opens from either the panel or the menu.

```sh
target/release/auto-switcher serve --config profiles/timer.json --clock
target/release/auto-switcher watch
target/release/auto-switcher take B
target/release/auto-switcher export switcher-SESSION-ID.jsonl > cuts.csv
```

Run each client in a separate terminal. The server binds to IPv4 loopback on port 48765 by default. Local processes that can reach the port are trusted controllers. Use one routing host per session. Start with `--clock` for autonomous operation, or omit it when UltraCam or another host supplies ticks. The host clock is in media seconds. All frame and audio producers must use the same origin. The CLI creates a new journal in its working directory or at `--journal PATH`. The menu app stores journals in `~/Library/Application Support/Auto Switcher/Sessions`.

## Switching profiles and plug-ins

Profiles are JSON files. The first two route IDs use the historical field names `anchor_camera_id` and `emphasis_camera_id`; other strategies can add `additional_targets` in routing order. Select a profile in the GUI or pass `--config` when starting a session. The default profile is talking head. The CLI enforces its existing ten-second minimum for that strategy. Other profiles can set their own minimum and cooldown.

| Profile | Decision |
| --- | --- |
| talkingHead | Speech, emphasis, pauses and transcript boundaries with shot duration and source health |
| timer | Rotate through healthy routes in profile order |
| motion | Prefer the recently observed route with more motion |
| eyeContact | Prefer a frontal face score from a vision adapter |
| provider | Compare recent normalized scores from any local or remote provider |
| rules | Evaluate ordered rules. The first healthy target whose conditions all match wins. A match for the on-air target holds the shot. |

Visual scores expire after one media second. Motion, eye contact and provider profiles apply a score threshold and a hysteresis margin over the current route. Rules can combine motion, gaze, provider score, energy, emphasis, laughter, pause length and final question confidence. An audio plug-in can attach numeric tone or emotion scores in `cue.features`. For example, a rule condition can use `{"signal":"audioFeature","name":"tone.pitchHz","minimum":180}`. The PCM decoder supplies a zero-crossing rate. Named emotion scores come from the chosen analyzer. See [the workbench example](profiles/workbench.json) and [profile schema](schemas/profile-v1.schema.json). New analysis or output plug-ins run as client processes and can use any implementation language.

## Wire protocol v1

Send UTF-8 JSON followed by LF over TCP. One request produces one reply. A watch connection receives an atomic state snapshot followed by updates in sequence order. Use a separate connection for commands. A session UUID changes on restart, and sequence numbers start at zero. An input frame can be up to 256 KiB. A slow watcher is disconnected when its bounded queue fills. Reconnect for a fresh snapshot and use the journal for historical updates. A watcher should never apply an old cut after reconnecting.

```jsonl
{"v":1,"op":"state"}
{"v":1,"op":"watch"}
{"v":1,"op":"event","event":{"type":"video","observation":{"camera_id":"Desk","time":15,"motion":0.8}}}
{"v":1,"op":"event","event":{"type":"tick","time":15}}
{"v":1,"op":"take","route":"Desk"}
```

An update includes the input, outputs, post-event status, and pending instruction. A `cut` proposes a route with a UUID, generation, requested media time and expiry. The routing host sends an `acknowledge` event with `decision_id` and optional `applied_at` after application, or `reject` on failure. An independent manual change uses `manualOverride` with its route and media time. A control panel or Stream Deck button that wants the host to *perform* a cut uses `take`. A reset starts a new generation. Native hosts can claim clock and routing control for the life of a connection. Other clients can continue publishing evidence and requesting takes.

The append-only journal contains the initial configuration and each event in order. CSV export lists route changes with seconds and 240000-Hz ticks. The `time_source` column distinguishes host-supplied application time from inferred request time. The `keyDispatched` application label identifies shortcut delivery. Use the host acknowledgement path when the recording needs the actual frame that switched.

Print the [service schema](schemas/service-v1.schema.json) with `auto-switcher schema service`, the [profile schema](schemas/profile-v1.schema.json) with `schema profile`, or all schemas with `schema all`.

## Hosts and signals

- **UltraCam** bundles the Rust worker and starts it over private pipes. In Settings → Switching → Director connection, choose Local server to attach on the next director start. Start Auto Switcher first with Host clock, enable Natural Talking Head in UltraCam and select Anchor and Emphasis. The shared profile chooses the decision strategy. Its first two route IDs map to the selected feeds, and additional IDs map to remaining running feeds in declaration order. Host Hold, manual changes, health, reset, rejection and frame-boundary acknowledgements cross the bridge. UltraCam keeps its recording sidecars and per-camera clock mapping. The fixed interval scheduler also uses the standalone Rust policy through its C SDK.
- **OBS** uses the v5 WebSocket adapter. Enable the OBS WebSocket server, use OBS scene names as route IDs, set `OBS_WEBSOCKET_PASSWORD` when required, and run `python adapters/obs.py`. The adapter synchronizes the initial OBS scene, follows manual changes to configured OBS scenes, sets Program on each proposal and acknowledges successful responses.
- **Global shortcuts** use a JSON map such as `{"A":{"keycode":18,"modifiers":["command","shift"]},"B":{"keycode":19,"modifiers":["command","shift"]}}`. Select it in the menu or use `serve --hotkeys keys.json --clock`. Configure matching shortcuts in the destination app and grant macOS Accessibility access to the posting executable. Keycodes are macOS virtual keycodes. Command, shift, control and option are supported.
- **Stream Deck** can launch `auto-switcher take ROUTE` using a command-running action. The same request is available over TCP for custom button software.
- **Audio** from any capture process can be piped to `auto-switcher feed-pcm --rate 24000` as signed mono PCM16LE. Use `--tick` when this producer owns the clock. Use `--origin` for audio starting partway through a session. The Rust decoder publishes energy, emphasis, pauses and speech transitions.
- **Transcriberrr** accepts the same 24 kHz audio on its native realtime WebSocket. Use a Transcriberrr build with the `serve` subcommand (the sibling source checkout supports it). Start its realtime server and pipe the audio to `python adapters/transcriberrr.py --origin 0`. Set `TRANSCRIBERRR_API_KEY` when required. The adapter converts final item frame ranges, text and speaker into transcript cues. Its adjustable confidence is the editorial boundary weight. The frame origin is the host media time at the first sample.
- **Local vision** ships the MIT-licensed YuNet ONNX model (232589 bytes). Run `python adapters/vision.py --mode eyeContact --camera 0 --route A` per camera. Its landmarks estimate head direction using the eyes and nose. Test this proxy at the camera angles in your setup. Motion mode uses frame differences without loading a model. Vision also accepts JSONL frame references on stdin with fields `path`, `camera_id`, and capture `time`. Keep images local to the producer. The protocol carries scores.
- **External image models** use `vision.py --mode provider --endpoint URL --model MODEL --camera 0 --route A`. Supply a local or cloud OpenAI-compatible multimodal chat-completions endpoint and optional `SWITCHER_MODEL_KEY`. Each request carries one downsampled JPEG and asks for a normalized score. The service stays responsive while inference runs. A separate provider can publish `provider_score` directly.

The Rust core, headless timer, native worker, GUI and hotkey output have no Python dependency. For OBS, Transcriberrr and image adapters, use Python 3.11+ in a virtual environment and install `pip install -r adapters/requirements.txt`. These adapters, examples and model are also included under the app bundle’s Resources directory. The model is distributed under [the YuNet license](models/LICENSE-YuNet). [Upstream model and benchmark](https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet).

## Realtime JSONL

The JSONL protocol accepts `StreamEvent` objects on stdin and emits
`SwitcherOutput` objects on stdout. It also writes a complete replay timeline
to a UTC-datetime filename such as `auto-switcher-session-20261015-190102-123.json`
by default; use `--output` to choose the path. Existing explicit output files
are never overwritten. Use `--output -` to stream instructions without
collecting a replay timeline.

```sh
rustup run stable cargo run -- realtime --input-format jsonl
```

Example input:

```json
{"type":"audio","cue":{"id":1,"time":10.0,"speech_energy":0.95,"pause_duration":0.0,"emphasis":0.95,"laughter":0.0}}
{"type":"transcript","cue":{"segment_id":"s1","revision":1,"start":9.8,"end":10.0,"kind":"sentenceEnd","confidence":0.96,"is_final":true}}
{"type":"tick","time":10.0}
```

For a raw mono 16-bit PCM stream:

```sh
cat microphone.pcm | rustup run stable cargo run -- realtime \
  --input-format pcm16le --sample-rate 16000
```

The PCM adapter emits normalized energy, speech start/stop, and pause cues.
Raw PCM carries no host control events. In this mode the CLI assumes each
emitted cut takes effect at its requested media time and records a matching
`acknowledge` event. Timeline metadata marks these simulated applications with
`cut_application` set to `assumed_at_requested_time`. Use realtime JSONL for
confirmed frame-boundary acknowledgements from a host.
Transcript or higher-quality prosody adapters can send additional JSONL events
on the event protocol.

## Offline analysis

Analyze a JSONL event recording:

```sh
rustup run stable cargo run -- offline \
  --events session.jsonl --output analysis.json
```

Offline analysis sorts observations and ticks between consecutive controls.
Controls retain their arrival position even when they carry application
timestamps. Each reset starts a new segment whose media clock can begin at
zero. Offline analysis assumes cuts take effect at the requested time and
records the corresponding acknowledgements.
As observations arrive in realtime, camera health follows the newest timestamp
for each camera within its session generation.

Analyze a mono 16-bit PCM WAV or a media file with an audio stream:

```sh
rustup run stable cargo run -- offline --audio interview.wav
rustup run stable cargo run -- offline --audio interview.mov \
  --transcript transcript.jsonl --video-cues video-observations.jsonl
```

Non-WAV media uses the installed `ffmpeg` command to decode mono PCM. Offline
analysis reads decoded samples in chunks and keeps the cue events for the
replay timeline. Video observations can be supplied as JSONL `video` events or with `--video-cues`.
Full vision extraction is deliberately an adapter boundary rather than a
dependency of this crate.

Both modes write the v3 session timeline schema with a 240000-tick timebase.
Existing v2 timelines retain their declared timebase when read. It stores the complete ordered
input event ledger, director outputs, proposed/applied/expired cuts, source and
recording artifacts, and exact integer media ticks alongside human-readable
seconds. The same media timebase must be retained by the video recorder so a
later editor can replay each cut against the original files without drift.
The app names source movies with their stable feed ID and UTC datetime, and
uses a UTC datetime plus a numeric collision suffix for the session JSON.

## Delayed Ollama advisory path

The optional Ollama path submits bounded context snapshots to a worker thread
and makes responses eligible only after a media delay. The default delay is
15 seconds:

```sh
rustup run stable cargo run -- realtime --ollama \
  --llm-delay-seconds 15
```

A session reset or backward clock discontinuity clears advisory context and
discards outstanding replies from the previous session.
Responses are emitted as `llmAdvisory` records. They are advisory only; the
heuristic director remains authoritative until a later integration adds an
explicit policy for accepting an LLM proposal. This prevents a slow or
unavailable model from blocking realtime audio processing.

The request/response boundary is represented by `DecisionContext`,
`LlmProposal`, and `DelayedLlmAdvisor`. A future vision model can add video
features to the same context without changing the realtime director API.

The Draft 2020-12 protocol schemas are in `schemas/`. Register the schemas
by their `$id` values when validating documents that reference other schemas.
Print the full set with:

```sh
rustup run stable cargo run -- schema all
```
