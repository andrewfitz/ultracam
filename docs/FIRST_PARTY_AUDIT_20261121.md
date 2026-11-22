# Ultracam first-party code audit

The review covered the macOS app and GUI, camera extension, capture and vendor adapters, shared media contracts, Program output, recording, Rust CLI and C bridge, project generation, bundle validation, developer tools, tests and executable mockups. It used the existing working tree, which already contained substantial changes. The findings below describe work during this audit. A diff against the repository HEAD also includes earlier work.

Local logs, benchmark reproducers and source hashes are in /Volumes/8TB/cinesomatic-build/ultracam-audit-20261121.K6294l. Artifact names below are relative to that directory.

## Fixes

| Area | Changes |
| --- | --- |
| GUI and operator controls | Removed an unused recursive movie-folder scan from recurring refreshes. Drive estimates can use another accessible folder on the same volume. Routine commands avoid building a complete presentation for confirmation. Sync Cameras carries the camera named in the confirmation through to execution. Moving an exclusive input checks both camera controllers before releasing it. Problem details open the corresponding Diagnostics tab. Stopped feeds no longer report stale counters as live. |
| Capture and audio | Fixed ownership of noninterleaved PCM planes, removed unnecessary meter-path allocations, released removed cameras' telemetry, and corrected the lifetime of the hardware status polling task. An active director can continue with its surviving camera. Queued callbacks from a released director no longer act on a new session. |
| Program, LUTs and monitor | Fixed pacing after a fractional missed host deadline, preserved visible cut information across metadata-only deliveries and avoided allocating rejected repeats. Preserved pixel aspect in LUT preconversion, honored source range and P3 tags, retained source storage through GPU completion, and removed redundant per-frame format/cache work. Reject late monitor frames across declaration changes and discard queued scope work for expired signals. |
| Virtual camera | Negotiate the actual Program cadence and validate support before changing installed settings. Fixed the runtime lifetime of queued streaming-client callbacks. Reused format descriptions and reduced repeated CoreMediaIO device UID reads. |
| Recording and recovery | Reused bounded GPU staging for UYVA recording and preserved native chroma declarations on 4:2:0 pass-through. Recheck volume capacity when resuming a paused claim. Release reservations after cancellation failures, detach from the controller that started the take, and recover interrupted partials even when another file occupies the intended final name. |
| Device adapters | DeckLink resets timecode inference across clock jumps, clears stale labels on signal loss and reuses the parsed timecode for media and frame callbacks. Sony avoids redundant property writes and detects disconnection during a native read. |
| Auto-switcher | Realtime stdout can stream without accumulating a replay ledger. Reduced allocation and serialization in PCM and ledger paths. Corrected offline control ordering, advisory recording, schema mismatches and handling of values that overflow the cue representation. File outputs preserve existing files. Swift timeline checkpoints encode new events once, coalesce periodic writes on a serial background queue and back off after write failures. Take boundaries and finalization retain synchronous checkpoints. |
| Build and verification | Validate the Camera Reload helper and its declared executable. Keep canonical bridge generation isolated and avoid reusing full GUI proof for explicitly requested diagnostics. Bound Swift test compilation, preserve the last actual test log during compile-only runs, cover all 16 pipeline switch combinations, and require GPU completion before verifying render results. Fixed vacuous or stale checks in several harnesses. |
| Mockups | Removed duplicate SVG definition IDs and validated freshly captured PNGs before replacing an existing screenshot. |

## CLI performance

Five interleaved release runs per executable and mode on an Apple M4 Max, using 150,000 audio and tick pairs. Manual hold isolated event ingestion and serialization. The baseline was a release binary built on November 20. Other builds were active during the measurement.

| Mode | Median elapsed before / after | Median maximum RSS before / after |
| --- | ---: | ---: |
| Realtime stdout | 1.42 / 0.13 s | 42.28 / 3.19 MiB |
| Realtime ledger | 1.56 / 0.71 s | 143.91 / 42.05 MiB |
| Offline ledger | 1.85 / 0.98 s | 271.02 / 60.50 MiB |

Raw trials and inputs are described in `auto-switcher-benchmark.txt` and `auto-switcher-benchmark.py`. In a separate 6,000-tick Swift timeline run, p95 time spent on the main actor at a checkpoint fell from 199 ms to 0.038 ms. Both resulting documents contained all 6,000 records. Each durable checkpoint still writes the entire JSON snapshot.

## Dependency boundary

The active MonitorKit dependency lives in the sibling checkout at `../MonitorKit`. The current app requires changes in that checkout that are absent from the published revision 5bf8dfe. The README documents the required API surface. Validation on this machine uses the working sibling. The untracked `Packages/MonitorKit` is an inactive, older snapshot. No package, external SDK, or sibling repository was modified as part of the audit.

## Long audio imports

Offline media input now streams mono PCM into the cue decoder. WAV reads respect the data chunk boundaries. FFmpeg output and diagnostics drain concurrently, a failed subprocess is reaped, and a partial analysis is discarded. On 384 MiB of decoded PCM (69.91 minutes at 48 kHz), median CLI peak RSS over three release runs fell from 771.45 to 4.89 MiB for WAV and from 376.36 to 16.28 MiB for FLAC via FFmpeg. Each route emitted the same 8,390 records before and after. The measurement excludes the FFmpeg child process. See `auto-switcher-audio-stream-benchmark.txt` and its companion Python script.

## Additional checks

- Standalone monitor host and app integration completed 36 and 38 checks respectively, with zero failures or skips. Measured scope rates for the 10, 15 and 30 Hz settings were 10.00, 15.43 and 29.76 Hz on the integration workload.
- All 39 Rust tests and Clippy passed. The C static-library harness and mock Ollama HTTP exchange passed. Both Rust replay tests accepted Swift-generated schema-v3 timeline JSON.
- All 44 focused recording output checks passed, along with four interrupted ProRes/HEVC recovery cases and six independently decoded recording-stop outputs.
- All 39 focused DeckLink Swift checks and 17 native DeckLink checks passed. Sony native and control conformance passed using the local SDK.
- The Metal 4 standby check validated all 216 slots on the M4 Max. The monitor integration measured a 0.212 ms median for 4K v210 to 1080p on its fixture.
- The synthetic cadence suite passed all 24 cases. The app timeline suite passed nine cases. Both exercise the fractional-clock corrections.
- 57 mockup pages passed a browser smoke check. All 36 pages using the shared JavaScript passed the post-fix rendering checks.

## Final integrated verification

- All 1,733 registered app tests passed with no skips. Runtime suite discovery and the required app GPU skip check passed. This includes camera negotiation, clock resets and the paced 59.94/29.97 capture checks. Under simultaneous GPU workloads the provisional binary had missed the paced throughput budget. The final run kept the UI performance workload separate.
- The unsigned Release Xcode build and embedded bundle validation passed. The Release app's isolated real-window self-test passed all 39 checks. No product was installed or published. Physical camera capture, meeting-app use of the installed extension and privileged reload were not exercised. The temporary sandbox recording-folder smoke bundle passed signature verification, but its interactive picker was unverified.
- The 187 Python contract tests passed across seven suites. Canonical project generation, vendor boundaries and CPU pixel-access checks passed. The sibling MonitorKit dependency's five suites ran 1,136 tests in total, with 12 skips and zero failures.
- Extension discovery now coalesces requests on a background queue and identifies the published devices by registry UID. A local measurement with no cameras published took 25.79 ms on the main thread before the change. The new cached UI read took 0.03 ms while the scan ran on the worker.
- The strict GUI verifier completed 1,861 checks successfully, failed six, and rendered 317 images. All six failures were in the four-camera live-meter case. The longest inspector-open stall was 845 ms, against a 250 ms budget. The layout settled during the following measurement window. Both two-camera configurations and the four-camera fixed-meter configuration passed. A separate four-camera profile saw main-thread waits inside QuartzCore display callbacks querying the display server. The aggregate thread sample cannot assign each stall to a specific call. Performance thresholds were kept in place.
- The GUI performance fixture now explicitly requests 59.94 fps, measures offered and accepted frames separately, and drives the synthetic inputs from a strict dispatch timer. This eliminated a false failure caused by the previous 29.97 fps fixture output, and distinguished source underdelivery from downstream delays.

Local evidence includes `tests-final.log`, `coverage-final.log`, `contracts-final.log`, `xcode-final.log`, `bundle-final.log`, `app-self-test-final.log` and `verified-source-hashes.json`. The GUI results and 317 renders are under `agent-work/build/ultracam/ui-verify/20261121T065507-70071/`. The input hashes cover the source, tests, build scripts, assets and documentation present during final validation.

The same GUI binary ran again after all other audit workloads finished. It passed 299 of 305 performance checks. All six misses were wall-clock stall budgets, occurring across two-camera fixed-meter and four-camera live/fixed-meter cases. All layout, structural-update and capture-throughput checks passed in this repeat. The longest stall was 436 ms on inspector open. The latency issue remains unresolved. See ui-perf-isolated.log.
