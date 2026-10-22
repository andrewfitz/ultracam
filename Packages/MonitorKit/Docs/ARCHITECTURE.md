# MonitorKit architecture contract

The binding contract for everyone working on MonitorKit. Product scope is in [`docs/MONITOR_LIBRARY_PLAN.md`](../../../docs/MONITOR_LIBRARY_PLAN.md) and device research in [`docs/MONITOR_DEVICE_INVENTORY.md`](../../../docs/MONITOR_DEVICE_INVENTORY.md) (both in the Ultracam repo). The constants and formulas are in [`MATH.md`](MATH.md).

## Platform

- macOS 26+ / iOS 26+, Apple silicon. Swift 6 language mode, tools 6.2, warnings are errors.
- Metal Shading Language 4.0 (4.1 on macOS/iOS 27), compiled at runtime from `.msl` text resources with `MonitorShaders.compileOptions` (safe math). `makeLibrary(source:)` uses the OS compiler, so no Metal toolchain is needed. `MonitorShaders.libraryDescriptor(parts:)` gives the same source to an `MTL4Compiler` (tested to produce identical output). All MSL symbols are prefixed `mk_`.
- Two encode paths with bit-identical pixels: classic (`MTLCommandBuffer`) and Metal 4 (`MonitorSubmission` over an `MTL4CommandBuffer`). The Metal 4 path reuses the device-built pipeline states (valid in MTL4 encoders, no second compile).
- No third-party dependencies.

## Zero-overhead contract (every rule is tested)

1. **Host GPU objects.** The library never creates an `MTLDevice`, command queue, command buffer, command allocator, thread or dispatch queue. The one exception is the batteries-included view tier in `MonitorKitUI`: a convenience-mode `MonitorMetalView`, `MonitorView`, `ScopeView` or `ScopeStackView` creates a command queue only when none is given, and commits its own command buffers (see the UI tier below). `MonitorRenderer` itself creates nothing.
2. **Encode, never commit.** Per-frame calls take an `MTLCommandBuffer` (classic) or a `MonitorSubmission` (Metal 4) and only encode into it. They never commit, wait or add handlers. On Metal 4 the library never begins or ends a command buffer either. A source-scan contract test checks both paths.
3. **Borrowed inputs.** A `MonitorFrame` wraps textures the host already has, e.g. from a `CVMetalTextureCache` over an IOSurface `CVPixelBuffer`. The library never copies, stages or blits frame pixels. The only copy anywhere is Freeze, which the user asks for explicitly; it is a compute kernel (`mk_copyUint` / `mk_copyFloat`; BGRA8 and BGR10A2 planes are stored as RGBA8 / RGB10A2), never a blit.
4. **Any output.** Draw into any render target: a drawable (including `framebufferOnly` drawables in `bgr10a2Unorm`, `rgba16Float` and `bgra8Unorm`, tested with real `CAMetalLayer` drawables), an offscreen texture, a viewport inside the host's render pass (depth, stencil, MSAA and further colour attachments described by `MonitorRenderTargetFormat`), or, on Metal 4, a compute write into a shader-writable target (`encodeCompute`).
5. **No per-frame allocation.**
   - GPU: pipelines are built at init or on first use of a pixel format. Persistent textures and buffers are recreated only when size, format or settings change.
   - Uniforms: classic path through `set*Bytes`. Metal 4: each pass, feed, accumulator, group and renderer owns a `MonitorUniformRing` (one shared, write-combined, resident buffer of `framesInFlight` slots, made on first use). A slot is rewritten only when its parameters change, and only after the last submission that read it completed; steady state writes nothing and binds the same slot. A host may instead pass a `MonitorUniformAllocator` in `MonitorSubmission.uniforms` (256-byte aligned, resident, valid until completion), sized from the `uniformLength` constants below.
   - Residency (Metal 4): changes are found by object identity and the set is committed only when something joins or leaves it; steady state makes no residency commit (tested).
   - CPU: the encode path makes no heap allocation of its own (measured against the same Metal calls made inline). No arrays are built per frame; derived data is cached behind an `Equatable` key. Per-frame code uses `while` loops with direct subscripts (no `for`-in, `enumerated()`, `first`, `contains`), so the zero-allocation tests hold in debug builds.
6. **No CPU readback on the frame path.** Scope data stays on the GPU. Small numeric results go into a shared buffer the host can read later (`ScopeStatisticsReader`).
7. **Fusable.** `MKLUT.msl` and `MKDecode.msl` are self-contained. A host can prepend them to its own kernel and call `mk_applyLUT` / `mk_decodeRGB` in its own pass, compiling with `MonitorShaders.compileOptions` or `libraryDescriptor(parts:)`. `MonitorLUT` shaper rows are the texture width wide (at least 8), so a host must use the shipped `MKLUT.msl` (`mk_shaperEntry(lut, i, n, w)`), not an older copy.

### Metal 4 rules

- **One queue, one timeline.** All of an engine's Metal 4 work goes on one `MTL4CommandQueue`. Submission indices start at 1 (0 means none; `MonitorSubmission.init` and `MonitorResidency.observe` trap on 0). Every encode into one command buffer shares its index.
- **Completion contract.** `completedIndex` is the highest *contiguous* completed submission: that one and every earlier one have completed or were abandoned. Feedback handlers can complete out of order, so a host keeps a done-set and advances a watermark (`Tests/MonitorKitTests/Metal4Support.swift`). Reporting a non-contiguous maximum would reuse ring slots and free resources still in flight. A host that limits frames in flight with a semaphore can use `MonitorSubmission(commandBuffer:index:framesInFlight:)` instead.
- **Residency.** `MonitorEngine.residency` (a `MonitorResidency`) holds everything the library owns: placeholders, focus masks, Freeze planes, rings, argument tables' resources and the feeds' LUT textures (counted, so a LUT shared by two feeds stays until both release it). `ScopeEngine(…, residency:)` can take the same object, so the host attaches one set. The host attaches `residency.set` to its queue once. Host frames and targets stay the host's to make resident (`MonitorFrame.addResidency(to:)` when a texture is first wrapped, e.g. in an IOSurface-keyed cache, never per frame). Call `feed.updateResidency()` before other Metal 4 work reads a feed's LUTs outside MonitorKit.
- **Argument tables.** Each object owns one table, made on its first Metal 4 encode (pass 7 textures / 5 buffers, feed 6 / 4, accumulator 5 / 6, group 5 / 15, renderer 2 / 3). Metal 4 snapshots bindings at each draw or dispatch, so reusing a table across encodes is safe. In a host encoder the library binds its own table; hosts rebind theirs afterwards.
- **Uniform sizes per encode** (`uniformLength`, 256-byte offsets): `MonitorPass` 5120 B (frame 80, two LUT blocks, `PassParameters` 1456 at offset 768, `GuideParameters` 2592 at 2304), `MonitorFeed` 1024, `ScopeAccumulator` 1280, `ScopeGroup` 2048 (fused pass; unfused members ask their own), `ScopeRenderer` 768 per `prepare` plus `graticuleUniformLength` 2304 only when the graticule changes. Use the constants, not hand-computed struct sizes.
- **Barriers**, all encoded by the library, as narrow as correctness allows:

| Work | Barrier |
| --- | --- |
| Focus analysis | Waits for earlier fragment and dispatch work (write-after-read on the mask, no cache flush), only while a submission that used the mask may still run. In a host encoder, encoder barriers before the dispatch and after it (`.device`). |
| Draw that reads the mask | Dispatch → fragment, `.device`, also inside host render passes; skipped once the analysis's submission is known complete. |
| Compute picture that reads the mask | Dispatch → dispatch, `.device`. |
| `encode(…, clear: false)` / `MonitorMultiview` with `clear: false` | Waits for earlier fragment and dispatch work before the attachment loads (once per multiview pass). |
| `encodeCompute(sharesTarget: true)` (default) | Waits for earlier fragment and dispatch work (another surface's render pass stores whole tiles); plus an encoder barrier in a host encoder. `sharesTarget: false` for the only writer of a fresh drawable waits only for a focus analysis. |
| Freeze | If it overwrites existing planes, first waits for earlier fragment, dispatch and blit reads; after the copy, a producer barrier from dispatch to later dispatch, fragment and blit work. |
| Scope accumulate | Waits for earlier dispatch, fragment and blit work before the clear (write-after-read on bins and statistics); encoder barriers order clear → count → finalize; in a host encoder also before the clear and after the finalize. No producer barrier, so the picture can overlap it. |
| Scope resolve | Waits for earlier dispatch and fragment work, `.device`. |
| Scope graticule raster | Fragment → fragment. |
| Scope draw | Waits for earlier dispatch and fragment work only while its trace or graticule writer's submission may be running. `render(clear: false)` (the default) has a load barrier. |

  The host orders its own writes to frames and targets. A host that reads a persistent, non-drawable target (samples or blits a multiview texture) ends its reading encoder with a producer barrier (after its stages, before fragment and dispatch) so the next frame's MonitorKit write does not overtake the read; `encode(clear: true)` adds no barrier of its own. A host reading scope bins in its own shaders adds a consumer barrier on `.dispatch` first. Drawables are covered by `waitForDrawable`.

### Thread safety

- `MonitorEngine`, `MonitorLUT`, `MonitorResidency` and `ScopeEngine` are immutable after init (apart from locked caches) and safe to share. Specialized pipelines are cached behind a lock and built on Metal's compiler threads.
- Feeds, passes, multiviews, accumulators, groups and renderers are confined: one thread at a time, no internal locks, and not `Sendable` (compile-time protection against sharing). Create and use them on the render thread, move them with `sending`, or keep them on a global actor whose executor is the render thread. A `ScopeRenderer` and the accumulators it draws stay on one thread (its Metal 4 `prepare` updates their residency). `ScopeStatisticsReader` is the `Sendable` reader for UI threads.
- `MonitorSubmission` is a per-frame value and not `Sendable`. State types are values.
- `MonitorKitUI`'s scene handles (`MonitorScene`, `MonitorSource`, `MonitorSurface`, `MonitorScopeOverlay`, `MonitorCompletionReporter`) are `Sendable` and lock-protected; `MonitorSource.submit` never waits for the GPU.

### Lifetimes

- **Classic path.** Per-frame encodes may go into command buffers created without retained references. Hosts keep frames and `MonitorLUT`s alive until those buffers complete. A feed keeps a replaced or released focus mask in a ring of `MonitorFeed.retiredFrames` (3) slots, each aged by later `analyze` calls; scopes keep replaced bins (`ScopeAccumulator`, aged per accumulation) and replaced trace and graticule textures (`ScopeRenderer`, aged per `prepare`) the same way. Retired resources are not counted in `persistentMemoryBytes`; `MonitorFeed.retiredMemoryBytes` shows them, and `releaseRetired()` drops them once every command buffer that used the feed has completed (a feed nobody analyses any more never ages them). Hosts using unretained command buffers keep accumulators, groups and renderers alive until their last command buffer completes.
- **Metal 4.** The library releases nothing early and needs no retain or retire hooks from the host. A replaced mask, Freeze plane, LUT texture, ring or bin buffer, and everything a feed, pass, accumulator, group or renderer owns when it is deallocated with work in flight, stays alive and resident until the submission that last used it completes (`MonitorResidency`, keyed by submission index). Keep the engines alive until their work completes. Resources retired after the host's last encode wait for the next `observe`; hosts can call `residency.release(through:)` from their completion handler. A LUT replaced with `feed.burnInLUT = nil` stays referenced until the feed's next Metal 4 encode or deinit (by design). `ScopeEngine` retires its placeholders from a shared residency set on deinit.
- **Frozen frames.** A `MonitorFrame` returned by `freeze` is valid while the host holds it. `unfreeze()` releases the planes by default (`unfreeze(keepingMemory: true)` keeps them for a host that toggles Freeze often). On Metal 4 the released planes leave residency once their last submission completes, and every MonitorKit Metal 4 encode that reads a held frozen frame (pictures, analysis, Freeze, scope accumulations and groups) calls `MonitorFrame.keepResidentIfReleased(in:)` to make it resident again for that submission. A re-freeze into the same planes needs no host ordering on Metal 4 (the library waits for earlier readers); on the classic path encode it after every command buffer that still reads the previous frozen frame.
- **UI tier.** `MonitorRenderer` holds replaced frames and LUTs for `max(3, framesInFlight)` classic encodes, or until `completedIndex` passes them on Metal 4. An encode may span two command buffers (`encodePictures`, then `encodeScopes` committed after it on the same queue); completion (`noteCompleted(through:)` or `MonitorCompletionReporter`, thread-safe and monotonic) is reported only after the later one completes. A paused or hidden convenience view commits one empty marker command buffer with a single completion handler per pause, then releases idle frames and focus masks.

## Modules and ownership

| Target | Contents |
| --- | --- |
| `MonitorKitCore` | `MonitorState` and settings (zebras, false colour, focus, guides, geometry, display adjustments with white-point trim, `DisplayTransformSettings`, `ClipIndicatorSettings`), `SignalDescription` (with `primaries`), `PixelLayout`, `LogCurve`, `MonitorLayout` and `GuideRaster`, `CubeLUT` and the CPU LUT reference, false-colour tables (`FalseColorTable`, `usesFullRangeARRI(signal:layout:)`), `MonitorOutputColor` / `MonitorLayerColor` (`OutputColor.swift`), `ColorPrimaries` / `ColorMatrix` (`Colorimetry.swift`), the reference math (`ColorMath`, `DecodeReference`, `MonitorColorPipeline`, `DisplayAssist`, `HDRToSDR`, `ToneMapEETF`, `WhitePointTrim`, transfer functions, Sony, ARRI, EL Zone) |
| `MonitorKit` | `MonitorFrame`, `MonitorShaders`, `MonitorLUT`, `MonitorEngine`, `MonitorFeed` (analysis, Freeze), `MonitorPass`, `MonitorMultiview`, `MonitorStatus`, the Metal 4 types (`Metal4.swift`: `MonitorSubmission`, `MonitorUniformAllocator`, `MonitorUniformRing`, `MonitorResidency`) and the Metal 4 encode paths (`MonitorFeedMetal4.swift`, `MonitorPassMetal4.swift`). Shaders: `MKLUT`, `MKDecode`, `MKMonitor` |
| `MonitorKitScopes` | `ScopeSettings`, `ScopeEngine`, `ScopeAccumulator`, `ScopeGroup` (one fused pass for a stage's waveform, histogram and vectorscope), `ScopeRenderer` (HDR-aware via `colorPipeline`), `ScopeStatisticsReader`, graticules, `RetiredResources`, and the Metal 4 paths (`Scope*Metal4.swift`, `ScopeMetal4.swift`). Shader: `MKScopes` (compiled after `MKLUT` + `MKDecode`) |
| `MonitorKitAudio` | `AudioMeter`, `AudioMeterConfiguration`, `AudioMeterSnapshot`, `LoudnessMeter`, `LoudnessEngine`, `MeterScale` (marks and zones per meter type), reset generations. Pure Swift + Accelerate |
| `MonitorKitUI` | Scene handles (`MonitorScene`, `MonitorSource`, `MonitorSurface`, `MonitorScopeOverlay`, `MonitorRegion`), `MonitorRenderer` (drawable-free, classic or Metal 4), `MonitorMetalView` (CAMetalLayer, `CAMetalDisplayLink`), layer colour (`MonitorLayerColor.apply(to:)`, exact ICC spaces), headroom, `MonitorMagnifier`, SwiftUI views (`MonitorView`, `MonitorSceneView`, `ScopeView`, `ScopeStackView`, `ClipReadout`, `MonitorStatusOverlay`), controls, `FalseColorLegend`, `AudioMeterView` |

## Data flow per frame (Encode tier)

```
host frame (CVPixelBuffer) ──wrap──▶ MonitorFrame (borrowed textures)
                                         │
       feed.analyze(frame, focus, into:)  ◀──┤ once per frame: focus mask at source resolution (only while some surface shows peaking)
       scopes.accumulate(frame, feed:, into:) once per frame per scope stage (or one ScopeGroup), at the host's scope rate
                                         │
 for each surface: pass.encode(frame, feed, state, target, viewport, into:)   (or MonitorMultiview: all surfaces in one render pass)
       one fragment pass (or compute kernel), its pipeline specialized to the surface's tool set and colour path:
                      decode (separable filter: nearest 1:1, Catmull-Rom magnified, box minified)
                      → burn-in LUT (output stage) → monitor LUT (monitor stage)
                      → false colour | display transform → display adjustments (incl. white-point trim)
                        → output conversion (linearize, 3×3 in linear light, optional roll-off, target encode)
                      → zebras → clip indicators → peaking → matte/guides (analytic strokes)
                      → navigator inset while magnified
       scopeRenderer.render(accumulator, display, target, viewport, into:)
```

- Signal stages (one decode per pixel feeds all three): `source` (the camera signal, range-expanded, matrix-decoded, never clipped); `output` (after the feed's burn-in LUT: what the real output carries; a host that burns the LUT in its own kernel uses the same `MonitorLUT` and `mk_applyLUT`, so preview and output are identical); `monitor` (after the monitor-only LUT).
- Tools measure their own `SignalStage`, never the transformed or output-encoded picture. Log false-colour modes always classify the source with the per-channel native-log decode. Zebras, the six-band and custom false colour, clip indicators, focus peaking and scopes each choose a stage.
- **LUT convention.** LUT output is Rec.709 display R'G'B' on every stage. Any burn-in LUT, or a monitor LUT the surface shows, makes the picture Rec.709 SDR and every display transform unavailable (`.lutOnMonitorStage`), matching Sony's Gamma Display Assist, which is off while a LUT is applied. `MonitorFeed.monitorStageHasLUT(for:)` is the public rule; pass it to `MonitorOutputColor.layer(for:…)` and `MonitorEngine.prepare(…)`, and re-tag the layer when LUTs change. HDR-to-HDR LUTs are not modelled.
- **One decode convention across modules** (tested end to end in `ScopePictureAgreementTests`): stage luma is the decoded transport Y' when no LUT touched the stage, else Rec.709 Y' of the LUT result (`mk_stageLuma` in the pass, the same rule in `MKScopes`). Boundaries are inclusive at the lower edge, so a 940 code is 100 IRE for zebras, false colour, clip indicators and scope clip counts alike. Scope statistics (Y' clip counts, luma min/max/average) always use this rule whatever `ScopeColorimetry` is; colorimetry drives only the drawn luma, the Y'CbCr parade and the vectorscope. Scope clip counts compare R', G', B' and Y' in percent with the same Float operations as the picture's clip indicator (`v·100 ≥ level`), so `ScopeStatistics.clippedHigh/Low` count exactly the pixels `ClipIndicatorSettings` marks.
- Log signal: `LogCurve.signal` / `mk_logSignal`. S-Log3 is code-valued (a legal container carries code / 1023); LogC fills the container's range. A full container labelled `.fullRescaledToLegal` is unsqueezed from its own depth's legal range (`mk_unsqueezeLegal`). ARRI's full-range tables are chosen by `FalseColorTable.usesFullRangeARRI(signal:layout:)` (full or float container, or a rescaled transport), shared by the pass and `FalseColorLegend`.
- Display-referred stops linearize with the source's own transfer (`DisplayTransfer.exposureLinear` / `mk_exposureLinear`).
- **Focus analysis.** `mk_focusMask` gives each thread one column of `MonitorFeed.focusRows` (8) rows and takes its left and right neighbours from the adjacent SIMD lanes, with no threadgroup memory or barrier; each threadgroup row is one SIMD-group whose two outer lanes only read halo; each source pixel is decoded about 1.3 times. `analyze` encodes nothing when the mask already holds the frame with the same settings (a frozen frame, or a display refreshing faster than the source). A focus pipeline compiles only the LUTs its stage uses.
- **Guides.** `GuideParameters` carries a 16-pixel cell bitmask per axis (`cells`, `cellSize`), so most pixels skip the line search. `GuideParameters()` starts with every cell set, so a hand-filled struct draws its lines; `updateCells()` rebuilds the mask.
- **Multiview.** `MonitorMultiview` draws N surfaces in one render pass (classic and Metal 4, at most one barrier), bit-identical to one pass per surface. Chained `encode(clear: false)` loads and stores the whole attachment once per surface.
- **UI tier per tick.** `MonitorRenderer.update()`, `needsDisplay(…)`, then `encode` (or `encodePictures` + `encodeScopes`): analyses, then scope-group accumulations, then every `prepare`, then a single render pass (clear, pictures in order, scopes). Scopes are grouped per (source, `monitorLUTEnabled`) in a `ScopeGroup` and re-accumulate only on frame, LUT, bin-setting or LUT-choice changes, at most every `accumulationInterval` seconds. A source gets one `MonitorFeed` per distinct focus analysis (effective stage, sensitivity, noise rejection). `MonitorSource` is display-only (latest frame wins): analysis that must see every frame belongs in the host's per-frame pipeline. `MonitorScene.clean` draws every surface clean and no scope; `MonitorScopeOverlay.isHidden` measures without drawing (the `ClipReadout` path).

## Public API (MonitorKit)

```swift
public enum PipelineSpecialization { case asynchronous, synchronous, off }

public final class MonitorEngine: @unchecked Sendable {
  public let device: MTLDevice
  public let framesInFlight: Int                       // Metal 4 ring slots per object (default 3)
  public let residency: MonitorResidency               // attach `residency.set` to the MTL4 queue once
  /// Compiles the library and compute pipelines (Freeze copy kernels start building
  /// at init on an asynchronous engine). Specialized per-tool-set picture pipelines
  /// build asynchronously by default; until one is ready a surface draws with the
  /// all-tools pipeline, which reads the output colour and transform from the
  /// uniforms (function constant 15): one per target format and layout, pixels
  /// identical to the specialized pipeline for native SDR and within 1e-5 otherwise.
  public init(device: MTLDevice, specialization: PipelineSpecialization = .asynchronous, framesInFlight: Int = 3) throws
  /// Optional warm-up: the colour-independent all-tools render pipelines, three
  /// focus pipelines per layout (source, burn-in, both LUTs) and the Freeze copy kernels.
  public func prepare(pixelFormat: MTLPixelFormat, layouts: [PixelLayout]? = nil) throws
  public func prepare(target: MonitorRenderTargetFormat, layouts: [PixelLayout]? = nil) throws
  public func prepare(target:layouts:outputColor:signal:displayTransform:monitorStageHasLUT:) throws
  public func prepareCompute(pixelFormat:layouts:outputColor:signal:displayTransform:monitorStageHasLUT:) throws
  public func makeFeed() -> MonitorFeed
  public func makePass() -> MonitorPass
}

public final class MonitorFeed {                       // one per video feed
  public var burnInLUT: MonitorLUT?                    // output stage; also what the host bakes into output
  public var monitorLUT: MonitorLUT?                   // monitor stage only
  /// Once per frame, before any pass that shows peaking. With focus off it encodes
  /// nothing and releases the mask (after the frames in flight).
  public func analyze(_ frame: MonitorFrame, focus: FocusSettings, into commandBuffer: MTLCommandBuffer) throws
  public func analyze(_ frame: MonitorFrame, focus: FocusSettings, into submission: MonitorSubmission) throws
  public func analyze(_ frame:, focus:, submission:, encoder: any MTL4ComputeCommandEncoder) throws
  public func monitorStageHasLUT(for state: MonitorState) -> Bool
  /// Freeze: one compute copy into planes owned by the feed (allocated once per size
  /// and format); the copy works wherever a live frame does.
  public func freeze(_ frame: MonitorFrame, into commandBuffer: MTLCommandBuffer) throws -> MonitorFrame
  public func freeze(_ frame: MonitorFrame, into submission: MonitorSubmission) throws -> MonitorFrame
  public private(set) var frozenFrame: MonitorFrame?
  public func unfreeze(keepingMemory: Bool = false)    // releases the planes by default
  public func updateResidency()                        // before other Metal 4 work reads the LUTs
  public var persistentMemoryBytes: Int                // mask while peaking + Freeze planes + Metal 4 ring
  public var retiredMemoryBytes: Int                   // classic: masks held for the frames in flight
  public func releaseRetired()                         // classic: once its command buffers completed
  public static let uniformLength: Int                 // 1024
}

public struct MonitorViewport { x, y, width, height (target pixels); pixelsPerPoint }

/// The host render pass a `draw` lands in: colour format, depth, stencil, sample
/// count and further colour attachments (left untouched).
public struct MonitorRenderTargetFormat: Hashable { init(colorPixelFormat:…); init(_ MTLRenderPassDescriptor) }

public final class MonitorPass {                       // one per surface
  public var outputColor: MonitorOutputColor           // default .signalNative
  public private(set) var colorPipeline: MonitorColorPipeline   // share with ScopeRenderer.colorPipeline
  /// Its own render pass into `target`. `clear` sets the load action.
  public func encode(frame:, feed:, state:, target:, viewport: = nil, clear: = true, into: MTLCommandBuffer) throws
  public func encode(frame:, feed:, state:, target:, viewport: = nil, clear: = true, into: MonitorSubmission) throws
  /// Host render pass: `prepare` (encodes nothing), then `draw` inside the pass. `draw`
  /// sets the pipeline, viewport, a scissor of the viewport, no culling, fill mode, its
  /// bindings (classic: fragment textures 0–5, buffers 0–4; Metal 4: its argument table
  /// at the fragment stage) and, with depth or stencil, an always-pass, never-write
  /// depth-stencil state, so the host's render state cannot hide the picture. The
  /// viewport must lie inside the host's target.
  public func prepare(frame:, feed:, state:, viewport:, target: MonitorRenderTargetFormat, into: MTLCommandBuffer) throws
  public func prepare(frame:, feed:, state:, viewport:, targetPixelFormat:, into: MTLCommandBuffer) throws
  public func prepare(frame:, feed:, state:, viewport:, target:, submission: MonitorSubmission) throws
  public func draw(with encoder: MTLRenderCommandEncoder) throws
  public func draw(with encoder: any MTL4RenderCommandEncoder) throws
  /// Metal 4 compute variant: writes only the viewport of a shader-writable, non-sRGB
  /// target, bit-identical to the render pass; own encoder or the host's.
  public func encodeCompute(frame:, feed:, state:, target:, viewport: = nil, sharesTarget: = true, into: MonitorSubmission) throws
  public func encodeCompute(…, submission:, encoder: any MTL4ComputeCommandEncoder) throws
  public private(set) var status: MonitorStatus        // why a tool is unavailable, the active labels
  public var persistentMemoryBytes: Int                // 0 classic; its ring on Metal 4
  public static let uniformLength: Int                 // 5120
}

public final class MonitorMultiview {                  // several surfaces, one render pass
  public func encode(target:, clear: = true, into: MTLCommandBuffer, _ surfaces: (Canvas) throws -> Void) throws
  public func encode(target:, clear: = true, into: MonitorSubmission, _ surfaces: (Canvas) throws -> Void) throws
  public struct Canvas { func draw(_ pass:, frame:, feed:, state:, viewport: = nil) throws }
}

// Metal 4 (Metal4.swift)
public struct MonitorSubmission { commandBuffer, index (≥ 1), completedIndex, uniforms }
public protocol MonitorUniformAllocator: AnyObject { func allocateUniforms(length: Int) -> MonitorUniformAllocation }
public final class MonitorResidency: @unchecked Sendable { set, add, retire(_:resident:after:), observe, release(through:), contains }
public struct MonitorUniformRing: ~Copyable { slot(for:generation:device:residency:initialSlots:), retire(to:) }

extension MonitorFrame {
  public func addResidency(to: MTLResidencySet); public func removeResidency(from: MTLResidencySet)  // no commit
  public func keepResidentIfReleased(in: MonitorResidency)  // frozen frames after unfreeze; scopes call it too
}
```

`MonitorFrame.id` is fresh per wrapped frame (a host reusing one `MonitorFrame` value across pictures sets it). `MonitorFrame.signal(of:)` reads the colour-primaries attachment (709, 2020 and P3 D65; others stay nil; `SignalDescription` equality includes `primaries`, so compare `effectivePrimaries`). `FrameParameters.matrix.w` is the 4:2:0 vertical chroma offset; `PassParameters.luts.w` the source transfer code; `LUTParameters` carries the 1D shaper rows (`shaperLow`, `shaperScale`).

### Scopes

```swift
public final class ScopeEngine: @unchecked Sendable {
  public init(device:, specialization: = .asynchronous, framesInFlight: = 3, residency: MonitorResidency? = nil) throws
  public let residency: MonitorResidency               // pass MonitorEngine.residency to share one set
  public func prepare(pixelFormat:) / prepare(target: MonitorRenderTargetFormat) / prepare(settings:layouts:target:)
  public var pipelineBuildFailures: [String]           // recorded once, never retried; fall back to general pipelines
  public func makeAccumulator(settings:) throws -> ScopeAccumulator
  public func makeGroup(_ accumulators: [ScopeAccumulator]) throws -> ScopeGroup
  public func makeRenderer() -> ScopeRenderer
}
// ScopeAccumulator and ScopeGroup:
//   accumulate(_:feed:monitorLUTEnabled: = true, into: MTLCommandBuffer | MonitorSubmission)
//   accumulate(_:burnInLUT:monitorLUT:into:), and (…, submission:, encoder: any MTL4ComputeCommandEncoder)
//   ScopeAccumulator.uniformLength 1280, ScopeGroup.uniformLength 2048; hasData is false before the
//   first accumulation and after one that reshaped the bins failed to encode.
// ScopeRenderer:
//   colorPipeline: MonitorColorPipeline (default SDR Rec.709); setOutputColor(_:signal:displayTransform:monitorStageHasLUT:)
//   render(_:display:target:viewport:clear:into:), prepare(_:display:viewport:target:into: | submission:),
//   draw(with: MTLRenderCommandEncoder | any MTL4RenderCommandEncoder) — sets pipeline, viewport, scissor = viewport,
//   cull none, fill, bindings and an always-pass depth-stencil state with depth or stencil; render(target:) accepts MSAA.
//   isReady (asynchronous engines draw nothing into a format until its pipeline is built);
//   uniformLength 768, graticuleUniformLength 2304.
```

In `.asynchronous`, scopes never compile on the frame thread: the `bgra8Unorm`, `bgra8Unorm_srgb`, `rgba16Float`, `bgr10a2Unorm` and `rgba8Unorm` general render pipelines start building at init; any other format draws nothing until built (call `ScopeEngine.prepare(target:)` up front). In `.off`, the four all-tools fused kernels build at init on compiler threads and groups run unfused until they are ready. A `.synchronous` engine records a failed build and falls back the same way (a group to per-member accumulation); only a failed general render pipeline makes drawing throw.

Status, not failure: a tool that cannot run on the given signal shows an explicit reason in `MonitorStatus` and is skipped. Examples: a log false-colour mode on a non-log source, stops on an unlabelled source (`requiresKnownTransfer`), peaking without an analysed mask, a display transform under a LUT (`lutOnMonitorStage`), an HDR transform on an SDR source (`requiresHDRSource`) or HDR passthrough into an SDR output (`requiresHDROutput`). The picture is still drawn.

## Target encoding and HDR

- The pass writes values in `MonitorPass.outputColor`'s encoding. `.signalNative` (the default) draws SDR sources exactly as W1 did (bit-exact test against the committed W1 shader); PQ and HLG sources stay in their own transfer and primaries. Other encodings: `.sdr(.bt1886 | .sRGB | .gamma22)`, `.extendedLinear` (keeps negative and above-white values), `.pq`, `.hlg`, on Rec.709, Display P3 or Rec.2020 primaries. Graphics white defaults to 203 cd/m² (BT.2408).
- Tag the layer with `outputColor.layer(for:displayTransform:monitorStageHasLUT:)` (`MonitorLayerColor`: pixel format, `kCGColorSpace…` name, EDR flag, suggested `CAEDRMetadata`); MonitorKitUI applies it (`apply(to: CAMetalLayer)`, exact power-law ICC spaces where Core Graphics names none or decodes differently, e.g. BT.1886 on P3). HDR encodings want an `rgba16Float` EDR layer.
- Each encoding and display transform is its own specialized pipeline (`PipelineKey.color`, function constants 10–14: transform, picture transfer, target transfer, roll-off, clip). The EDR headroom is a uniform outside every pipeline and cache key: changing it rebuilds nothing and allocates nothing. An output whose transfer and primaries equal the picture's (and that does not roll off) needs no conversion (`MonitorColorPipeline.convertsToTarget` false) and uses the native pipeline.
- A signal-native linear picture (an extended-linear layer) keeps values up to ±65504; every other picture written without conversion is clipped to 0…1. For `*_srgb` targets the pass linearizes first, so the hardware encode is correct (fixed per pipeline, not branched per pixel).
- Overlays (zebras, false-colour grey, peaking, guides, clip indicators, navigator) are authored as Rec.709 SDR at graphics white and encoded on the CPU for the target only when settings change: 58 % PQ / 75 % HLG on HDR layers, so they are never blinding. On native layers they stay as authored only for BT.1886 or sRGB on Rec.709 primaries.
- Scope colours are authored as Rec.709 BT.1886 SDR; on any other encoding each pixel is un-premultiplied, decoded, converted to the target primaries, encoded and premultiplied again (within 1e-3 of `MonitorColorPipeline.overlayColor`; graphics white 58.07 % PQ, 75 % HLG, 1.0 extended linear). A host drawing a scope into the same layer as a PQ/HLG picture sets `renderer.colorPipeline = pass.colorPipeline`; otherwise it writes SDR values onto an HDR-tagged layer.
- HLG is always encoded and decoded for the 1000 cd/m² reference display; `hlgNominalPeak` is only the PQ-to-HLG roll-off target (at most 1000).
- Display transforms (`MonitorState.displayTransform`, applied after the monitor LUT): `logToRec709` (MonitorKit display assist v1), `hdrToSDR` (PQ: BT.2408 Annex 5 EETF; HLG: SDR-camera scene light), `hdrPassthrough` (roll-off to the EDR headroom). The math is in MATH.md §5.1.

## Quality bars

- **Correctness:** every GPU path matches the CPU reference in Core within documented tolerances: exact for classification boundaries, ≤ 1/1023 for decode at integral codes, ≤ 1e-4 for LUT interpolation, ≤ 1e-5 for the output-colour paths. Tests cover every layout, bit depth, range, matrix, chroma siting, LUT size (2/17/33/65) and interpolation mode. Metal 4 and classic produce bit-identical bytes (16 picture cases × 2 frames, every scope kind, draws in 5 formats).
- **Shader precision:** decode and classification use correctly rounded division so boundaries at integral codes are exact (940 is exactly 100 IRE; the W1 bit-for-bit tests enforce it, so never turn them into reciprocal multiplications). Output-colour transfer math uses `fast::pow`, `fast::exp2`, `fast::log2`, `fast::divide` and reciprocal constants, bounded by the GPU-vs-CPU tolerance tests. Integer remainders by a run-time divisor go through an exact float quotient (`mk_modulo`): integer division by a run-time value is very slow on Apple GPUs.
- **Math:** constants trace to primary sources (Sony S-Log3 technical summary, ARRI LogC3/LogC4 white papers, ITU-R BT.709/1886/2020/2100, Report BT.2408, SMPTE ST 2084, RP 177, CIE 15, EBU R128/Tech 3341/3342, ITU-R BS.1770, IEC 60268-10/17/18). The sources are listed in `Docs/MATH.md`.
- **Performance** (GPU timestamps on the dev machine, M4 Max, minimum of N interleaved runs; the GPU is shared, so budgets carry margin). Enforced by the benchmark tests:
  - Picture pass, 4K v210 with every tool: ≤ 0.35 ms to 1080p (measured 0.29), ≤ 0.40 ms to 1600×900 (0.33), ≤ 0.5 ms at any smaller window (720p 0.22, 540p 0.14). Not budgeted: 2560×1440 0.56 ms, 4K 1:1 0.70 ms.
  - Every output encoding, PQ and HLG included, within 1.10× + 10 µs of signal-native SDR. Display transforms are not part of that bar (+8 to +16 % tools off).
  - Focus mask at 4K on the source stage ≤ 0.24 ms (0.113). On a LUT stage with a 33³ LUT it measures 0.48 ms tetrahedral / 0.55 ms trilinear, guarded at 0.52 / 0.6 ms (over the old 0.4 ms target; see PROGRESS open items).
  - Four feeds (4 analyses, 4 × 1080p with every tool, 4 × 540p) into one 4K target ≤ 2.0 ms in one `MonitorMultiview` pass (1.56; eight chained passes 1.96).
  - Scope accumulation of every 4K pixel ≤ 1 ms (single scopes 0.32–0.42, fused three-scope group 0.62 source / 0.78 output stage).
  - Freeze of a 4K v210 frame ≤ 0.5 ms (0.043; 22.3 MB of planes while frozen).
  - CPU per surface in steady state: classic encode < 30 µs in a debug build (median 7.6–8.8 µs debug, 6.5 µs release); Metal 4 render encode ≤ 15 µs debug / 10 µs release (9.4 / 5.3), compute encode, host prepare + draw and analysis ≤ 10 µs (7.2, 4.8, 4.7 debug). Zero heap allocations beyond the Metal calls themselves (measured).
  - Audio: all meters on 16 channels at 48 kHz cost 0.30 % of a core in release (the bound scales with the sample rate: K-weighting and the true-peak FIR grow with fs, the PPM stops growing above about 192 kHz).
- **Memory:** persistent memory is documented and tested (`persistentMemoryBytes`). A feed owns one r8 focus mask at source size (8.3 MB at 4K) only while peaking is on (`analyze` with focus off releases it after the frames in flight), Freeze planes only while frozen, and on Metal 4 one 16 KB ring page. A surface owns nothing on the classic path (guides are analytic) and one ring page on Metal 4. Scope bins and trace textures are sized to the scope resolution, not the frame; the graticule texture is r8 rounded up to 64-px multiples (it shrinks only when more than 2× too big); on minified axes the resolve writes a plot-pixel sub-rect of the bins-sized trace.
- **Tests:** XCTest. GPU tests skip cleanly (`XCTSkip`) when no Metal device is present; Metal 4 tests skip without a Metal 4 device. Allocation-count tests skip under `MTL_DEBUG_LAYER` (the debug layer allocates inside Metal's calls). The suite runs clean under `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1`.
