# Blind performance and bug pass — 2026-11-05

This follow-up pass used fresh Sol reviewers across capture, format admission, LUT/GPU processing, MonitorKit, audio, native adapters, and the switcher. It reviewed the current uncommitted changes as well as surrounding first-party code. SDK sources and external libraries were excluded.

The pass found and fixed these concrete issues:

- Auto-switcher startup seeded its manual override from video PTS while later director events used the audio-or-video director clock. Startup now uses `directorClock()` consistently.
- Installed extension catalogs could be reordered or replaced and still return a published index, allowing an active format index to refer to the wrong contract. Admission now requires an unchanged published prefix; a focused regression covers reordered and singleton malformed catalogs.
- Untouched full-range packed formats did not receive an explicit `FullRangeVideo` attachment, so their sample metadata could disagree with the negotiated contract. Passthrough stamping now removes stale range metadata and writes the source range explicitly.
- LUT processing accepted a destination pixel buffer sharing the input IOSurface. The new guard rejects read/write aliasing before GPU submission.
- A stale LUT output-texture cache entry was removed before the GPU idle wait. If the wait timed out, its budget lease could be released while GPU work still referenced the texture. Removal now happens only after the idle wait succeeds.
- MonitorKit freeze preparation could publish plane 0 before plane 1 allocation succeeded, leaving a half-replaced frozen pair after an allocation error. Both planes are now prepared before either is published.
- Blackmagic colorimetry state retained an old signal fallback after an explicit colorspace-change event reported no colorspace. Both auto and fixed paths now clear the stale value.
- A rejected audio packet during a take did not break the next packet's filter history. Rejected format packets now mark a discontinuity before later valid audio is processed.

Validation completed in this pass:

- Unsigned `Ultracam` Debug build passed with the new app, capture, format, LUT, and native changes.
- `UltracamCamera` build passed.
- MonitorKit freeze regression passed: `FreezeTests/testPlanesAreReusedAndCounted`.
- MonitorKit package built successfully from a clean external scratch path.
- Swift frontend parsing, vendor-boundary checks, CPU-pixel checks, and `git diff --check` passed.
- The native CMSampleBuffer association retention probe passed through copy/release behavior.
- The previous full integration proof remains valid: 1,610 app tests passed; the latest affected-source proof added 125 passing tests. Existing package/UI failures remain baseline-reproduced and were not hidden or threshold-adjusted.

No speculative catalog cache or SDK changes were made. The working tree remains uncommitted so the full diff can be reviewed together with the existing feature work.
