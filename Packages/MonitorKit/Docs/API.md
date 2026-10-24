# MonitorKit API reference

Every public type, by module, with the rules for threads and lifetimes. Parameters, defaults and ranges of the tool settings are in [FEATURES.md](FEATURES.md); the guarantees behind each call (barriers, residency, allocation) are in [ARCHITECTURE.md](ARCHITECTURE.md); step-by-step integration is in [INTEGRATION.md](INTEGRATION.md). Every code sample in these documents is compiled against the package.

Contents:

1. [Threads and lifetimes](#1-threads-and-lifetimes)
2. [MonitorKitCore](#2-monitorkitcore)
3. [MonitorKit](#3-monitorkit)
4. [MonitorKitScopes](#4-monitorkitscopes)
5. [MonitorKitAudio](#5-monitorkitaudio)
6. [MonitorKitUI](#6-monitorkitui)
7. [Errors](#7-errors)

## 1. Threads and lifetimes

| Kind | Types | Rule |
| --- | --- | --- |
| Shared engines | `MonitorEngine`, `ScopeEngine`, `MonitorLUT`, `MonitorResidency`, `MonitorTextureCache`, `ScopeStatisticsReader` | `Sendable`. Immutable after init apart from locked caches; use from any thread |
| Confined encoders | `MonitorFeed`, `MonitorPass`, `MonitorMultiview`, `ScopeAccumulator`, `ScopeGroup`, `ScopeRenderer`, `MonitorRenderer` | Not `Sendable`, no internal locks: one thread at a time (your render thread). Create them there, move them with `sending`, or keep them on a global actor whose executor is that thread. A `ScopeRenderer` and the accumulators it draws stay on one thread |
| Per-frame values | `MonitorFrame`, `MonitorSubmission`, `MonitorState`, settings | Values. `MonitorFrame` is `@unchecked Sendable` (it wraps textures); `MonitorSubmission` is not `Sendable` (it holds your command buffer) |
| Scene handles | `MonitorScene`, `MonitorSource`, `MonitorSurface`, `MonitorScopeOverlay`, `MonitorCompletionReporter` | `Sendable`, lock-protected: edit from the UI, submit frames from the capture thread |
| Views | `MonitorMetalView`, the SwiftUI views | `@MainActor`. The view's renderer runs on its display-link thread |
| Audio | `AudioMeter`, `LoudnessMeter` | `process` from one thread (the audio thread); `snapshot()`, resets and pause from any thread |

Lifetimes:

- **Frames.** MonitorKit borrows frame textures and never retains them past your command buffer. Keep a `MonitorFrame` (and the `CVMetalTexture` or pixel buffer it holds) alive until every command buffer that reads it has completed.
- **Classic path.** Command buffers created with retained references keep the library's resources alive. With unretained references, keep frames, LUTs, feeds, passes, accumulators and renderers alive until their last command buffer completes; replaced masks, bins and textures stay referenced for `MonitorFeed.retiredFrames` (3) more uses, and an idle feed drops them with `releaseRetired()` once its work completed.
- **Metal 4.** The library releases nothing early: a replaced resource (and everything an object owns when it is deallocated with work in flight) stays alive and resident until the submission that last used it completes, keyed by the submission indices you report. Keep the engines alive until their work completes.

## 2. MonitorKitCore

Pure Swift (no Metal): settings, signal descriptions, geometry, LUT parsing, output colour and the CPU reference math. `MonitorKit` re-exports it.

### 2.1 Settings

| Type | Purpose |
| --- | --- |
| `MonitorState` | Every tool setting of one surface: `clean`, `zebras` (two `ZebraSet`), `falseColor`, `focus`, `guides`, `geometry`, `display`, `monitorLUT`, `displayTransform`, `clipIndicators`, `pictureStage`. `normalized()` clamps everything. `pictureHasLUT(burnInLUT:monitorLUT:)`. Codable, fail-closed: `schemaVersion` (2), `codingKind` (`"MonitorKit.MonitorState"`), `maximumZebraSets`. Non-throwing decodes: `init(decodingOrDefault:)`, `decodedOrDefault(from:)` |
| `LenientMonitorState` | Property wrapper for a `MonitorState` field inside your own `Codable` type: a missing, `null` or foreign value decodes to the defaults instead of failing the whole outer value; encodes the state as a plain field would |
| `SignalStage` | `.source`, `.output`, `.monitor` |
| `ZebraSet`, `ZebraMode` | `init(enabled:mode:level:range:opacity:stage:)`, `covers(ire:)` (CPU reference) |
| `FalseColorSettings`, `FalseColorMode`, `FalseColorBand`, `FalseColorUnit` | `mode.needsLogSource`; `maximumCustomBands` (16) |
| `FocusSettings`, `PeakingStyle`, `PeakingColor` | `edgeThreshold`; `PeakingColor.rgb` |
| `GuideSettings`, `FrameGuide`, `FrameGuideStyle` | `FrameGuide.standardAspects` |
| `ViewGeometry`, `Magnification`, `FlipMode` | `ViewGeometry.standardDesqueezeFactors`, `normalized()`; `Magnification.isActive` |
| `DisplayAdjustments`, `MonochromeMode` | `isIdentity`, `trimsWhitePoint` |
| `DisplayTransform`, `DisplayTransformSettings` | `.none`, `.logToRec709`, `.hdrToSDR`, `.hdrPassthrough`; `pqSourcePeak` |
| `ClipIndicatorSettings`, `ClipIndicatorColoring` | `isEffective`, `indicator(rgb:luma:)` and `color(_:channels:over:uniform:)` (CPU reference) |
| `LUTInterpolation`, `LUTRouting`, `LUTOutputEncoding` | `.tetrahedral` / `.trilinear` / `.hardware`; `.monitorOnly` / `.burnIn`; `.rec709` and its `signal` |

```swift
import Foundation
import MonitorKitCore

func configuredState() -> MonitorState {
  var state = MonitorState()
  state.zebras[0] = ZebraSet(mode: .band, level: 44, range: 1)  // "44 ± 1": mid grey on S-Log3
  state.zebras[1] = ZebraSet(mode: .lowerLimit, level: 100.5)  // "100+"
  state.falseColor.mode = .sonySLog3
  state.focus.enabled = true
  state.focus.sensitivity = 0.75  // High
  state.guides.enabled = true
  state.guides.frameGuides = [FrameGuide(aspect: 2.39, style: .linesAndMatte)]
  state.guides.safeAreas = [90]
  state.geometry.desqueeze = 2
  return state.normalized()
}

func save(_ state: MonitorState) throws -> Data { try JSONEncoder().encode(state) }

/// JSON without MonitorKit's `kind`, or with a schema below 2, throws. Try your own
/// legacy decoder on the error, else take the defaults; never half-read a foreign blob.
func load(_ data: Data, legacy: (Data) -> MonitorState?) -> MonitorState {
  do {
    return try JSONDecoder().decode(MonitorState.self, from: data)
  } catch {
    return legacy(data) ?? MonitorState()
  }
}

/// Inside your own settings: one bad monitor blob cannot cost the other fields.
struct FeedPreferences: Codable {
  var name: String
  @LenientMonitorState var monitor: MonitorState
}
```

### 2.2 Signals

| Type | Purpose |
| --- | --- |
| `SignalDescription` | `range` (`CodeRange`), `matrix` (`YCbCrMatrix`), `chromaSiting`, `chromaVerticalSiting`, `encoding` (`SignalEncoding`), `primaries` (`ColorPrimaries?`), `outputReading` (`SignalReading?`). `effectivePrimaries`, `isHDR`, `levels(bitDepth:)`, `.rec709` |
| Per-stage reading | `outputReading`: how the Output and Monitor stages read the codes when that differs from the source's `range` and `matrix` (nil, the default: as the source does), e.g. a camera declared full range on a legal-range link, or a SMPTE 240M source whose output path decodes BT.709. The Source stage, log false colour and the camera-signal classifiers keep `range` and `matrix`; the Output and Monitor stages, with or without a LUT, and every tool, scope and focus analysis on them, decode the same codes with `outputReading`. `sourceReading`, `effectiveOutputReading`, `hasDistinctOutputReading` (an `outputReading` equal to the source's is none), `outputSignal` (the signal as those stages read it, no `outputReading` of its own) and `signal(for: SignalStage)`. Lenient JSON key `outputReading` (absent: one reading) |
| `SignalReading` | `range` (`CodeRange`) and `matrix` (`YCbCrMatrix`): one reading of a frame's codes. Lenient `Codable` (missing fields: legal BT.709) |
| `SignalEncoding` | `.display(DisplayTransfer)`, `.log(LogEncoding)`, `.unknown`; `log` |
| `DisplayTransfer` | `.bt709`, `.sRGB`, `.pq`, `.hlg`, `.linear`; `exposureLinear(_:)` |
| `LogEncoding`, `LogCurve`, `LogTransport` | `curve` (`.sLog3`, `.arriLogC3`, `.arriLogC4`), `gamut` (`ColorGamut`), `transport` (`.native`, `.fullRescaledToLegal`); `.sLog3SGamut3Cine`, `.sLog3SGamut3`; `profileID`, `init?(profileID:transport:)`; `LogCurve.signal(expanded:range:transport:bitDepth:)`, `decode(_:)` |
| `PixelLayout`, `ChromaSubsampling` | `.v210`, `.uyvy8`, `.yuyv8`, `.biplanar(_:bitDepth:)`, `.rgb(bitDepth:float:)`; `.nv12`, `.p010`, `.p210`, `.p410`, `.bgra8`, `.rgb10a2`, `.rgba16Float`, `.rgba32Float` |
| `ChromaSiting`, `ChromaVerticalSiting` | Horizontal `.left` / `.center`; vertical `.center` / `.top` / `.bottom` (H.273 types 0–5) |
| `CodeRange`, `YCbCrMatrix`, `ColorGamut` | `.legal` / `.full`; `.bt601`, `.bt709`, `.bt2020`, `.smpte240m`; `.rec709`, `.rec2020`, `.sGamut3`, `.sGamut3Cine`, `.arriWideGamut3`, `.arriWideGamut4` (with `luminanceCoefficients` and `conversion(to:)`) |
| `ColorPrimaries`, `ColorMatrix`, `Chromaticity`, `ColorRGB` | `.rec709`, `.displayP3`, `.rec2020`; RP 177 `toXYZ`, `conversion(to:)`, `luminanceCoefficients` |

```swift
import MonitorKitCore

/// A 10-bit legal S-Log3 / S-Gamut3.Cine camera, its codes carried as recorded.
func sLog3Camera() -> SignalDescription {
  SignalDescription(range: .legal, matrix: .bt709, encoding: .log(.sLog3SGamut3Cine))
}

/// An HLG camera labelled with BT.709 primaries keeps them: primaries are read
/// independently of the transfer.
func hlgOn709() -> SignalDescription {
  SignalDescription(range: .legal, matrix: .bt709, encoding: .display(.hlg), primaries: .rec709)
}
```

### 2.3 Geometry

| Type | Purpose |
| --- | --- |
| `MonitorFrameGeometry` | A frame's shape without pixels: `width`, `height`, `pixelAspectRatio`, `cleanAperture`. `shownRect`, `effectivePixelAspectRatio`, `hasUsablePixelAspectRatio`, `displayAspectRatio(desqueeze:)`, `displayAspectRatio(for:)`; `pixelAspectRatioRange` (1/16…16) |
| `MonitorLayout` | Where the picture lands in a viewport: `fitRect`, `imageRect`, `visiblePictureRect`, `navigatorRect`, `displayToPicture` / `navigatorToPicture` (`AxisMap`), `isMagnified`, `aperture`, `pictureWidth` / `pictureHeight` (the aperture's size), `footprintX` / `footprintY`. The maps return frame pixels (with an aperture the shown picture starts at `aperture.x`, not 0); `pictureFraction(x:y:)`, `picturePoint(fractionX:fractionY:)` and `pictureFraction(displayX:displayY:)` convert to and from fractions of the aperture, the coordinates of `Magnification.centerX`/`centerY`. `init(frame:state:viewportWidth:viewportHeight:)` and the lower-level `init(pictureWidth:pictureHeight:pixelAspectRatio:viewportWidth:viewportHeight:geometry:cleanAperture:)` |
| `MonitorRect`, `AxisMap` | Rectangles and display-to-picture maps (`AxisMap.display(_:toPicture:flip:)`) |
| `GuideRaster` | The guide strokes and matte of a layout, as `MonitorPass` draws them |

```swift
import MonitorKitCore

/// The display aspect of a 1920 × 1080 aperture in a 2048 × 1080 frame shot with a 2× anamorphic.
func anamorphicAspect() -> Double {
  let geometry = MonitorFrameGeometry(
    width: 2048, height: 1080, cleanAperture: MonitorRect(x: 64, y: 0, width: 1920, height: 1080))
  var state = MonitorState()
  state.geometry.desqueeze = 2
  return geometry.displayAspectRatio(for: state)  // 3.56
}

/// Hit testing on the main thread: the picture pixel under a click, in frame pixels.
func picturePoint(atViewX x: Double, y: Double, geometry: MonitorFrameGeometry, state: MonitorState,
                  viewportWidth: Int, viewportHeight: Int) -> (x: Double, y: Double) {
  let layout = MonitorLayout(frame: geometry, state: state, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
  return layout.displayToPicture.apply(x: x, y: y)
}
```

### 2.4 LUT parsing

`CubeLUT(text:fallbackTitle:)` parses Adobe/Resolve `.cube` text: 3D tables 2³…65³, 1D tables and shapers up to 65 536 entries (`maximumShaperSize`), domains and input ranges. It throws `CubeLUT.ParseError`. `apply(_:interpolation:)` and `applyShaper(_:)` are the CPU references of the GPU sampler. Properties: `title`, `dimension`, `domainMin`, `domainMax`, `rgba`, `shaper`, `shaperSize`, `hasCube`, `data`.

```swift
import Foundation
import MonitorKitCore

func loadCube(at url: URL) throws -> CubeLUT {
  try CubeLUT(text: String(contentsOf: url, encoding: .utf8), fallbackTitle: url.deletingPathExtension().lastPathComponent)
}

func middleGrey(through cube: CubeLUT) -> SIMD3<Float> { cube.apply(SIMD3(0.41, 0.41, 0.41)) }
```

### 2.5 Output colour

| Type | Purpose |
| --- | --- |
| `MonitorOutputColor` | What the target's values mean: `encoding` (`.signalNative`, `.sdr(SDRTransfer)`, `.extendedLinear`, `.pq`, `.hlg`), `primaries`, `referenceWhite`, `hlgNominalPeak`, `headroom`. `.signalNative`, `normalized()`, `withoutHeadroom`, `recommended(for:displayTransform:monitorStageHasLUT:)`, `layer(for:displayTransform:monitorStageHasLUT:)` |
| `MonitorLayerColor` | How to configure the layer: `primaries`, `kind`, `pixelFormat`, `wantsExtendedDynamicRange`, `colorSpace` (`ColorSpace`, the `kCGColorSpace…` name), `edrMetadata` (`EDRMetadata`). MonitorKitUI adds `apply(to:)` |
| `MonitorColorPipeline` | The resolved colour path of a surface (for diagnostics and the CPU reference): `status`, `picture`, `target`, `convertsToTarget`, `overlayColor(_:)`, `present(_:range:bitDepth:headroom:)` |

```swift
import MonitorKitCore

/// The layer a PQ camera's signal-native picture wants: rgba16Float, ITU-R BT.2100 PQ, EDR, HDR10 metadata.
func layerForPQCamera() -> MonitorLayerColor {
  let signal = SignalDescription(range: .legal, matrix: .bt2020, encoding: .display(.pq), primaries: .rec2020)
  return MonitorOutputColor.signalNative.layer(for: signal)
}
```

### 2.6 Reference math

Public so hosts and tests can reproduce what the GPU draws: `ColorMath` (Y'CbCr, transfers, S-Log3, PQ, HLG, BT.1886), `DecodeReference`, `DisplayAssist`, `HDRToSDR`, `ToneMapEETF`, `WhitePointTrim`, `SonySLog3FalseColor`, `SonyARRIStyleFalseColor`, `ARRIFalseColorProfile`, `ELZoneProfile`, `ELZonePublicReference`, `SixBandFalseColor`, `FalseColorBands`, `FalseColorTable` (`measure(for:)`, `bands(for:arriCurve:arriFullRange:)`, `usesFullRangeARRI(signal:layout:)`). Their constants and sources are in [MATH.md](MATH.md).

## 3. MonitorKit

The picture pass, analysis, LUTs, Freeze and the Metal 4 types. Shaders: `MKLUT.msl`, `MKDecode.msl`, `MKMonitor.msl` (resources, compiled at runtime).

### 3.1 `MonitorEngine`

One per GPU, shared by every feed and surface (`Sendable`).

| Member | Meaning |
| --- | --- |
| `init(device:specialization:framesInFlight:compiler:)` | Compiles the library. `specialization`: `.asynchronous` (default: draw with the all-tools pipeline while the specialized one builds on Metal's compiler threads), `.synchronous`, `.off`. `framesInFlight` (default 3, 1…16) sizes the Metal 4 uniform rings. `compiler`: a Metal 4 host's `MTL4Compiler`; nil lets the device build |
| `init(device:specialization:framesInFlight:compiler:cacheDirectory:)` | The same with a persistent warm start (`MonitorPipelineArchive`, 3.12) in `cacheDirectory`, e.g. a subdirectory of the host's `.cachesDirectory` (made by the first save). The engine then builds with the archive's own `MTL4Compiler` (a host `compiler` is unused), looks each pipeline up in the files earlier launches saved, and saves new ones. Nil: no cache |
| `device`, `specialization`, `framesInFlight`, `compiler` | `compiler`: the one the engine builds with (the archive's with a `cacheDirectory`) |
| `pipelineArchive` | The `MonitorPipelineArchive` of an engine made with a `cacheDirectory`, else nil |
| `residency` | A `MonitorResidency`: attach `residency.set` to your `MTL4CommandQueue` once |
| `warmUp(targets:layouts:surfaces:save:) -> Int` | Builds every pipeline a first frame could need, on the calling thread (call it at start-up, off the frame path). Default targets: `standardTargetFormats` (`bgr10a2Unorm`, `rgba16Float`, `bgra8Unorm`); `surfaces`: `MonitorSurfaceConfiguration`s for the exact specialized pipelines (a surface's `signal` with a distinct `outputReading` warms the pipeline with the second decode when a tool reads the Output or Monitor stage). With a `pipelineArchive`, saves it before returning unless `save` (default true) is false: warm several engines with `save: false`, then call `pipelineArchive?.save()` on each |
| `prepare(pixelFormat:layouts:)`, `prepare(target:layouts:)`, `prepareCompute(pixelFormat:layouts:…)` | Narrower warm-ups: all-tools pipelines, focus kernels, Freeze kernels |
| `makeFeed()`, `makePass()` | |
| `resourcesCreated`, `pipelinesBuilt` | Counters for tests and diagnostics; constant in steady state |

`MonitorSurfaceConfiguration(target:layout:state:signal:outputColor:hasBurnInLUT:hasMonitorLUT:frameSize:viewportSize:compute:pixelAspectRatio:cleanAperture:)` describes a surface to warm up. Frame and viewport size, pixel aspect ratio and clean aperture decide the filter (a magnified picture interpolates); with either size nil both filter variants are built.

```swift
import Metal
import MonitorKit

/// At start-up, on a background task: the all-tools pipelines for the three layer
/// formats, plus the exact pipeline the default S-Log3 surface draws with.
func warmUp(_ engine: MonitorEngine) throws -> Int {
  var state = MonitorState()
  state.falseColor.mode = .sonySLog3
  let surface = MonitorSurfaceConfiguration(
    target: MonitorRenderTargetFormat(colorPixelFormat: .bgr10a2Unorm), layout: .v210, state: state,
    signal: SignalDescription(encoding: .log(.sLog3SGamut3Cine)))
  return try engine.warmUp(layouts: [.v210, .p210], surfaces: [surface])
}
```

### 3.2 `MonitorFrame`

One borrowed video frame: textures plus a layout and a signal. Allocation-free to build.

| Member | Meaning |
| --- | --- |
| `init(layout:width:height:packed:luma:chroma:signal:pixelAspectRatio:cleanAperture:)` | From your textures (formats below); throws when they do not match the layout or the aperture is not inside the frame |
| `wrap(_:cache:signal:)` | From an IOSurface `CVPixelBuffer` through a `CVMetalTextureCache` (signal, pixel aspect and clean aperture from the attachments; `signal` overrides) |
| `layout(for:)`, `signal(of:range:)`, `cleanAperture(of:)`, `geometry(of:)` | CoreVideo helpers, allocation-free |
| `id` | Fresh per frame; what the focus mask belongs to. Set a new one if you reuse a value for another picture |
| `layout`, `width`, `height`, `signal`, `pixelAspectRatio`, `cleanAperture`, `isProcessed`, `geometry` | `isProcessed`: not the camera's own signal (a programme mix, a scaled or graded render): log false colour and peaking are then unavailable |
| `packed`, `luma`, `chroma`, `parameters` | The textures and the `FrameParameters` (`mk_FrameParams`, the source reading) a fused kernel binds |
| `parameters(for: SignalStage)` | That stage's `FrameParameters`: the source reading at `.source`, `signal.effectiveOutputReading` at `.output` and `.monitor`. A kernel that measures one stage binds these |
| `addResidency(to:)`, `removeResidency(from:)`, `keepResidentIfReleased(in:)` | Metal 4 residency of host frames (once per texture, not per frame) and of released frozen frames |

| Layout | Plane | Texture format | Size |
| --- | --- | --- | --- |
| `.v210` (`'v210'`) | `packed` | `rgba32Uint` | ⌈w/6⌉ × h |
| `.uyvy8` (`'2vuy'`), `.yuyv8` (`'yuvs'`) | `packed` | `rgba8Uint` | ⌈w/2⌉ × h |
| `.biplanar(_, bitDepth: 8)` | `luma`, `chroma` | `r8Unorm`, `rg8Unorm` | w × h, chroma subsampled |
| `.biplanar(_, bitDepth: 10 or 16)` | `luma`, `chroma` | `r16Unorm`, `rg16Unorm` (high-aligned, not `r16Uint`) | as above |
| `.bgra8` | `luma` | `bgra8Unorm` or `rgba8Unorm` | w × h |
| `.rgb10a2` | `luma` | `bgr10a2Unorm` or `rgb10a2Unorm` | w × h |
| `.rgb(bitDepth: 16, float: false)` | `luma` | `rgba16Unorm` | w × h |
| `.rgba16Float`, `.rgba32Float` | `luma` | `rgba16Float`, `rgba32Float` | w × h |

Chroma planes are ⌈w/2⌉ wide for 4:2:0 and 4:2:2, ⌈h/2⌉ high for 4:2:0. Textures need `.shaderRead` and any storage mode; they are read, never sampled.

```swift
import CoreVideo
import Metal
import MonitorKit

/// A host-built frame over textures you already have (e.g. a resident IOSurface cache).
func p210Frame(luma: MTLTexture, chroma: MTLTexture, width: Int, height: Int) throws -> MonitorFrame {
  try MonitorFrame(
    layout: .p210, width: width, height: height, luma: luma, chroma: chroma,
    signal: SignalDescription(range: .legal, matrix: .bt709, encoding: .log(.sLog3SGamut3Cine)))
}

/// A programme feed: shown with every tool except those that need the camera's own signal.
func programmeFrame(_ pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) throws -> MonitorFrame {
  var frame = try MonitorFrame.wrap(pixelBuffer, cache: cache)
  frame.isProcessed = true
  return frame
}
```

### 3.3 `MonitorTextureCache`

IOSurface-keyed plane textures, made once per surface, plane, format and size, added to a `MonitorResidency` once and retired after `idleLifetime` seconds unused (or on `flush(owner:)`, `removeAll()`, deinit) once the submissions that may read them complete. The Metal 4 replacement for a per-frame `CVMetalTextureCache`; capture pools recycle a few surfaces, so the steady state makes no texture and changes no residency. `Sendable`.

| Member | Meaning |
| --- | --- |
| `init(device:residency:idleLifetime:capacity:)` | Pass `MonitorEngine.residency`. `idleLifetime` default 2 s (0.1…3600) |
| `frame(_:signal:owner:now:) -> MonitorFrame` | The pixel buffer as a frame, formatted as `wrap` does; the frame retains the pixel buffer |
| `makeTexture(iosurface:plane:format:width:height:owner:now:)` | One plane |
| `sweep(now:)`, `flush(owner:)`, `removeAll()` | Release idle textures, an owner's (a camera that stopped), or all |
| `count`, `count(owner:)`, `texturesMade`, `idleLifetime`, `sweepInterval`, `uptime()` | |

### 3.4 `MonitorLUT`

A LUT on the GPU: one `rgba32Float` 3D texture (with the 1D shaper in further slices), built once per load, immutable and shareable across feeds and threads.

| Member | Meaning |
| --- | --- |
| `init(device:cube:interpolation:outputEncoding:)` | `interpolation` default `.tetrahedral`; `.hardware` falls back to `.trilinear` without 32-bit float filtering. `outputEncoding` default `.rec709` (the only one modelled) |
| `cube`, `texture`, `interpolation`, `parameters` (`LUTParameters`, `mk_LUTParams`), `outputEncoding`, `memoryBytes` | |

`LUTParameters.disabled` passes RGB through unchanged.

### 3.5 `MonitorFeed`

One per video feed (confined): its LUTs and its once-per-frame analysis, shared by every surface of the feed.

| Member | Meaning |
| --- | --- |
| `burnInLUT`, `monitorLUT` | The output-stage and monitor-stage LUTs (`MonitorLUT?`) |
| `analyze(_:focus:into:)` | Once per frame, before passes that show peaking. Classic `MTLCommandBuffer`, `MonitorSubmission`, or `(_:focus:submission:encoder:)` in your `MTL4ComputeCommandEncoder`. With `focus.enabled` false it encodes nothing and releases the mask; an unchanged frame and settings encode nothing |
| `hasFocusMask(for:)`, `invalidateFocusMask()`, `focusMask`, `analysisCount` | |
| `monitorStageHasLUT(for:)` | Whether a surface with this state shows a LUT result (it follows `pictureStage`): the `monitorStageHasLUT` argument for layer tagging |
| `freeze(_:into:) -> MonitorFrame`, `frozenFrame`, `unfreeze(keepingMemory:)` | Freeze: one compute copy into feed-owned planes, classic or Metal 4 |
| `updateResidency()` | Metal 4: before other Metal 4 work reads the feed's LUTs outside MonitorKit |
| `persistentMemoryBytes`, `retiredMemoryBytes`, `releaseRetired()`, `retiredFrames`, `uniformLength` (1024) | Memory, and the classic retirement of replaced masks |

### 3.6 `MonitorPass`

One per surface (confined): draws a feed's frame with this surface's tools.

| Member | Meaning |
| --- | --- |
| `encode(frame:feed:state:target:viewport:clear:into:)` | Its own render pass into `target` (a drawable, `framebufferOnly` included, or any texture). Classic or `MonitorSubmission` |
| `prepare(frame:feed:state:viewport:target:into:)` then `draw(with:)` | Inside your render pass (depth, stencil, MSAA and further attachments described by `MonitorRenderTargetFormat`). `prepare(…, targetPixelFormat:into:)` for a single attachment; Metal 4: `prepare(…, target:submission:)` and `draw(with: any MTL4RenderCommandEncoder)` |
| `encodeCompute(frame:feed:state:target:viewport:sharesTarget:into:)` | Metal 4: a compute kernel writes the viewport of a shader-writable, non-sRGB target (also in your compute encoder) |
| `outputColor` | `MonitorOutputColor`, default `.signalNative` |
| `status` | `MonitorStatus` after the last prepare |
| `layout`, `colorPipeline`, `usesSpecializedPipeline` | `colorPipeline`: share it with a `ScopeRenderer` drawn into the same layer |
| `persistentMemoryBytes`, `uniformLength` (5120), `rebuildCount`, `statusRebuildCount`, `guideBuildCount`, `currentParameters`, `currentGuides` | Diagnostics |

`MonitorViewport(x:y:width:height:pixelsPerPoint:)` is where a surface draws in target pixels; `pixelsPerPoint` (0.25…16) scales guide strokes and zebra stripes. `MonitorRenderTargetFormat(colorPixelFormat:depthPixelFormat:stencilPixelFormat:sampleCount:additionalColorPixelFormats:)`, or `MonitorRenderTargetFormat(passDescriptor)`, describes your pass. `MonitorLayout(frame:state:viewport:)` is the layout the pass will use, on any thread.

```swift
import Metal
import MonitorKit

/// Inside your own render pass: prepare before the encoder starts, draw inside it.
/// `draw` sets its own pipeline, viewport, scissor and bindings (fragment textures 0–5,
/// buffers 0–4), so rebind yours afterwards.
func drawInHostPass(
  pass: MonitorPass, frame: MonitorFrame, feed: MonitorFeed, state: MonitorState,
  descriptor: MTLRenderPassDescriptor, viewport: MonitorViewport, commandBuffer: MTLCommandBuffer
) throws {
  try pass.prepare(
    frame: frame, feed: feed, state: state, viewport: viewport, target: MonitorRenderTargetFormat(descriptor),
    into: commandBuffer)
  guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
  // … your own draws …
  try pass.draw(with: encoder)
  encoder.endEncoding()
}
```

### 3.7 `MonitorMultiview`

Several surfaces in one render pass into one target: one clear (or load) and one store of the attachment, bit-identical to a pass per surface. Classic and Metal 4. Each surface keeps its own `MonitorPass`.

```swift
import Metal
import MonitorKit

func drawSideBySide(
  multiview: MonitorMultiview, left: MonitorPass, right: MonitorPass, a: MonitorFrame, feedA: MonitorFeed,
  b: MonitorFrame, feedB: MonitorFeed, state: MonitorState, target: MTLTexture, commandBuffer: MTLCommandBuffer
) throws {
  let half = target.width / 2
  try multiview.encode(target: target, into: commandBuffer) { canvas in
    try canvas.draw(left, frame: a, feed: feedA, state: state, viewport: MonitorViewport(width: half, height: target.height))
    try canvas.draw(
      right, frame: b, feed: feedB, state: state,
      viewport: MonitorViewport(x: half, y: 0, width: target.width - half, height: target.height))
  }
}
```

### 3.8 `MonitorStatus`

Why a tool that is on is not drawn, and what is shown. Rebuilt only when the state, signal or feed changes.

| Member | Meaning |
| --- | --- |
| `active` (`[Entry]`: `tool`, `label`, `isProvisional`), `activeLabels`, `isActive(_:)` | e.g. "Sony S-Log3", "Zebra 1 · 95+ IRE", "Source · S-Log3 code values" |
| `unavailable` (`[Unavailable]`: `tool`, `reason`), `reason(for:)` | `MonitorUnavailableReason` (see [FEATURES §9](FEATURES.md#9-why-a-tool-is-not-drawn)); `description` is user-facing text |
| `pictureStage`, `isCodeValueView`, `codeValueViewNote` | |

`MonitorTool` lists the tools: `falseColor`, `zebra1`, `zebra2`, `focusPeaking`, `guides`, `burnInLUT`, `monitorLUT`, `magnification`, `desqueeze`, `flip`, `displayAdjustments`, `displayTransform`, `clipIndicators`, `picture`.

```swift
import MonitorKit

func statusLine(_ pass: MonitorPass) -> String {
  var parts = pass.status.activeLabels
  for entry in pass.status.unavailable { parts.append("\(entry.tool.rawValue): \(entry.reason)") }
  return parts.joined(separator: " · ")
}
```

### 3.9 Freeze

```swift
import Metal
import MonitorKit

/// Freeze returns a frame that works wherever a live one does (passes, analysis, scopes).
/// It is the only frame copy MonitorKit makes, and only on request.
func freeze(_ live: MonitorFrame, feed: MonitorFeed, commandBuffer: MTLCommandBuffer) throws -> MonitorFrame {
  try feed.freeze(live, into: commandBuffer)
}

/// Draw `feed.frozenFrame` until the user unfreezes; the planes are released by default.
func unfreeze(_ feed: MonitorFeed, togglesOften: Bool) {
  feed.unfreeze(keepingMemory: togglesOften)
}
```

### 3.10 Metal 4 types

| Type | Purpose |
| --- | --- |
| `MonitorSubmission` | One host command buffer: `commandBuffer` (`any MTL4CommandBuffer`), `index` (≥ 1, shared by every encode into it), `completedIndex` (the highest *contiguous* completed index), `uniforms` (an optional host allocator). `init(commandBuffer:index:completedIndex:uniforms:)`, or `init(commandBuffer:index:framesInFlight:uniforms:)` for a host that never has more than `framesInFlight` submissions in flight |
| `MonitorUniformAllocator`, `MonitorUniformAllocation` | Your transient uniform memory: `allocateUniforms(length:)` returns 256-byte-aligned, resident memory valid until the submission completes. Sizes: `MonitorPass.uniformLength` 5120, `MonitorFeed.uniformLength` 1024, `ScopeAccumulator.uniformLength` 1280, `ScopeGroup.uniformLength` 2048, `ScopeRenderer.uniformLength` 768 and `graticuleUniformLength` 2304 |
| `MonitorResidency` | The residency set of everything MonitorKit owns, with deferred release: `set`, `add(_:)`, `retire(_:resident:after:)`, `observe(_:)`, `release(through:)`, `contains(_:)`, `latestSubmission`, `completedSubmission`, `pendingReleaseCount`, `commitCount`. Thread-safe |
| `MonitorUniformRing` | A noncopyable ring of uniform slots, the library's default when `uniforms` is nil; public for hosts building their own encoders |

```swift
import Metal
import MonitorKit

/// A bump allocator over one shared buffer, reset when its command buffer is reused.
final class BumpUniforms: MonitorUniformAllocator {
  let buffer: MTLBuffer
  private var offset = 0

  /// `residency` is a set on your queue; size from the uniformLength constants.
  init?(device: MTLDevice, residency: MTLResidencySet, length: Int = 32 * 1024) {
    guard let buffer = device.makeBuffer(length: length, options: [.storageModeShared, .cpuCacheModeWriteCombined])
    else { return nil }
    self.buffer = buffer
    residency.addAllocation(buffer)
    residency.commit()
  }

  func reset() { offset = 0 }

  func allocateUniforms(length: Int) -> MonitorUniformAllocation {
    precondition(offset + length <= buffer.length, "size the allocator from the uniformLength constants")
    let allocation = MonitorUniformAllocation(
      contents: buffer.contents() + offset, gpuAddress: buffer.gpuAddress + UInt64(offset))
    offset += (length + 255) / 256 * 256
    return allocation
  }
}
```

### 3.11 `MonitorShaders`

| Member | Meaning |
| --- | --- |
| `Part` | `.lut` (`MKLUT.msl`: `mk_LUTParams`, `mk_applyLUT`), `.decode` (`MKDecode.msl`: `mk_FrameParams`, `mk_decodeRGB`, `mk_decodeLuma`, `mk_nativeLog`), `.monitor` (`MKMonitor.msl`) |
| `source(_:)` | The parts' text as one compilation unit |
| `compileOptions` | Safe math, MSL 4.0 (4.1 on macOS/iOS 27): compile fused kernels with these for identical results |
| `makeLibrary(device:parts:prefix:extra:)`, `libraryDescriptor(parts:prefix:extra:name:)` | For the device or an `MTL4Compiler` |
| `lutLayoutVersion` | 2: the 80-byte `mk_LUTParams` with a shaper. `MKLUT.msl` and `MKDecode.msl`, the parts a host prepends, are each guarded as a whole file (included twice, compiled once); an older `MKLUT.msl` copy in the same source fails to compile |

`FrameParameters` (80 B) and `LUTParameters` (80 B) mirror the MSL structs; `PassParameters` and `GuideParameters` are the picture pass's uniforms (public for diagnostics; never hand-size them).

### 3.12 `MonitorPipelineArchive`

The persistent warm start of `MonitorEngine(…, cacheDirectory:)` and `ScopeEngine(…, cacheDirectory:)` (`Sendable`, thread-safe). Engines make it; hosts read its counters and may call `save()`.

| Member | Meaning |
| --- | --- |
| `statistics` (`Statistics`) | `filesLoaded` (verified files opened: the newest at init, older ones at the first pipeline it lacks, or written since), `filesRejected` (damaged files of this key, removed), `staleFilesRemoved` (other keys' files on this GPU, removed by a save), `hits`, `misses` (compiled, recorded for the next save), `saves`, `lastError` |
| `files` | The archive files in use for lookups, newest first |
| `save() -> Bool` | When something was compiled since the last save: records the whole session with a second compiler (its `MTL4PipelineDataSetSerializer`) and writes a new file, then removes this GPU's stale and surplus files. Blocks for the file I/O (tens to a few hundred milliseconds): never on a frame. A no-op otherwise. A failure is in `statistics.lastError`, and the next save retries |
| `saveDelay` | 2 s: pipelines built after warm-up are saved this long after the last one, from a utility-priority task |
| `directory`, `name`, `key`, `maximumFiles` | `name`: `MonitorKit` or `MonitorKitScopes`; `key`: hex SHA-256 of the identity below; `maximumFiles`: 3 per key |

Files are `<name>-<gpu>-<key>-<content>.mtl4archive`: `gpu` hashes `MTLDevice.name` and the architecture, `key` the exact shader source, compile options, GPU, OS version and build, Metal validation settings and the format version, so an archive of other shaders, another OS build or GPU is never opened; `content` hashes the file's bytes, checked before Metal reads them. Each save holds every pipeline of the session, so the newest file holds what the last launch used. A pipeline is returned from an archive only when its whole descriptor matches, so pixels are identical with or without a cache. The directory is the host's: only files with the engine's prefix are touched. Under `MTL_SHADER_VALIDATION` no archive is written (Metal cannot load the instrumented binaries it records; `save()` returns false with the reason in `lastError`), so a validated session builds as without a cache.

```swift
import Foundation
import Metal
import MonitorKit
import MonitorKitScopes

/// Both engines warm-start from one caches subdirectory; each archive is saved once,
/// after both are warm.
func makeEngines(device: MTLDevice) throws -> (MonitorEngine, ScopeEngine) {
  let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
  let directory = caches.appendingPathComponent("MonitorKit pipelines", isDirectory: true)
  let engine = try MonitorEngine(device: device, cacheDirectory: directory)
  let scopes = try ScopeEngine(device: device, residency: engine.residency, cacheDirectory: directory)
  try engine.warmUp(save: false)
  try scopes.prepare(save: false)
  engine.pipelineArchive?.save()
  scopes.pipelineArchive?.save()
  return (engine, scopes)
}
```

## 4. MonitorKitScopes

### 4.1 `ScopeEngine`

Compiled scope kernels and render pipelines for one device (`Sendable`).

| Member | Meaning |
| --- | --- |
| `init(device:specialization:framesInFlight:residency:)` | Pass `MonitorEngine.residency` so one set covers both |
| `init(device:specialization:framesInFlight:residency:cacheDirectory:)` | The same with a persistent warm start in `cacheDirectory` (it may be the `MonitorEngine`'s: files are named per engine kind); `pipelineArchive` is then set |
| `prepare(pixelFormats:save:)` | Warm-up of the render pipelines for `drawablePixelFormats` (`bgr10a2Unorm`, `rgba16Float`, `bgra8Unorm`) by default. An asynchronous engine draws nothing into a format until its pipeline is built. Saves the archive before returning unless `save` is false |
| `prepare(pixelFormat:)`, `prepare(target:)`, `prepare(settings:layouts:pixelFormats:save:)` / `(…pixelFormat:)` / `(…target:)`, `isPrepared(target:)`, `isPrepared(pixelFormat:)` | `prepare(target:)` and the single-format forms leave the save to the scheduled one |
| `makeAccumulator(settings:)`, `makeGroup(_:)`, `makeRenderer()` | |
| `pipelineBuildFailures`, `library`, `scopeSource()` | |

### 4.2 `ScopeAccumulator`, `ScopeGroup`, `ScopeRenderer`

| Type | Purpose |
| --- | --- |
| `ScopeAccumulator` | Persistent bins for one scope. `accumulate(_:feed:monitorLUTEnabled:into:)` (classic `MTLCommandBuffer` or `MonitorSubmission`), `accumulate(_:burnInLUT:monitorLUT:into:)`, and host-encoder overloads (`using:` classic, `submission:encoder:` Metal 4). `settings`, `accumulatedSettings`, `hasData`, `generation`, `layout` (`ScopeBinLayout`), `bins`, `statistics`, `statisticsReader`, `graticule(width:height:display:)`, `prepareMetal4()`, `persistentMemoryBytes`, `uniformLength` |
| `ScopeGroup` | One fused pass for a stage's waveform, histogram and vectorscope (each pixel decoded once); other members accumulate on their own in the same encoder. Same `accumulate` overloads; `isFused(_:)`, `fusedMemberCount`, `prepare(layouts:)`, `prepareMetal4()`, `uniformLength` |
| `ScopeRenderer` | Draws an accumulator with its graticule into any target. `render(_:display:target:viewport:clear:into:)`, `prepare(_:display:viewport:target:into:)` / `(…submission:)` then `draw(with:)`. `colorPipeline` (set it to `MonitorPass.colorPipeline` on a shared HDR layer) or `setOutputColor(_:signal:displayTransform:monitorStageHasLUT:)`; `isReady`, `graticule`, `graticuleTexture`, `traceTexture`, `prepareMetal4()`, `uniformLength`, `graticuleUniformLength` |
| `ScopeStatisticsReader`, `ScopeStatistics` | Any-thread reads of `generation`, `pixelCount`, `lumaMinimum` / `lumaMaximum` / `lumaAverage`, `clippedHigh` / `clippedLow` (R, G, B, luma), `histogramPeak` |
| `ScopeSettings`, `ScopeDisplay` and their enums | [FEATURES §3](FEATURES.md#3-scopes). `ScopeSettings.ultracamLegacy(mode:stage:)`, `accumulationKey` |
| `ScopeGraticule`, `ScopeLabel`, `ScopeTick`, `VectorscopeTarget`, `ScopeContext`, `ScopeLevelAxis`, `ScopeLevelRange`, `ScopeTransfer`, `VectorscopeGeometry`, `WaveformScale.ticks(range:levelRange:)` | Graticule geometry and labels, for a UI drawing its own text |

```swift
import Metal
import MonitorKit
import MonitorKitScopes

final class Scopes {
  let group: ScopeGroup
  let waveform: ScopeAccumulator
  let vectorscope: ScopeAccumulator
  let renderer: ScopeRenderer

  init(engine: ScopeEngine) throws {
    var parade = ScopeSettings(kind: .waveform, stage: .output)
    parade.waveformMode = .rgbParade
    waveform = try engine.makeAccumulator(settings: parade)
    vectorscope = try engine.makeAccumulator(settings: ScopeSettings(kind: .vectorscope, stage: .output))
    group = try engine.makeGroup([waveform, vectorscope])
    renderer = engine.makeRenderer()
  }

  /// At the host's scope rate: accumulate, then draw over the picture (`clear` false composites).
  func update(_ frame: MonitorFrame, feed: MonitorFeed, target: MTLTexture, viewport: MonitorViewport,
              commandBuffer: MTLCommandBuffer) throws {
    try group.accumulate(frame, feed: feed, into: commandBuffer)
    try renderer.render(waveform, target: target, viewport: viewport, into: commandBuffer)
  }

  /// From any thread, e.g. a UI timer: no GPU readback on the frame path.
  func clippedHighPercent() -> Double? {
    waveform.statisticsReader.statistics.map { $0.clippedHigh.w * 100 }
  }
}
```

## 5. MonitorKitAudio

Pure Swift and Accelerate. Realtime-safe: everything is allocated at init; `process` makes no heap allocation, takes no lock and uses no Swift concurrency.

| Type | Purpose |
| --- | --- |
| `AudioMeter` | `init(configuration:)`, `init(sampleRate:channelCount:)` (throws `AudioMeterError`). `process(planar:frameCount:)` (Float32, Int16, Int32 pointers), `process(interleaved:frameCount:frameStride:)`, `process(bufferList:frameCount:format:)`; `snapshot()`, `publishCount`, `resetPeaks()`, `resetLoudness()`, `reset()`, `pauseLoudness()`, `resumeLoudness()`, `isLoudnessPaused`, `flush()` |
| `AudioMeterConfiguration` | [FEATURES §8](FEATURES.md#8-audio); `ppmBallistics`, `loudnessChannels` |
| `AudioMeterSnapshot` | `sequence`, `frameCount`, `channelCount`, `channels` (`InlineArray<16, AudioChannelLevels>`, or `snapshot[channel:]`), `loudness` (`LoudnessSnapshot`), `programmeChannelMask`, `maximumTruePeak`, `programmeMaximumTruePeak` (R 128 Max TP), `vuReferenceDBFS`, `ppmAlignmentDBFS` |
| `AudioChannelLevels`, `LoudnessSnapshot` | dBFS / dBTP / VU / PPM readings, clip count; M, S, I, LRA, maxima, duration |
| `LoudnessMeter` | Loudness alone: `init(sampleRate:channels:)`, the same `process` overloads, `snapshot()`, `resetMeasurement()`, `reset()`, `pauseMeasurement()`, `resumeMeasurement()` |
| `AudioMeterKinds`, `AlignmentLevel`, `PPMType`, `PPMBallistics`, `VUBallistics`, `RMSScale`, `LoudnessChannel`, `AudioSampleFormat`, `audioMeterMaximumChannelCount` | Configuration values |
| `MeterScale`, `MeterScaleMark`, `MeterZone`, `MeterZoneKind`, `MeterScaleUnit`, `MeterScaleMapping`, `MeterScalePoint`, `LoudnessScaleRange` | Marks and zones: `digitalPeak(unit:range:alignment:maximumPeak:)`, `vu`, `ppm(_:)`, `ppmNordic`, `loudness(_:unit:target:)`; `position(of:)`, `zone(of:)` |
| `Biquad`, `KWeighting` | The BS.1770 K-weighting filters at any rate |

```swift
import AVFAudio
import MonitorKitAudio

/// Meters on an audio engine's tap: `process` on the audio thread, `snapshot()` from the UI.
func installMeter(on engine: AVAudioEngine) throws -> AudioMeter {
  let input = engine.inputNode
  let format = input.outputFormat(forBus: 0)
  let meter = try AudioMeter(sampleRate: format.sampleRate, channelCount: Int(format.channelCount))
  input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    guard let channels = buffer.floatChannelData else { return }
    meter.process(planar: channels, frameCount: Int(buffer.frameLength))
  }
  return meter
}

/// R 128 readouts: integrated loudness and the programme's maximum true peak.
func loudnessReadout(_ meter: AudioMeter) -> (integrated: Float, maxTruePeak: Float) {
  let s = meter.snapshot()
  return (s.loudness.integrated, s.programmeMaximumTruePeak)
}
```

## 6. MonitorKitUI

The batteries-included tier. It is the one exception to "the library creates no queue and commits nothing": a convenience-mode view makes a command queue when you give it none and commits its own command buffers.

### 6.1 Scene handles

| Type | Purpose |
| --- | --- |
| `MonitorSource` | A display slot for one source, latest frame wins: `submit(_:)` from any thread (never waits), `clear()`, `latestFrame`, `sequence`, `burnInLUT`, `monitorLUT`, `setLUT(_:routing:)` |
| `MonitorSurface` | One picture of a source in a view: `init(source:state:region:)`, `state`, `updateState(_:)`, `region`, and (published after drawing) `status`, `layout`, `viewport` |
| `MonitorScopeOverlay` | One scope of a source: `init(source:settings:region:monitorLUTEnabled:isHidden:accumulationInterval:)`, `settings`, `region`, `isHidden` (measured, not drawn), `accumulationInterval` (the scope rate; 0 every new frame), `statisticsReader`, `graticule`, `viewport` |
| `MonitorScene` | What a view draws: `surfaces`, `scopes`, `outputColor`, `clean`, `headroom` |
| `MonitorRegion` | A normalized rectangle of the view (`.full`), `viewport(width:height:pixelsPerPoint:)` |

### 6.2 Rendering

| Type | Purpose |
| --- | --- |
| `MonitorRenderer` | Draws a scene into any texture, classic or Metal 4 (confined). Per tick: `update()`, `needsDisplay(width:height:pixelFormat:)`, then `encode(target:into:)`, or `encodePictures(target:into:)` and `encodeScopes(into:)` in a later command buffer so pictures never wait for scopes. `noteCompleted(through:)`, `releaseIdleResources()`, `layerColor`, `headroom`, `pixelsPerPoint`, `displayHeadroom`, `scopesDue`, `takeStatusChanges()`, `takeGraticuleChanges()`, per-handle accessors (`pass(for:)`, `feed(for:)`, `accumulator(for:)`, `scopeRenderer(for:)`, `scopeGroup(for:)`), `sharedScopeEngine(for:)`, `lastError`, `errorCount`, `persistentMemoryBytes` |
| `MonitorMetalView` | A `CAMetalLayer` view (`NSView` / `UIView`, `@MainActor`) drawing a scene on a `CAMetalDisplayLink`: `init(engine:scene:mode:configuration:scopeEngine:displayLinkRunLoop:)`. `MonitorMetalViewMode.convenience(queue:)` or `.hostDriven { context in … }` (you encode with `MonitorDrawableContext` and present). `isPaused`, `headroomOverride`, `layerColorOverride`, `onSurfaceStateChange`, `onStatusChange`, `onGraticuleChange`, `onError`, `drawOffscreen(into:commandBuffer:)`, `completionReporter`, `renderer`, `commandQueue`, `drawCount`, `skippedCount` |
| `MonitorMetalViewConfiguration` | `maximumDrawableCount` (3), `preferredFrameLatency` (2), `preferredFrameRateRange`, `framebufferOnly` (`true`), `gesturesEnabled` (`true`) |
| `MonitorDrawableContext`, `MonitorCompletionReporter` | What a host-driven tick receives (`drawable`, `texture`, `renderer`, `targetPresentationTimestamp`, `pixelsPerPoint`, `headroom`, `layerColor`, `needsDisplay`, `completion`, `viewport(_:)`), and where a host reports finished GPU work from any thread |
| `MonitorLayerColor` extensions | `metalPixelFormat`, `cgColorSpace` (exact power-law ICC spaces where Core Graphics names none), `hasNamedColorSpace`, `caEDRMetadata`, `apply(to:)`; `ColorSpace.cgName`; `MonitorOutputColor.explicit(for:)` |
| `MonitorDisplayHeadroom` | `current(for:)`, `potential(for:)` (`NSScreen` / `UIScreen`), `sanitized(_:)` |
| `MonitorMagnifier` | Gestures as `Magnification` edits: `zoom(…)`, `pan(_:by:layout:)`, `togglePixelExact(…)`, `recenter(…)`, `reset(_:)`, `pictureFraction(at:layout:)`, `effectiveZoom(_:)`, `zoomRange` |

```swift
import Metal
import MonitorKit
import MonitorKitUI
import QuartzCore

/// A view whose ticks the host encodes on its own queue (classic here).
@MainActor
func hostDrivenView(engine: MonitorEngine, scene: MonitorScene, queue: MTLCommandQueue) -> MonitorMetalView {
  let view = MonitorMetalView(
    engine: engine, scene: scene,
    mode: .hostDriven { context in
      guard context.needsDisplay, let drawable = context.drawable,
        let commandBuffer = queue.makeCommandBuffer()
      else { return false }
      do {
        try context.renderer.encode(target: context.texture, into: commandBuffer)
      } catch {
        return false
      }
      let encoded = context.renderer.encodeCount
      let reporter = context.completion
      commandBuffer.addCompletedHandler { _ in reporter.noteCompleted(through: encoded) }
      commandBuffer.present(drawable)
      commandBuffer.commit()
      return true
    })
  view.onStatusChange = { print(scene.surfaces.first?.status.activeLabels ?? []) }
  return view
}
```

### 6.3 SwiftUI

| View | Purpose |
| --- | --- |
| `MonitorView(engine:source:state:outputColor:queue:configuration:displayLinkRunLoop:onStatusChange:)` | One source's picture with its own tools; `state` is a binding both ways (gestures flow back) |
| `MonitorSceneView(view:)` | Hosts a `MonitorMetalView` you built (several surfaces, scopes, host mode) |
| `ScopeView(engine:scopeEngine:source:settings:monitorLUTEnabled:outputColor:queue:showsLabels:accumulationInterval:displayLinkRunLoop:)`, `ScopeStackView(… settings: [ScopeSettings], axis: …)` | Scopes of a source; a stack accumulates its scopes in one group |
| `ScopeLabelsView(labels:)`, `ScopeIREScale`, `ScopeIREScaleView(scale:showsGrid:)` | Graticule text; the −10 / 0 / 50 / 100 / 110 IRE scale of either level axis (`monitorKitAxis`, `legacyAxis`) |
| `ClipReadout(overlay:)` | Clip % from a scope overlay's statistics, ten times a second |
| `MonitorStatusOverlay(metadata:region:clean:)` / `(model:…)`, `MonitorOverlayMetadata`, `MonitorOverlayModel` | Timecode, format, LUT name, tally border, corner labels |
| `FalseColorLegend(settings:signal:layout:arriFullRange:)`, `FalseColorLegendView(legend:)` / `(legend:style:unavailable:)` | The legend of the active false colour, as a list or the captioned monitor legend |
| `MonitorTileToolbar(state:name:signal:status:tools:unavailable:placement:scopesEnabled:onScopes:freeze:onFreeze:scopeSettings:)` | A compact tile toolbar; `MonitorTileTool`, `MonitorFreezeState` (`actionTitle`, `accessibilityValue`), `MonitorMagnifyChoice`, `MonitorTileToolbarPlacement` |
| `ZebraControls`, `FalseColorControls`, `PeakingControls`, `GuideControls`, `GeometryControls`, `DisplayAdjustmentControls`, `LUTRoutingControls`, `OutputColorControls`, `ClipIndicatorControls`, `CleanSwitch`, `MonitorControlSection` | Editors of `MonitorState`; `Binding<MonitorState>.normalizing` clamps every write; `.monitorControlStyle()` |
| `AudioMeterView(meter:kind:scale:loudness:loudnessUnit:target:channelLabels:palette:)`, `AudioMeterBarKind`, `MeterBarReading`, `LoudnessReadout`, `MeterPalette` | Bar meters with peak hold and clip LEDs, and the R 128 panel |

```swift
import MonitorKit
import MonitorKitAudio
import MonitorKitScopes
import MonitorKitUI
import SwiftUI

struct MonitorWithScopes: View {
  let engine: MonitorEngine
  let source: MonitorSource
  let meter: AudioMeter
  @State private var state = MonitorState()

  var body: some View {
    VStack(spacing: 0) {
      MonitorView(engine: engine, source: source, state: $state)
      ScopeStackView(
        engine: engine, source: source,
        settings: [ScopeSettings(kind: .waveform), ScopeSettings(kind: .vectorscope), ScopeSettings(kind: .histogram)],
        accumulationInterval: 1.0 / 15)
        .frame(height: 180)
      AudioMeterView(meter: meter)
        .frame(height: 120)
      if let legend = FalseColorLegend(settings: state.falseColor, signal: source.latestFrame?.signal) {
        FalseColorLegendView(legend: legend, style: .captioned)
      }
    }
  }
}
```

## 7. Errors

| Error | Thrown by |
| --- | --- |
| `MonitorKitError` (`.unsupportedPixelFormat`, `.invalidFrame`, `.textureMapping`, `.gpu`) | Frames, engines, passes, feeds, scopes: a frame that does not match its layout, a viewport outside the target, a pipeline or encoder that could not be made. A throw leaves the object usable; nothing half-encoded is reused |
| `CubeLUT.ParseError` | `.cube` parsing |
| `DecodingError.dataCorrupted` | `MonitorState` JSON that is not MonitorKit's schema 2 |
| `AudioMeterError` (`.unsupportedSampleRate`, `.unsupportedChannelCount`, `.channelLayoutMismatch`, `.invalidParameter`) | Audio meter configuration |

`MonitorRenderer` does not throw for a surface or scope that fails: it skips it and records `lastError`.
