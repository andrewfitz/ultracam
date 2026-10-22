# MonitorKit architecture contract

The binding contract for everyone working on MonitorKit. Product scope is in [`docs/MONITOR_LIBRARY_PLAN.md`](../../../docs/MONITOR_LIBRARY_PLAN.md) and device research in [`docs/MONITOR_DEVICE_INVENTORY.md`](../../../docs/MONITOR_DEVICE_INVENTORY.md) (both in the Ultracam repo).

## Platform

- macOS 26+ / iOS 26+, Apple silicon. Swift 6 language mode, tools 6.2, warnings are errors.
- Metal Shading Language 4.0, compiled at runtime from `.msl` text resources. `makeLibrary(source:)` uses the OS compiler, so no Metal toolchain is needed. All MSL symbols are prefixed `mk_`.
- No third-party dependencies.

## Zero-overhead contract (every rule is tested)

1. **Host GPU objects.** The library never creates an `MTLDevice`, command queue, thread or dispatch queue. The one exception is `MonitorKitUI.MonitorMetalView`, the batteries-included tier: it uses a queue the host passes in, or creates one only if none is given.
2. **Encode, never commit.** Per-frame calls take an `MTLCommandBuffer` and only encode into it. They never commit, wait or add handlers.
3. **Borrowed inputs.** A `MonitorFrame` wraps textures the host already has, e.g. from a `CVMetalTextureCache` over an IOSurface `CVPixelBuffer`. The library never copies, stages or blits frame pixels. The only copy anywhere is Freeze, which the user asks for explicitly.
4. **Any output.** Draw into any render target: a drawable, an offscreen texture, or a viewport inside the host's render pass.
5. **No per-frame allocation.**
   - GPU: pipelines are built at init or on first use of a pixel format. Persistent textures and buffers are recreated only when size, format or settings change.
   - Uniforms go through `set*Bytes`.
   - CPU: the encode path makes no heap allocation. No arrays are built per frame; cache derived data behind an `Equatable` key.
6. **No CPU readback on the frame path.** Scope data stays on the GPU. Small numeric results go into a shared buffer the host can read later.
7. **Fusable.** `MKLUT.msl` and `MKDecode.msl` are self-contained. A host can prepend them to its own kernel and call `mk_applyLUT` / `mk_decodeRGB` in its own pass.

Thread safety:
- `MonitorEngine`, `MonitorLUT` and the scope engine are immutable after init and safe to share. Specialized pipelines are cached behind a lock and built on Metal's compiler threads.
- Feeds, passes, accumulators, groups and renderers are confined: one thread at a time, no internal locks, and not `Sendable` (move them with `sending`, or keep them on the render actor). `ScopeStatisticsReader` is the one `Sendable` reader for UI threads.
- State is a value type.

Lifetimes: per-frame encodes may go into command buffers created without retained references. Hosts keep frames and `MonitorLUT`s alive until those buffers complete; a feed keeps a replaced focus mask alive for `MonitorFeed.retiredFrames` (3) more analyses.

## Modules and ownership

| Target | Contents |
| --- | --- |
| `MonitorKitCore` | `MonitorState` and settings, `SignalDescription`, `PixelLayout`, `LogCurve`, `MonitorLayout` and `GuideRaster` (the guide strokes the pass draws analytically), `CubeLUT` (3D, 1D and shaper + 3D) and the CPU LUT reference, false-color tables, the reference math (`ColorMath`, `DecodeReference`, Sony, ARRI, EL Zone) |
| `MonitorKit` | `MonitorFrame`, `MonitorShaders`, `MonitorLUT`, `MonitorEngine`, `MonitorFeed`, `MonitorPass`, `MonitorStatus`, display transforms and HDR. Shaders: `MKLUT`, `MKDecode`, `MKMonitor` |
| `MonitorKitScopes` | `ScopeSettings`, `ScopeEngine`, `ScopeAccumulator`, `ScopeGroup` (one fused pass for a stage's waveform, histogram and vectorscope), `ScopeRenderer`, `ScopeStatisticsReader`, graticules. Shader: `MKScopes` (compiled after `MKLUT` + `MKDecode`) |
| `MonitorKitAudio` | `AudioMeter`, `AudioMeterConfiguration`, `AudioMeterSnapshot`, `LoudnessMeter`. Pure Swift + Accelerate |
| `MonitorKitUI` | `MonitorMetalView` (CAMetalLayer, display link), SwiftUI controls bound to `MonitorState`, legends, scope and meter views |

## Data flow per frame (Encode tier)

```
host frame (CVPixelBuffer) ──wrap──▶ MonitorFrame (borrowed textures)
                                         │
       feed.analyze(frame, into: cb)  ◀──┤ once per frame: focus mask at source resolution (only if any surface needs peaking)
       scopes.accumulate(frame, feed: feed, into: cb) once per frame per scope stage (or one ScopeGroup), at the host's scope rate
                                         │
 for each surface: pass.encode(frame, feed, state, target, viewport, into: cb)
       one fragment pass, its pipeline specialized to the surface's tool set:
                      decode (separable filter: nearest 1:1, Catmull-Rom magnified, box minified)
                      → burn-in LUT (output stage) → monitor LUT (monitor stage)
                      → false color | display adjustments → zebras → peaking → matte/guides (analytic strokes)
                      → navigator inset while magnified
       scopeRenderer.render(accumulator, display, target, viewport, into: cb)
```

Signal stages (one decode per pixel feeds all three):
- `source`: the camera signal, range-expanded, matrix-decoded, never clipped
- `output`: after the feed's burn-in LUT. This is what the real output carries. A host that burns the LUT in its own kernel uses the same `MonitorLUT` and `mk_applyLUT`, so preview and output are identical.
- `monitor`: after the monitor-only LUT

Log false-color modes always classify the source, using the per-channel native-log decode. Zebras, the six-band and custom false color, focus peaking and scopes each choose a stage.

One decode convention across modules (tested end to end in `ScopePictureAgreementTests`):
- Stage luma: the decoded transport Y' when no LUT touched the stage, else Rec.709 Y' of the LUT result (`mk_stageLuma` in the pass, the same rule in `MKScopes`). Boundaries are inclusive at the lower edge, so a 940 code is 100 IRE for zebras, false colour and scope clip counts alike.
- Log signal: `LogCurve.signal` / `mk_logSignal`. S-Log3 is code-valued (a legal container carries code / 1023); LogC fills the container's range. A full container labelled `.fullRescaledToLegal` is unsqueezed from its own depth's legal range (`mk_unsqueezeLegal`).
- Display-referred stops linearize with the source's own transfer (`DisplayTransfer.exposureLinear` / `mk_exposureLinear`).

## Public API (MonitorKit)

```swift
public enum PipelineSpecialization { case asynchronous, synchronous, off }

public final class MonitorEngine: @unchecked Sendable {
  public let device: MTLDevice
  /// Compiles the library and compute pipelines. Specialized per-tool-set picture
  /// pipelines build asynchronously by default; until one is ready a surface draws
  /// with the all-tools pipeline (same pixels).
  public init(device: MTLDevice, specialization: PipelineSpecialization = .asynchronous) throws
  /// Optional warm-up of the render and focus pipelines.
  public func prepare(pixelFormat: MTLPixelFormat, layouts: [PixelLayout]? = nil) throws
  public func prepare(target: MonitorRenderTargetFormat, layouts: [PixelLayout]? = nil) throws
  public func makeFeed() -> MonitorFeed
  public func makePass() -> MonitorPass
}

public final class MonitorFeed {                       // one per video feed
  public var burnInLUT: MonitorLUT?                    // output stage; also what the host bakes into output
  public var monitorLUT: MonitorLUT?                   // monitor stage only
  /// Once per frame, before any pass that shows peaking. With focus off it marks the mask stale.
  /// The mask is valid for `MonitorFrame.id` and the LUTs of `focus.stage`.
  public func analyze(_ frame: MonitorFrame, focus: FocusSettings, into commandBuffer: MTLCommandBuffer) throws
}

public struct MonitorViewport { x, y, width, height (target pixels); pixelsPerPoint }

/// The host render pass a `draw` lands in: colour format, depth, stencil, sample
/// count and further colour attachments (left untouched).
public struct MonitorRenderTargetFormat: Hashable { init(colorPixelFormat:…); init(_ MTLRenderPassDescriptor) }

public final class MonitorPass {                       // one per surface; owns no GPU memory
  /// Its own render pass into `target`. `clear` sets the load action.
  public func encode(frame: MonitorFrame, feed: MonitorFeed, state: MonitorState,
                     target: MTLTexture, viewport: MonitorViewport? = nil, clear: Bool = true,
                     into commandBuffer: MTLCommandBuffer) throws
  /// Host render pass: `prepare` (encodes nothing), then `draw` inside the pass. `draw`
  /// binds fragment textures 0–5 and buffers 0–4 and, with depth or stencil, a
  /// depth-stencil state that always passes and never writes.
  public func prepare(frame:, feed:, state:, viewport:, target: MonitorRenderTargetFormat, into commandBuffer:) throws
  public func prepare(frame:, feed:, state:, viewport:, targetPixelFormat:, into commandBuffer:) throws
  public func draw(with encoder: MTLRenderCommandEncoder) throws
  public private(set) var status: MonitorStatus        // why a tool is unavailable, the active labels
}
```

`MonitorFrame.id` is fresh per wrapped frame (a host reusing one `MonitorFrame` value across pictures sets it). `FrameParameters.matrix.w` is the 4:2:0 vertical chroma offset; `PassParameters.luts.w` the source transfer code; `LUTParameters` carries the 1D shaper rows (`shaperLow`, `shaperScale`).

Status, not failure: a tool that cannot run on the given signal shows an explicit reason in `MonitorStatus` and is skipped. Examples: a log false-color mode on a non-log source, stops on an unlabelled source (`requiresKnownTransfer`), or peaking without an analysed mask. The picture is still drawn.

Target encoding:
- The pass writes SDR display-encoded values.
- For `*_srgb` targets it linearizes first, so the hardware encode is correct (fixed per pipeline, not branched per pixel).
- Planned (W2): for `rgba16Float` EDR targets, HDR mode writes values for the layer's color space. Until then give such a layer a non-linear SDR colour space.

## Quality bars

- **Correctness:** every GPU path matches the CPU reference in Core within documented tolerances: exact for classification boundaries, ≤ 1/1023 for decode at integral codes, ≤ 1e-4 for LUT interpolation. Tests cover every layout, bit depth, range, matrix, chroma siting, LUT size (2/17/33/65) and interpolation mode.
- **Math:** constants trace to primary sources (Sony S-Log3 technical summary, ARRI LogC3/LogC4 white papers, ITU-R BT.709/1886/2020/2100, SMPTE ST 2084, EBU R128/Tech 3341/3342, ITU-R BS.1770-4, IEC 60268-10/17). The sources are listed in `Docs/MATH.md`.
- **Performance:** measured with GPU timestamps on the dev machine (M4 Max).
  - The full picture pass, from 4K v210 to a 1080p target with every tool on, should cost ≤ 0.5 ms of GPU time.
  - The focus mask at 4K should cost ≤ 0.4 ms.
  - The scope accumulation of every pixel at 4K should cost ≤ 1 ms.
  - Four feeds at 4K60 must hold 60 Hz.
  - The CPU encode cost per pass is ≤ 30 µs, with zero heap allocations (measured).
- **Memory:** persistent memory per feed and per surface is documented and tested (`persistentMemoryBytes`). A surface owns none (guides are analytic); a feed owns one r8 focus mask at source size; scope bins and trace textures are sized to the scope resolution, not the frame.
- **Tests:** XCTest. GPU tests skip cleanly (`XCTSkip`) when no Metal device is present.
