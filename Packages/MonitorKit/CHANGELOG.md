# Changelog

All notable changes to MonitorKit are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Until 1.0.0, a minor version may change the public API; every such change is listed under **Changed** or **Removed**.

## [0.1.0] - Unreleased

The first public release. MonitorKit was developed inside Ultracam (pre-release snapshots W1 `e82659f` and W2 `a1b652a`); the sections after **Added** list what changed relative to the W2 snapshot, for hosts that integrated it.

### Added

Picture (`MonitorKit`, `MonitorKitCore`):

- `MonitorEngine`, `MonitorFeed`, `MonitorPass` and `MonitorMultiview`: one picture pass per surface (decode, burn-in and monitor LUTs, false colour or display transform, display adjustments, output conversion, zebras, clip indicators, peaking, guides, navigator), encoded into the host's command buffers. Classic (`MTLCommandBuffer`) and Metal 4 (`MonitorSubmission` over an `MTL4CommandBuffer`) with bit-identical pixels.
- Frame layouts: v210, UYVY, YUYV, 8/10/16-bit biplanar 4:2:0, 4:2:2 and 4:4:4, BGRA8/RGBA8, RGB10A2, RGBA16 and RGBA16F/RGBA32F; every range, matrix (BT.601, BT.709, BT.2020, SMPTE 240M) and H.273 chroma siting.
- Two zebra sets (band or lower limit); false colour (Sony S-Log3 Pattern 2, ARRI LogC3/LogC4 tables, ARRI-style on S-Log3, EL Zone (provisional), six-band, custom IRE or stops); per-channel clip indicators; focus peaking at source resolution (coloured edges or peak); magnify with 1:1, zoom, pan and navigator; frame guides, safe areas and grids drawn analytically; de-squeeze; flip; monochrome and blue only; brightness, contrast, saturation and white-point trim.
- `.cube` LUTs (`CubeLUT`, `MonitorLUT`): 3D 2³–65³, 1D and shaper tables, tetrahedral, trilinear and hardware interpolation, monitor-only and burn-in routing.
- Display transforms: log to Rec.709 ("MonitorKit display assist v1"), PQ and HLG to SDR (BT.2408 Annex 5 EETF), HDR passthrough with roll-off to the EDR headroom.
- Output colour (`MonitorOutputColor`, `MonitorLayerColor`): signal-native, SDR (BT.1886, sRGB, gamma 2.2), extended linear, PQ and HLG on Rec.709, Display P3 or Rec.2020; overlays at BT.2408 graphics white; layer tagging with colour space and EDR metadata. `SignalDescription.primaries`, read independently of the transfer.
- Freeze (`MonitorFeed.freeze(_:into:)`, `unfreeze(keepingMemory:)`): one compute copy into feed-owned planes, the only frame copy the library makes.
- Metal 4 types: `MonitorSubmission`, `MonitorUniformAllocator` / `MonitorUniformAllocation`, `MonitorResidency`, `MonitorUniformRing`; library-owned argument tables and barriers.
- `MonitorStatus` with `MonitorTool` and `MonitorUnavailableReason`: what each surface shows and why a tool that is on is not drawn.
- Fused tier: `MonitorShaders` (`source(_:)`, `compileOptions`, `makeLibrary`, `libraryDescriptor`), `MKLUT.msl` (`mk_applyLUT`) and `MKDecode.msl` (`mk_decodeRGB`) for a host's own kernel.
- `MonitorState.pictureStage` (`SignalStage`, default `.monitor`) and `MonitorState.pictureHasLUT(burnInLUT:monitorLUT:)`: show the source, output or monitor stage; tools keep measuring their own stages.
- Clean aperture: `MonitorFrame.cleanAperture` (validated by `MonitorFrame.init`, read by `wrap`), static `MonitorFrame.cleanAperture(of:)` and `MonitorFrame.geometry(of:)`, `MonitorFrame.geometry`, `MonitorFrameGeometry` (`shownRect`, `displayAspectRatio(desqueeze:)`, `displayAspectRatio(for:)`, `pixelAspectRatioRange`, `hasUsablePixelAspectRatio`, `effectivePixelAspectRatio`), `MonitorLayout.aperture`, `MonitorLayout(…, cleanAperture:)`, `MonitorLayout(frame:state:viewportWidth:viewportHeight:)` and `MonitorLayout(frame:state:viewport:)`, `AxisMap.display(_:toPicture:flip:)`, `ViewGeometry.normalized()`.
- `MonitorFrame.isProcessed`: a processed picture (a programme mix, a scaled or graded render) refuses the tools that need the camera's own signal.
- `MonitorTextureCache`: IOSurface-keyed, residency-aware plane textures for Metal 4 hosts (`frame(_:signal:owner:now:)`, `makeTexture(…)`, `sweep(now:)`, `flush(owner:)`, `removeAll()`, `count`, `count(owner:)`, `texturesMade`, `idleLifetime`, `sweepInterval`, `uptime()`).
- `MonitorEngine(…, compiler:)` and `MonitorEngine.compiler`: build the library and pipelines with the host's `MTL4Compiler`.
- Warm-up: `MonitorEngine.warmUp(targets:layouts:surfaces:)`, `MonitorEngine.standardTargetFormats`, `MonitorSurfaceConfiguration`.
- `MonitorShaders.lutLayoutVersion` (2) and whole-file include guards on every `.msl` part.
- `MonitorLUT(…, outputEncoding:)`, `MonitorLUT.outputEncoding` and `LUTOutputEncoding` (`.rec709`, with its `signal` for tagging a host's output buffer).
- `MonitorTool.picture`; `MonitorUnavailableReason.requiresCameraSignal` and `.unsupportedGeometry`; `MonitorStatus.pictureStage`, `isCodeValueView` and `codeValueViewNote`.
- `MonitorState.codingKind`; non-throwing decodes `MonitorState(decodingOrDefault:)` and `MonitorState.decodedOrDefault(from:)`; the `@LenientMonitorState` property wrapper, so a host's own `Codable` settings survive a foreign or old monitor blob.
- `MonitorLayout.pictureFraction(x:y:)`, `picturePoint(fractionX:fractionY:)` and `pictureFraction(displayX:displayY:)`: frame pixels to and from fractions of the clean aperture.
- `MonitorSurfaceConfiguration.pixelAspectRatio` and `cleanAperture`, so warm-up builds the filter variant anamorphic or cropped frames draw with.
- Per-stage decode: `SignalReading` (`range`, `matrix`) and `SignalDescription.outputReading`, how the Output and Monitor stages read the codes when that differs from the source's declared `range` and `matrix` (a camera declared full range on a legal link, a SMPTE 240M source whose output path decodes BT.709); `sourceReading`, `effectiveOutputReading`, `hasDistinctOutputReading`, `outputSignal`, `signal(for:)`; `MonitorFrame.parameters(for:)`. The picture pass decodes those stages a second time with that reading (exact at integral codes), in the same pass; focus analysis, scopes and scope groups bind their stage's reading. A specialized pipeline compiles the second decode only when a drawn tool reads those stages. Lenient JSON key `outputReading`.
- Persistent pipeline warm start: `MonitorPipelineArchive` (`statistics`, `files`, `save()`, `saveDelay`, `directory`, `name`, `key`, `maximumFiles`), `MonitorEngine(device:specialization:framesInFlight:compiler:cacheDirectory:)`, `ScopeEngine(device:specialization:framesInFlight:residency:cacheDirectory:)` and `pipelineArchive` on both. Metal 4 archives in the host's caches directory, named `<name>-<gpu>-<key>-<content>.mtl4archive`: the key hashes the shader source, compile options, GPU, OS build and validation settings, the content hash is verified before Metal reads a file. Only the newest file is opened at launch, older ones (3 kept per key) at the first pipeline it lacks.
- `save:` (default true) on `MonitorEngine.warmUp(targets:layouts:surfaces:save:)`, `ScopeEngine.prepare(pixelFormats:save:)` and `prepare(settings:layouts:pixelFormats:save:)`: warm several engines, then save each archive once (source-compatible; defaulted parameters).
- Report ITU-R BT.2446-1 Method C for HLG → SDR (`BT2446MethodC` in `MonitorKitCore`, `HDRToSDR.hlg`): 38 % HLG → 53.2 % SDR, 50 % → 70 %, 75 % → 96 %; both HDR → SDR transforms then go into BT.709 by Report ITU-R BT.2407 §2.

Scopes (`MonitorKitScopes`):

- `ScopeEngine`, `ScopeAccumulator`, `ScopeGroup` (one fused pass for a stage's waveform, histogram and vectorscope), `ScopeRenderer` and `ScopeStatisticsReader`, classic and Metal 4. Waveform (luma, RGB overlay, RGB parade, Y'CbCr parade), vectorscope (1/2/4×, 75 and 100 % targets, skin-tone line), histogram (luma, RGB overlay, parade); percent, code-value and PQ/HLG nit graticules; HDR-aware colours; GPU statistics (luma extremes and mean, clip fractions per channel).
- `ScopeLevelRange` (`.standard` −7…109 %, the default; `.minus10To110`) with `low` and `high`; `ScopeSettings.levelRange` and `ScopeSettings.AccumulationKey.levelRange`; `ScopeLevelAxis.fraction(ofLevel:range:)`, `level(atFraction:range:)`, `drawnFraction(ofLevel:bins:range:)`; `WaveformScale.ticks(range:levelRange:)` and `chromaTicks(range:levelRange:)`. The existing statics forward to `.standard` and return the same results.
- `ScopeTracePalette` (`.standard`, `.ultracamLegacy`) and `ScopeDisplay.palette`: the legacy palette is the earlier Ultracam colours without bloom, for waveforms and histograms.
- `ScopeSettings.ultracamLegacy(mode:stage:)`, `ScopeSettings.ultracamLegacyImageWidth` (768) and `ultracamLegacyImageHeight` (256).
- Warm-up: `ScopeEngine.drawablePixelFormats`, `prepare(pixelFormats:)`, `prepare(settings:layouts:pixelFormats:)`, `isPrepared(target:)`, `isPrepared(pixelFormat:)`; `prepareMetal4()` on `ScopeAccumulator`, `ScopeGroup` and `ScopeRenderer`.
- Two lenient JSON keys, `levelRange` and `display.palette`: settings saved before them decode to the standard look, and unknown values fall back to it.

Audio (`MonitorKitAudio`):

- `AudioMeter` for 1–16 channels at 8–768 kHz: sample peak, BS.1770 true peak, RMS, VU (IEC 60268-17), PPM Type I / IIa / IIb (IEC 60268-10), BS.1770 / EBU R 128 loudness (momentary, short-term, integrated, loudness range, maxima, Max TP), with hold, decay, pause and reset. `LoudnessMeter` for loudness alone. `MeterScale` marks and zones for every meter type. Realtime-safe: no allocation, lock or concurrency in `process`.

UI (`MonitorKitUI`):

- `MonitorMetalView` (convenience or host-driven, `CAMetalDisplayLink`, EDR headroom tracking, gestures), `MonitorRenderer`, the scene handles (`MonitorScene`, `MonitorSource`, `MonitorSurface`, `MonitorScopeOverlay`, `MonitorRegion`), SwiftUI views (`MonitorView`, `MonitorSceneView`, `ScopeView`, `ScopeStackView`, `ClipReadout`, `MonitorStatusOverlay`, `AudioMeterView`), the controls and `FalseColorLegend`.
- `FalseColorLegend` fields `headline`, `analysis`, `sourceName`, `captions`, `footnotes`, `provisionalReason`, `unavailableNote`, `showsSwatchesAsGrid`, and `Entry.swatchLabel`; `FalseColorLegendView.Style` (`.list`, `.captioned`) and `FalseColorLegendView(legend:style:unavailable:)`. `FalseColorLegendView(legend:)` is unchanged and draws the list style.
- `ScopeIREScale` (`init(levels:axis:bins:)`, `Mark`, `standardLevels`, `monitorKitAxis`, `legacyAxis`, `fraction(ofLevel:axis:bins:)`, `rangeText`, `caption`, `accessibilityLabel`) and `ScopeIREScaleView(scale:showsGrid:)`.
- `MonitorTileToolbar` (with a convenience initializer without scope settings), `MonitorTileTool` (`standard`, `title`, `systemImage`, `isOn(in:)`, `toggled(_:falseColorMode:magnify:)`, `suggestedFalseColorMode(for:)`), `MonitorFreezeState` (with `actionTitle` and `accessibilityValue`), `MonitorMagnifyChoice`, `MonitorTileToolbarPlacement`.

Documentation: README, FEATURES, API, INTEGRATION, ARCHITECTURE and MATH (every constant with its source and test); Apache License 2.0.

### Changed (relative to the W2 snapshot)

- **Breaking:** `MonitorState` JSON is fail-closed. It writes `"kind": "MonitorKit.MonitorState"` and `schemaVersion` 2, and decoding throws `DecodingError.dataCorrupted` for JSON without that `kind` or with a `schemaVersion` below 2, including MonitorKit's own W1/W2 JSON. Catch the error and fall back to defaults or a legacy decoder (or use `MonitorState(decodingOrDefault:)`, `decodedOrDefault(from:)` or `@LenientMonitorState`). Fields inside a valid blob still decode leniently.
- **Breaking:** new enum cases `MonitorTool.picture`, `MonitorUnavailableReason.requiresCameraSignal` and `MonitorUnavailableReason.unsupportedGeometry` break exhaustive `switch` statements.
- **Breaking (behaviour):** `MonitorFeed.monitorStageHasLUT(for:)` follows `MonitorState.pictureStage`; it returns false for `.source` even when the feed has a burn-in LUT.
- **Breaking (behaviour):** `MonitorLayout.pictureWidth` and `pictureHeight` are the clean aperture's size (unchanged when there is none). A pixel aspect ratio that is not finite or is outside 1/16…16 is drawn with square pixels and reported as `.unsupportedGeometry`; it used to be honoured.
- `MonitorStatus.activeLabels` gains a `.picture` entry for log or unlabelled pictures shown without a LUT or transform ("S-Log3 code values") and for non-default picture stages.
- `MonitorFrame.wrap(_:cache:signal:)` reads the clean aperture attachment, so a picture that carries one is cropped to it.
- `MonitorFrame.pixelAspectRatio` still reads finite and positive (1 otherwise), but the declared value is kept: a broken tag reaches `geometry` and is reported as `.unsupportedGeometry`.
- Log and unlabelled pictures with no LUT and no display transform are labelled as a code-value view.
- **Behaviour:** HLG → SDR (`DisplayTransform.hdrToSDR` on HLG) is BT.2446-1 Method C instead of the scene-light convention (75 % HLG scaled to 100 % SDR with the BT.709 OETF and a hard clip above reference white): mid-tones are brighter and highlights roll off up to 100 % SDR at about 82.9 % HLG.
- `MonitorFeed` keeps a focus mask analysed with one reading apart from another: with a distinct output reading, an Output-stage mask with no LUT is not the source's. `MonitorRenderer` analyses such a surface on its own stage.
- `PassParameters` is 1520 bytes (`outputReading`, `hlgToSDR`, `sourceWeights`), and the picture pass's buffer 0 is the 160-byte `mk_PassFrames` (the source and the output reading's `FrameParameters`); `MonitorPass.uniformLength` stays 5120. Bind by the constants and `MemoryLayout`, as before.

### Fixed

- See [MATH.md §9](Docs/MATH.md#9-discrepancies) for the record of the constants corrected before this release (S-Gamut3 luminance weights, 4:2:0 vertical chroma siting, SMPTE 240M, ARRI wide gamuts, full-container log rescaling, ARRI range convention, stops on non-BT.709 sources).

[0.1.0]: https://github.com/OWNER/MonitorKit/releases/tag/0.1.0
