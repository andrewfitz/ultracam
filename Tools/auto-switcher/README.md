# Ultracam Auto Switcher

This is an independent Rust subsystem for realtime and offline camera
direction. It is intentionally transport-neutral: applications can feed it
JSONL events, raw PCM16LE audio, WAV audio, or audio extracted from a media
file, then consume JSONL cut instructions.

The package owns editorial state only. A host application remains responsible
for camera frames, Program output, frame-boundary application, and sending
acknowledgements.

The default automatic shot minimum is 10 seconds between camera jumps. Hosts
may use shorter values only for controlled test or replay configurations.

## Build

The repository uses Rust through `rustup`:

```sh
cd Tools/auto-switcher
rustup run stable cargo test
rustup run stable cargo build --release
```

If the Rust toolchain binaries are not on `PATH`, prefix those commands with
`RUSTC="$(rustup which rustc)" RUSTDOC="$(rustup which rustdoc)"`.

## Realtime JSONL

The JSONL protocol accepts `StreamEvent` objects on stdin and emits
`SwitcherOutput` objects on stdout. It also writes a complete replay timeline
to a UTC-datetime filename such as `auto-switcher-session-20261015-190102-123.json`
by default; use `--output` to choose the path. Existing explicit output files
are never overwritten.

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
Transcript or higher-quality prosody adapters can send additional JSONL events
on the event protocol.

## Offline analysis

Analyze a JSONL event recording:

```sh
rustup run stable cargo run -- offline \
  --events session.jsonl --output analysis.json
```

Analyze a mono 16-bit PCM WAV or a media file with an audio stream:

```sh
rustup run stable cargo run -- offline --audio interview.wav
rustup run stable cargo run -- offline --audio interview.mov \
  --transcript transcript.jsonl --video-cues video-observations.jsonl
```

Non-WAV media uses the installed `ffmpeg` command to decode mono PCM. Video
observations can be supplied as JSONL `video` events or with `--video-cues`.
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

Responses are emitted as `llmAdvisory` records. They are advisory only; the
heuristic director remains authoritative until a later integration adds an
explicit policy for accepting an LLM proposal. This prevents a slow or
unavailable model from blocking realtime audio processing.

The request/response boundary is represented by `DecisionContext`,
`LlmProposal`, and `DelayedLlmAdvisor`. A future vision model can add video
features to the same context without changing the realtime director API.

The protocol schemas are in `schemas/` and can be printed with:

```sh
rustup run stable cargo run -- schema all
```
