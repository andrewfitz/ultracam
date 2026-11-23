# UltraCam first-party audit, November 22–23, 2026

Fifty Sol reviewers independently examined the working tree after the previous audit. The review covered UltraCam, its first-party SDK adapters and tools, the local streaming integration, and the tracked and active copies of MonitorKit and Auto Switcher. Existing uncommitted work predates this round.

## Fix inventory

Each numbered entry counts one related group of changes. An entry can include several defects. The same repair in two checkouts counts once. Test runs and fixture changes that prove a production fix are included with that fix.

1. **Director timing.** Fixed interrupted dwell, transcript revisions, eligibility boundaries, future audio samples and clock rewinds. Reduced repeated observation scans.
2. **Director service and realtime API.** Bounded handshake reads, validated attach responses, cleared absent audio, and bounded offline ticks to admitted observations. Preserved half-closed watcher delivery.
3. **OBS and adapter lifecycle.** Fixed manual scene changes racing automated cuts, waiters stranded by a clean close, route argument parsing and stale adapter events after reset.
4. **Swift switcher bridge.** Preserved batch and final-drain order, accounted for accepted events at their effective timestamps and expired stale pending cuts.
5. **Native Blackmagic adapter.** Fixed release statistics on a reused backend and connector restoration after readback failure. Skipped unnecessary no-signal clock queries.
6. **Swift Blackmagic adapter.** Fixed reentrant startup, detected changed signal formats and preserved actionable discovery and frame rejection errors.
7. **Sony disconnect.** Retained handles after failed release for retry and handled overlapping disconnect and shutdown.
8. **Mac camera discovery and capture.** Fixed notification ordering, stale hardware and capability records, and inconsistent device identity checks. Invalid probe requests now fail before requesting access.
9. **Camera extension standby.** Released the correct viewer lease after standby failure, shared the format catalog and removed repeated geometry scans.
10. **Camera stream discovery.** Respected known stream direction and validated topology, handled unreadable names and retained format objects across writes.
11. **GPU and PCM ingest.** Fixed cancellation accounting, bounded zero-duration metadata, accepted valid unpadded terminal rows and validated host clock scales and PCM byte totals.
12. **Device API.** Preserved opaque device IDs and rejected misrouted claims and inactive drivers. Corrected fake driver reentry, cancellation and capability behavior for reusable conformance checks.
13. **Recorder callback lifetime.** Kept the VideoToolbox callback context alive through invalidation and moved abandoned-session cleanup off the callback stack. Preserved the original writer failure during teardown.
14. **Recorder concurrency and statistics.** Ordered startup, stop and metadata delivery, invalidated stale disk probes on resume and repaired latency and overflow accounting.
15. **Recording recovery.** Added bounded alternating checksummed journal slots, exclusive sidecar creation and cleanup that preserves recovery evidence on failure. New builds read legacy journals. Downgraded builds cannot read a journal after its first slot update.
16. **Recording clocks and PCM.** Fixed sign extension for low-aligned 24-bit audio, packet duration rounding, mixed-timescale cadence gaps and track-scale timestamp overflow.
17. **Recording LUT conversion.** Corrected transport and range admission, checked buffer aliasing and bounds, and preserved live GPU views across cache lookups.
18. **UYVA input.** Rejected odd widths on the raw packed-memory path before accessing chroma samples.
19. **Shared media contracts.** Corrected integral-rate timecode, overflowing VFR end times and aspect calculations, retention-duration accounting and nonfinite resource limits.
20. **Program routing and standby.** Advanced monitor generations at source or timeline changes, rearmed error reporting, selected the first enabled feed consistently and closed abandoned standby command buffers.
21. **Program video and AV1.** Rejected contradictory planes and color metadata before encoding or passthrough, and protected scaling crop arithmetic against overflow.
22. **Program audio and pacing.** Rejected partially overlapping PCM and zero-frame clock anchors, and recovered an overdue external pump without replaying stale wakes.
23. **Capture epochs.** Kept clocks, counters, PCM admission and stale delivery failures scoped to their take. Fixed nominal source cadence and retained small declared durations.
24. **App inventory and settings.** Cleared stale reconnect and permission state, preserved saved folder access settings, skipped unchanged registry writes and checked finite GPU utilization.
25. **Recording controls.** Handled Stop during pending Start, preserved results for waiters and corrected preparation-failure alerts. The GUI exposes Starting, allows Stop and suppresses Pause during preparation.
26. **Signal health, telemetry and logs.** Restarted the recovery hold after signal loss, protected archives during log rotation, and fixed meter sign extension, stale-reset races and displayed byte ranges.
27. **Control and vendor settings stores.** Verified plugin, device, endpoint and capability before acting, fixed reconnect and credential cancellation races and refreshed inherited defaults before saving.
28. **Monitor feeds.** Rebound hosts and LUT caches when a source or Program returned, and used delivered picture cadence to determine staleness.
29. **LUT metadata and HLG.** Corrected cancellation and external texture reuse, rejected malformed range and matrix metadata, preserved typed metadata and fixed HLG superblack.
30. **Window and keyboard interaction.** Fixed global hotkey conflict detection, inspector resizing with VoiceOver, and invisible grid elements receiving focus or input.
31. **Settings interaction.** Fixed credential endpoint replacement, typed timing field persistence and accessibility, cancellation of validation on close and recording settings order.
32. **Monitor tools and scopes.** Kept settings reachable on narrow tiles, corrected drag and resize coordinates, added accessible slider adjustment and reset, and reduced repeated meter lookups.
33. **GUI state and recovery.** Fixed permission-pending presentation, Stop visibility, keyboard focus, the streaming camera label and recovery-sheet scrolling and accessible names.
34. **Operator alerts.** Identified Program loss by stable ID, corrected permission prompts during outages and starting takes, and fixed paused rollover countdown and clipboard feedback.
35. **MonitorKit engine.** Coalesced repeated engine initialization, aligned primaries inference between warm-up and rendering, validated Metal targets and bounded uniform allocation.
36. **MonitorKit texture and focus handling.** Corrected chroma-only cache lookup, focus parameter tracking, and raw plane and Metal device or buffer preflight.
37. **MonitorKit color math.** Fixed chroma phase at extreme dimensions and clamped authored overlays. Ported effective log range and depth handling and nonfinite ARRI rejection to the tracked copy.
38. **MonitorKit audio.** Removed reader spinning behind a paused snapshot publisher, guarded empty input and stride, fixed extreme meter references, and made peak timing independent of packet boundaries.
39. **MonitorKit scopes.** Fixed GPU resource and retry lifetimes across resize, pause and encoder changes, graticule blending and nonfinite samples.
40. **MonitorKit views.** Fixed command completion and error handling, drawable and SwiftUI identity changes, and premature backing release on view teardown. The tracked scene view now wraps its native representable.
41. **RTMP publish timing.** Propagated the profile’s audio setting to the publish epoch. A video-only synthetic packet previously starting at 168 ms now starts at the expected 125 ms.
42. **Build and publication.** Hardened project generation and output paths, serialized shared DerivedData publication, and preserved the last validated bundle and unrelated dSYMs on failures.
43. **SDK packaging checks.** Fixed archive validation and extraction consistency, version stamp and inventory checks, parallel query files and executable dependency-root checks in first-party scripts.
44. **Capture diagnostics.** Corrected gap attribution, detection of swapped or duplicated stereo, reconnect and decoder evidence, clip times and TLS cleanup.
45. **CLI and smoke utilities.** Rejected invalid arguments before encoding, checked active recovery journals and fixed split pipe reads and verifier owner-exit handling.
46. **GUI tour and self-test.** Fixed alert versus menu detection, partial screenshot retries, child termination, timeout arithmetic and validation of self-test reports.
47. **UI verification scripts.** Propagated failed cache hashes and Rust build errors, isolated overlapping typechecks and corrected render fixture lifetime.
48. **Test discovery.** Handled raw strings, interpolation and nested helpers in Swift discovery. MonitorKit retries now require the requested cases to actually run and pass.
49. **Standalone tools.** Fixed partial source discovery, early validation of monitor and stream smoke arguments, caller-relative link resolution and stale synthetic-stream deadlines.

50. **Encoder frame admission and drops.** Rejected repeated timestamps on the legacy path and accounted for synchronous and callback drop flags once per submitted frame. A dropped frame now fails the take and preserves the initiating error.

A separate cross-module review traced stale PCM and frame failures across capture and recorder boundaries. Its repair is counted in entry 23 and includes a dedicated fake-writer regression.

## HEVC incident and validation boundary

The November 22 22:24 host panic reports an invalid DART write in the Apple video encoder path. The report does not identify an UltraCam source line or establish the codec or initiating process. Recorder teardown improvements address a source-level lifetime issue. Physical HEVC stability remains unverified. This round used injected writers, software codecs, archived media, Metal rendering and isolated UI fixtures for runtime evidence.

## Package-level evidence

| Check | Result |
| --- | --- |
| MonitorKit UI, tracked / active | 217 / 221 executed, zero failures, four opt-in on-screen skips in each |
| MonitorKit Core CPU, tracked / active | 197 / 211 executed, zero failures, two opt-in skips in each |
| MonitorKitAudio, tracked release / active debug | 146 / 153 executed, zero failures, one opt-in skip in each |
| MonitorKit engine and pipeline regressions | 21 passed in each checkout |
| Recording journal and output policy | 57 synthetic filesystem and estimator checks passed |
| RTMP publish epoch | 15 package cases and one app regression passed |
| Camera extension and stream routing | 45 focused fixture checks passed |
| Program standby | All 216 Metal output format and cadence cases passed |

A synthetic PCM replay measured −1.515 dB for the same signal in 1-, 37- and 256-frame packets after the repair. Before the change, the readings ranged from −1.515 to 0 dB. The tracked release build’s 16-channel meter benchmark measured 0.36% of one core at 48 kHz. These are local results, and package tests across the two checkouts overlap.

Hosted CI fetches MonitorKit separately. The active sibling contains worktree API changes needed by the app that are absent from its checked-in main revision. The three working trees need to be released together for a clean hosted build.

## Combined verification

| Entry point | Result |
| --- | --- |
| Debug app and camera-extension build | Passed bundle validation and published the local Debug app |
| Optimized app test build with strict concurrency and warnings as errors | Passed |
| Selected app integration suites | 894 tests across 62 suites, zero failures |
| Strict UI performance verifier | 305 passed, zero failed across two and four cameras with live and fixed meters |
| App self-test | 39 passed, zero failed, including light and dark windows, menus, Settings and Diagnostics |
| Python build, diagnostic, vendor, bundle, boundary, CI and CPU pixel contracts | 242 passed across seven groups |
| Auto Switcher release tests | 58 passed in the active sibling and 58 passed in the tracked package |
| Canonical project generation, CPU pixel access classification, vendor boundary checks, and whitespace checks in all three trees | Passed |

The integrated Metal benchmark on this Mac measured a median 0.204 ms for the 4K v210 to 1080p picture path and 0.469 ms with focus, zebra and guides enabled. These are post-change measurements. The change in end-to-end throughput was not benchmarked against the previous revision.

[App integration log](/Volumes/8TB/cinesomatic-build/ultracam-sol-audit/selected-tests.log) · [UI performance log](/Volumes/8TB/cinesomatic-build/ultracam-sol-audit/ui-perf-final.log) · [App self-test](/Volumes/8TB/cinesomatic-build/ultracam-sol-audit/selftest-settled.log)
