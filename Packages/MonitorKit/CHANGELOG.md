# Changelog

All notable changes to MonitorKit are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Until 1.0.0, a minor version may change the public API; every such change is listed under **Changed** or **Removed**.

## [0.1.8] - 2026-10-26

### Fixed

- A live meter's VoiceOver value (and the compact meter's tooltip) was empty until the meter's first display tick, and stayed empty in a render that never ticks, such as a snapshot. Until a tick has written the summary, it is read from the meter.

## [0.1.7] - 2026-10-26

### Fixed

- 0.1.6 did not build with Xcode 26 (Swift 6.2): two meter views copied a property into a local of the same name after the property's first use in the same body. The copies now come first.

## [0.1.6] - 2026-10-26

### Changed

- `LevelMeterView` and `AudioMeterView` draw their bars (true peak and the other bar kinds, loudness and correlation) as Core Animation layers moved by the meter's own display link, instead of a `TimelineView(.animation)` and a `Canvas`. Each of those frames was a SwiftUI update of the host's whole window; now a frame touches only the layers that moved and never re-evaluates a SwiftUI view, and one that looks like the last commits nothing. In Ultracam's main window two live meters had kept the main thread about 60% busy. The public API is unchanged.
- The display link runs only while a meter is live and on screen, not in a hidden or occluded window. Fixed readings and "No audio" draw once per view update.
- Readouts (channel maxima, the over latch, the R 128 grid, correlation) change only when a printed value does, checked at most 10 times a second, and each re-evaluates only its own text. VoiceOver summaries and the compact meter's tooltip refresh at most once a second the same way.

### Added

- `MeterDiagnostics.displayTicks`, the number of display frames every meter in the process has drawn, for a host's diagnostics and performance checks.

## [0.1.5] - 2026-10-25

### Fixed

- `LoudnessEngine` no longer makes a dynamic exclusivity check on the audio thread. In unoptimized builds it called `swift_beginAccess` on every `process`, and on macOS 26 a thread's first such call allocates the runtime's exclusivity context, so the first callback on an audio thread allocated. MonitorKitAudio now has no `swift_beginAccess` in debug or release builds.

## [0.1.4] - 2026-10-25

### Fixed

- Extend loudness histogram range and safely normalize extreme finite channel weights while preserving quiet channels; bound extreme biquad magnitude arithmetic.
- Enforce mutable submission invariants, share cold pipeline compilation, warm both unknown-size filter variants, invalidate metadata-dependent focus masks, and retain cross-engine Metal 4 scope resources through completion.
- Reject unsupported GPU LUT domain spans, preserve filename fallback for blank LUT titles, validate false-color bands and preserve exact ARRI neutral code boundaries.
- Keep extreme low-target EETF curves monotone, reject overflowing scope viewports, select layer colors from visible surfaces, and preserve outstanding caller-owned command-buffer lifetimes.
- Preserve changed metadata and secondary planes when freezing a frame that aliases existing frozen storage.
- Correct guide clearing, safe-area selection limits, fractional-target loudness readouts and selected-meter accessibility announcements.
- Reject invalid frame planes, texture shapes and overflowing viewport dimensions before GPU encoding; failed picture and Metal 4 scope preparation no longer leaves a stale draw available.
- Synchronize residency retirement bookkeeping, preserve stencil-only sample counts, retry partially recorded pipeline archives, and validate texture-cache and warm-up requests.
- Prevent duplicate asynchronous scope compilation after completion or failure, reject cross-device scope residency, and preserve all lanes when counting SIMD ballots.
- Apply changed scope accumulation intervals to fused groups, separate scopes that stop measuring from live hidden scopes, and clear stale published geometry when pictures or scopes disappear.
- Correct audio peak-hold release when its timer expires partway through a buffer, reject unrepresentable meter calibration parameters, bound custom scale generation, and prevent histogram conversion traps and biquad magnitude overflow.
- Make correlation independent of callback partitions with exact per-sample exponential weights and nine Double vDSP passes over the selected pair; reject VU coefficients whose rounded poles are unstable, and preserve silence through custom scale conversions.
- Handle degenerate BT.1886 endpoints, white-point temperatures outside the daylight domain, overflowing color analysis, and invalid layout, guide, gesture and readout inputs without integer traps or invalid geometry.
- Revalidate mutable display configuration, release paused offscreen GPU work after completion, resume UIKit display links after scene activation, and show unavailable reasons in list legends.
- ARRI LogC false colour shows clipped highlights red and crushed blacks purple: the top zone is open upward (full code 1023, legal 940 and super-whites were grey) and the bottom zone open downward (legal sub-blacks were grey). The ARRI-style S-Log3 mode keeps purple's floor at code 0 so saturated blues do not read as black clipping. See MATH.md §4.2.
- Float RGB frames with NaN or infinite samples keep their clip, zebra, peaking and guide overlays, and magnifying an infinite area no longer draws black; NaN reads as 0 and ±inf as ±65504. The shader clamps hand-filled guide and band counts.
- Saving a `MonitorState` or `MonitorOutputColor` with a NaN or infinite field writes its normalized value instead of throwing.
- A synchronous pipeline request waits for a stalled background build only up to a deadline, then compiles itself, in both `MonitorEngine` and `ScopeEngine`, so starved background builds cannot hang warm-up. A failed background specialization is not restarted every frame.
- Library-made frame ids start at 2^63, so a frozen frame's focus mask cannot be reused for a host frame numbered the same.
- The first `AudioMeter.process(bufferList:)` call allocates nothing; snapshots claiming more than 16 channels no longer trap; degenerate meter scales never position at NaN; the clip count saturates instead of wrapping.
- `LevelMeterView` draws nothing for a NaN bar or a non-positive hold, and an endless hold follows peak resets on sample-peak bars. VoiceOver steps on a slider never move a value against the requested direction when it lies outside the slider's range.
- 1:1 magnifier pans are pixel exact (small drags were lost in one direction and doubled in the other), and pans keep the centre of an axis that fits. A re-added tile whose source was cleared no longer keeps a stale viewport, layout or status, and a second renderer drawing nothing cannot clear another renderer's publication.

### Changed

- Cache immutable color transforms, bound guide generation, simplify the Method C reference algebra, and avoid redundant picture/scope geometry and scene reconciliation work.
- Avoid temporary loudness display arrays and unused focus-mask dependencies. Loudness histograms use 96 KB more default fixed storage, with an initialization-only tail for extreme custom weights; audio processing remains allocation-free.
- See [the follow-up audit](Docs/AUDIT-2026-10-25-ROUND2.md) for measured improvements, algorithm comparisons and retained limitations.
- Reuse the PPM coefficients produced during configuration validation when initializing `AudioMeter`, avoiding duplicate calibration and buffer allocation while retaining validation of disabled meters.

## [0.1.3] - 2026-10-25

### Fixed

- `LevelMeterView` and `AudioMeterView`: the hold line held 4 s instead of 2, because the meter's own hold, offered with every snapshot, kept restarting it; it now holds `peakHoldTime` from the last peak, then falls.
- A peak reset from the host, `AudioMeterView`'s menu or VoiceOver restarts the hold line while audio is flowing; before, only a reset seen before the next audio did.
- The bars and hold lines no longer freeze when the wall clock steps back: the meters keep their own clock, and `MeterDisplayBallistics` and `MeterHoldLine` treat a time before the last one as a new origin.
- Drawing a frame builds no colours (a dimmed zone allocated for every unlit rectangle); readouts and the VoiceOver summary pause with the bars when there is no audio; fixed readings no longer offer a Reset Peaks action.
- Red readouts keep 4.5:1 on the window in light and dark appearance; long channel labels truncate instead of widening the strip; the R 128 panel's Max TP reads "−∞ dBTP" in silence.
- `MeterText.number` no longer traps on an infinite or huge value.

### Changed

- `AudioMeterSnapshot.correlation` is the Pearson correlation: the window's means come off, so a DC offset no longer pulls the reading towards +1 (unrelated noise with a common offset read +0.97), DC alone reads NaN and DC against signal reads 0. The window's moments are divided by its total weight, so the first time constants after a start or reset are unbiased.

## [0.1.2] - 2026-10-25

### Added

- `LevelMeterView` (MonitorKitUI): a broadcast true-peak level meter in three styles, compact, strip and full. Hard colour zones fixed in dB (green below −9, amber to −1, red from −1 dBTP), a hold line, an over latch that lights on a clipped sample or a true-peak maximum at −1 dBTP and stays lit until clicked, each channel's held maximum, one to sixteen channels, and one VoiceOver element with a Reset Peaks action. One `TimelineView(.animation(paused:))` and one Canvas per meter, one `snapshot()` per frame, the fall extrapolated between snapshots and readouts at 10 Hz.
- `MeterScale.expandedPeak(unit:reference:cautionLevel:maximumPeak:)`: −60…0 dBTP with an expanded top and the SMPTE RP 155 −20 dBFS reference line; `zoneSpans`, `ticks` and `layout(level:hold:)` (`MeterZoneSpan`, `MeterTick`, `MeterChannelLayout`).
- `MeterDisplayBallistics` and `MeterHoldLine`: a display's bar and hold line between snapshots.
- `AudioChannelLevels.isOver(maximumTruePeak:)`, `AudioMeterSnapshot.isOver(maximumTruePeak:)` and `peakToLoudnessRatio`.
- Phase correlation (`AudioMeterKinds.correlation`, on in `.all`): `AudioMeterSnapshot.correlation`, `AudioMeterConfiguration.correlationTime` and `correlationChannels`, with no allocation inside `process`.
- `MeterText`: readout text with one decimal and a typographic minus, "−∞" for silence and "—" for no reading.
- `MeterPalette.lightTrack`, `unlitOpacity`, `reference`, `latch`, `track(for:)` and `color(_:scheme:)`.

### Changed

- `AudioMeterView` draws the same bars as `LevelMeterView`'s full style: true peak by default on `MeterScale.expandedPeak()` with the red zone from −1 dBTP, hold lines, each channel's maximum and the over latch (clip LEDs are gone). The R 128 panel defaults to absolute LUFS (`loudnessUnit: .lufs`) with the −23 LUFS target line, adds PLR, and the panel adds a phase-correlation meter. The well stays dark in light appearance and the lines adapt. New parameters `present` and `name`. Reset Peaks also on the context menu; clicking the bars no longer resets.
- `MeterPalette.standard`'s colours step in luminance as well as hue, for colour-blind viewers.
- `LoudnessReadout` adds `peakToLoudnessRatio`.

## [0.1.1] - 2026-10-24

### Fixed

- The library compiles with Xcode 26.0.1 and 26.6 (Swift 6.2 and 6.3), and its tests with Xcode 26.6. Those compilers gave up type-checking the waveform and chroma graticule tick builders (`WaveformScale.ticks`, `chromaTicks`) and several test expressions. Behaviour is unchanged. Running the tests needs Xcode 26.6 or later.

## [0.1.0] - 2026-10-24

The first public release.

### Added

Picture (`MonitorKit`, `MonitorKitCore`):

- `MonitorEngine`, `MonitorFeed`, `MonitorPass` and `MonitorMultiview`: one picture pass per surface (decode, burn-in and monitor LUTs, false colour or display transform, display adjustments, output conversion, zebras, clip indicators, peaking, guides, navigator), encoded into the host's command buffers. Classic Metal (`MTLCommandBuffer`) and Metal 4 (`MonitorSubmission` over an `MTL4CommandBuffer`) produce bit-identical pixels.
- Frame layouts: v210, UYVY, YUYV, 8/10/16-bit biplanar 4:2:0, 4:2:2 and 4:4:4, BGRA8/RGBA8, RGB10A2, RGBA16 and RGBA16F/RGBA32F; legal and full range, BT.601, BT.709, BT.2020 and SMPTE 240M matrices, and every ITU-T H.273 chroma siting. `MonitorFrame.wrap(_:cache:signal:)` reads CoreVideo attachments, including the clean aperture and pixel aspect ratio.
- Exposure tools: two zebra sets (band or lower limit); false colour (Sony S-Log3 Monitor & Control Pattern 2, ARRI LogC3/LogC4 code-value tables, ARRI-style on S-Log3, six-band display IRE, custom bands in IRE or stops); per-channel clip indicators with exact clip percentages.
- Focus and framing: focus peaking at source resolution (coloured edges or traditional peak); magnify with 1:1, 1–64× zoom, pan and a navigator inset; aspect guides, safe areas, thirds, grids, diagonals and centre marks drawn analytically; anamorphic de-squeeze, flip and clean aperture.
- Per-surface picture stage (`MonitorState.pictureStage`: source, output or monitor), with every tool measuring its own stage. A distinct output reading (`SignalDescription.outputReading`) lets the output and monitor stages decode the codes differently from the source declaration, in the same pass.
- `.cube` LUTs (`CubeLUT`, `MonitorLUT`): 3D 2³–65³, 1D and shaper tables, tetrahedral, trilinear and hardware interpolation, monitor-only and burn-in routing.
- Display transforms: log to Rec.709 (S-Log3, LogC3, LogC4), PQ to SDR (BT.2408 Annex 5 EETF), HLG to SDR (Report ITU-R BT.2446-1 Method C), each followed by the Report ITU-R BT.2407 gamut step, and HDR passthrough with roll-off to the EDR headroom.
- Display adjustments: brightness, contrast, saturation, white-point trim (temperature and tint), luma monochrome and blue only.
- Output colour (`MonitorOutputColor`, `MonitorLayerColor`): signal-native, SDR (BT.1886, sRGB, gamma 2.2), extended linear, PQ and HLG on Rec.709, Display P3 or Rec.2020; overlays at BT.2408 graphics white; layer tagging with colour space and EDR metadata.
- Freeze (`MonitorFeed.freeze(_:into:)`, `unfreeze(keepingMemory:)`): one compute copy into feed-owned planes, the only frame copy the library makes.
- `MonitorStatus`: what each surface shows and, through `MonitorTool` and `MonitorUnavailableReason`, why a tool that is on is not drawn.
- Metal 4 support: `MonitorSubmission`, `MonitorUniformAllocator`, `MonitorResidency`, `MonitorUniformRing`, `MonitorTextureCache` (IOSurface-keyed, residency-aware frame textures); library-owned argument tables and barriers.
- Start-up: `MonitorEngine.warmUp(targets:layouts:surfaces:save:)`, a host `MTL4Compiler` (`MonitorEngine(…, compiler:)`), and a persistent pipeline warm start (`MonitorPipelineArchive`, `cacheDirectory:`) with content-verified Metal 4 archives.
- Fused tier: `MonitorShaders` with `MKLUT.msl` (`mk_applyLUT`) and `MKDecode.msl` (`mk_decodeRGB`), versioned (`MonitorShaders.lutLayoutVersion`) and include-guarded, so a host kernel burns in exactly the LUT the monitor shows.
- Settings: `MonitorState` is a `Codable` value with fail-closed JSON (`"kind": "MonitorKit.MonitorState"`, `schemaVersion` 2), lenient decoding inside a valid blob, and non-throwing helpers (`MonitorState(decodingOrDefault:)`, `decodedOrDefault(from:)`, `@LenientMonitorState`).

Scopes (`MonitorKitScopes`):

- `ScopeEngine`, `ScopeAccumulator`, `ScopeGroup` (one fused pass for a stage's waveform, histogram and vectorscope), `ScopeRenderer` and `ScopeStatisticsReader`, classic and Metal 4, counting every pixel on the GPU with no readback.
- Waveform (luma, RGB overlay, RGB parade, Y'CbCr parade), vectorscope (1/2/4×, 75 and 100 % targets for BT.601/709/2020, skin-tone line), histogram (luma, RGB overlay, parade; linear or log).
- Percent, code-value and PQ/HLG nit graticules; HDR-aware colours; level ranges `.standard` (−7…109 %) and `.minus10To110`; trace palettes `.standard` and `.plain`, and the `ScopeSettings.plainWaveform(mode:stage:)` preset (768 × 256 over −10…110 IRE).
- GPU statistics: luma extremes and mean, clip fractions per channel.

Audio (`MonitorKitAudio`):

- `AudioMeter` for 1–16 channels at 8–768 kHz: sample peak, ITU-R BS.1770 true peak, RMS, VU (IEC 60268-17), PPM Type I / IIa / IIb (IEC 60268-10), and BS.1770 / EBU R 128 loudness (momentary, short-term, integrated, loudness range, maxima, Max TP), with hold, decay, pause and reset. `LoudnessMeter` for loudness alone. `MeterScale` marks and zones for every meter type. Realtime-safe: no allocation, lock or blocking in `process`.

UI (`MonitorKitUI`):

- `MonitorMetalView` (convenience or host-driven, `CAMetalDisplayLink`, EDR headroom tracking, gestures) and `MonitorRenderer`, with scene handles (`MonitorScene`, `MonitorSource`, `MonitorSurface`, `MonitorScopeOverlay`, `MonitorRegion`).
- SwiftUI views: `MonitorView`, `MonitorSceneView`, `ScopeView`, `ScopeStackView`, `ClipReadout`, `MonitorStatusOverlay`, `AudioMeterView`, `FalseColorLegendView`, `ScopeIREScaleView`, and `MonitorTileToolbar` with per-tool controls.

Documentation: README, FEATURES, API, INTEGRATION, ARCHITECTURE and MATH (every constant with its source and the test that checks it).

[0.1.8]: https://github.com/andrewfitz/MonitorKit/releases/tag/0.1.8
[0.1.7]: https://github.com/andrewfitz/MonitorKit/releases/tag/0.1.7
[0.1.6]: https://github.com/andrewfitz/MonitorKit/releases/tag/0.1.6
[0.1.5]: https://github.com/andrewfitz/MonitorKit/releases/tag/0.1.5
[0.1.4]: https://github.com/andrewfitz/MonitorKit/releases/tag/0.1.4
[0.1.3]: https://github.com/andrewfitz/MonitorKit/releases/tag/0.1.3
[0.1.2]: https://github.com/andrewfitz/MonitorKit/releases/tag/0.1.2
[0.1.1]: https://github.com/andrewfitz/MonitorKit/releases/tag/0.1.1
[0.1.0]: https://github.com/andrewfitz/MonitorKit/releases/tag/0.1.0
