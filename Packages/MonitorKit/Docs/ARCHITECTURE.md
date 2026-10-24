# MonitorKit architecture contract

The binding contract for everyone working on MonitorKit. User-facing documentation: [README](../README.md), [FEATURES](FEATURES.md), [API](API.md), [INTEGRATION](INTEGRATION.md). Product scope is in [`docs/MONITOR_LIBRARY_PLAN.md`](../../../docs/MONITOR_LIBRARY_PLAN.md) and device research in [`docs/MONITOR_DEVICE_INVENTORY.md`](../../../docs/MONITOR_DEVICE_INVENTORY.md) (both in the Ultracam repo). The constants and formulas are in [`MATH.md`](MATH.md).

## Platform

- macOS 26+ / iOS 26+, Apple silicon. Swift 6 language mode, tools 6.2, warnings are errors.
- Metal Shading Language 4.0 (4.1 on macOS/iOS 27), compiled at runtime from `.msl` text resources with `MonitorShaders.compileOptions` (safe math). `makeLibrary(source:)` uses the OS compiler, so no Metal toolchain is needed. `MonitorShaders.libraryDescriptor(parts:)` gives the same source to an `MTL4Compiler` (tested to produce identical output). All MSL symbols are prefixed `mk_`.
- Two encode paths with bit-identical pixels: classic (`MTLCommandBuffer`) and Metal 4 (`MonitorSubmission` over an `MTL4CommandBuffer`). One set of pipeline states serves both (device-built states are valid in MTL4 encoders; no second compile).
- Pipeline builder: by default the device builds the library and pipelines. `MonitorEngine(…, compiler:)` takes the host's `MTL4Compiler` instead: the library (`libraryDescriptor(parts:)`), the picture render and compute pipelines (`MTL4RenderPipelineDescriptor`, `MTL4ComputePipelineDescriptor`), the focus kernels and Freeze's copy kernels are then built by it (with the host's lookup archives, if its compiler has them). Its render pipelines carry no depth or stencil format and draw in any host pass. A host compiler with a pipeline data set serializer must not be used for asynchronous specialization: on macOS 27 (SDK 27.0) an asynchronous build by such a compiler crashes in Metal's compiler scheduler, so record with a separate compiler, as `MonitorPipelineArchive` does.
- Persistent warm start: `MonitorEngine(…, cacheDirectory:)` and `ScopeEngine(…, cacheDirectory:)` build through a `MonitorPipelineArchive` in the host's caches directory. The archive owns a plain `MTL4Compiler` (it uses and fills the system shader cache) that builds the library and every pipeline, each first looked up in the archive files earlier launches saved (`lookupArchives`, one load, no compile); a second compiler with an `MTL4PipelineDataSetSerializer` records the session at each save, synchronously, and writes a new file (`serializeAsArchiveAndFlush`). A host `compiler` passed with a `cacheDirectory` is then unused; `engine.compiler` reports the one used. Files are keyed by a SHA-256 of the shader source, compile options, GPU, OS build and validation settings, and named by a SHA-256 of their bytes, which are verified before Metal reads them; each archive is used once in a build when opened (Metal re-reads the file at its first use and raises an uncaught exception if it is gone). Only the newest verified file is opened at init (it holds the whole last session); older ones (at most `maximumFiles`, 3, per key) are opened at the first pipeline it lacks. Pixels are identical with or without a cache. `ScopeEngine` builds with the device unless made with a `cacheDirectory`.
- No third-party dependencies.

## Zero-overhead contract (every rule is tested)

1. **Host GPU objects.** The library never creates an `MTLDevice`, command queue, command buffer, command allocator, thread or dispatch queue. The one exception is the batteries-included view tier in `MonitorKitUI`: a convenience-mode `MonitorMetalView`, `MonitorView`, `ScopeView` or `ScopeStackView` creates a command queue only when none is given, and commits its own command buffers (see the UI tier below). `MonitorRenderer` itself creates nothing; when no `ScopeEngine` is given it builds the shared one on the existing global queue (`DispatchQueue.global(qos: .userInitiated)`), never on the display thread.
   - Asynchronous compiles run on Metal's compiler threads. On an engine built with a `compiler` (or a `cacheDirectory`), asynchronous specialization awaits the Swift overlay's async-only `MTL4Compiler` API (`makeRenderPipelineState(descriptor:)`, `makeComputePipelineState(descriptor:)`) from `Task.detached(priority: .utility)`. A `MonitorPipelineArchive` saves pipelines built after warm-up from the same kind of utility-priority task, `MonitorPipelineArchive.saveDelay` (2 s) after the last new one; its file I/O blocks one cooperative-pool thread for tens to a few hundred milliseconds. Both run on Swift's cooperative pool; the library still creates no thread or queue of its own.
2. **Encode, never commit.** Per-frame calls take an `MTLCommandBuffer` (classic) or a `MonitorSubmission` (Metal 4) and only encode into it. They never commit, wait or add handlers. On Metal 4 the library never begins or ends a command buffer either. A source-scan contract test checks both paths.
3. **Borrowed inputs.** A `MonitorFrame` wraps textures the host already has, e.g. from a `CVMetalTextureCache` over an IOSurface `CVPixelBuffer`, or from `MonitorTextureCache` (IOSurface-keyed textures made once, resident once, for Metal 4 hosts). The library never copies, stages or blits frame pixels. The only copy anywhere is Freeze, which the user asks for explicitly; it is a compute kernel (`mk_copyUint` / `mk_copyFloat`; BGRA8 and BGR10A2 planes are stored as RGBA8 / RGB10A2), never a blit.
4. **Any output.** Draw into any render target: a drawable (including `framebufferOnly` drawables in `bgr10a2Unorm`, `rgba16Float` and `bgra8Unorm`, tested with real `CAMetalLayer` drawables), an offscreen texture, a viewport inside the host's render pass (depth, stencil, MSAA and further colour attachments described by `MonitorRenderTargetFormat`), or, on Metal 4, a compute write into a shader-writable target (`encodeCompute`).
5. **No per-frame allocation.**
   - GPU: pipelines are built at init or on first use of a pixel format. Persistent textures and buffers are recreated only when size, format or settings change.
   - Uniforms: classic path through `set*Bytes`. Metal 4: each pass, feed, accumulator, group and renderer owns a `MonitorUniformRing` (one shared, write-combined, resident buffer of `framesInFlight` slots, made on first use). A slot is rewritten only when its parameters change, and only after the last submission that read it completed; steady state writes nothing and binds the same slot. A host may instead pass a `MonitorUniformAllocator` in `MonitorSubmission.uniforms` (256-byte aligned, resident, valid until completion), sized from the `uniformLength` constants below.
   - Residency (Metal 4): changes are found by object identity and the set is committed only when something joins or leaves it; steady state makes no residency commit (tested).
   - CPU: the encode path makes no heap allocation of its own (measured against the same Metal calls made inline). No arrays are built per frame; derived data is cached behind an `Equatable` key. Per-frame code uses `while` loops with direct subscripts (no `for`-in, `enumerated()`, `first`, `contains`), so the zero-allocation tests hold in debug builds.
6. **No CPU readback on the frame path.** Scope data stays on the GPU. Small numeric results go into a shared buffer the host can read later (`ScopeStatisticsReader`).
7. **Fusable.** `MKLUT.msl` and `MKDecode.msl` are self-contained. A host can prepend them to its own kernel and call `mk_applyLUT` / `mk_decodeRGB` in its own pass, compiling with `MonitorShaders.compileOptions` or `libraryDescriptor(parts:)`. `MonitorLUT` shaper rows are the texture width wide (at least 8), so a host must use the shipped `MKLUT.msl` (`mk_shaperEntry(lut, i, n, w)`), not an older copy.
   - The two fusable parts are each guarded as a whole file (`MK_LUT_MSL_VERSION`, `MK_DECODE_MSL`), so a host source that includes one twice compiles it once. `MKMonitor.msl` and `MKScopes.msl` are not guarded (they are compiled once, by MonitorKit). `MKLUT.msl` is keyed by its layout version, `MonitorShaders.lutLayoutVersion` (2: the 80-byte `mk_LUTParams` = `LUTParameters`, with a 1D shaper). An older copy (plain `MK_LUT_MSL` guard, 48-byte parameters) in the same source fails to compile in either order (an `#error` before, a redefinition after), so one layout's bytes can never be bound to the other's struct. Bind `LUTParameters` by `MemoryLayout<LUTParameters>.size`, never a hand-written struct.

### Metal 4 rules

- **One queue, one timeline.** All of an engine's Metal 4 work goes on one `MTL4CommandQueue`. Submission indices start at 1 (0 means none; `MonitorSubmission.init` and `MonitorResidency.observe` trap on 0). Every encode into one command buffer shares its index.
- **Completion contract.** `completedIndex` is the highest *contiguous* completed submission: that one and every earlier one have completed or were abandoned. Feedback handlers can complete out of order, so a host keeps a done-set and advances a watermark (`Tests/MonitorKitTests/Metal4Support.swift`). Reporting a non-contiguous maximum would reuse ring slots and free resources still in flight. A host that limits frames in flight with a semaphore can use `MonitorSubmission(commandBuffer:index:framesInFlight:)` instead.
- **Residency.** `MonitorEngine.residency` (a `MonitorResidency`) holds everything the library owns: placeholders, focus masks, Freeze planes, rings, argument tables' resources and the feeds' LUT textures (counted, so a LUT shared by two feeds stays until both release it). `ScopeEngine(…, residency:)` can take the same object, so the host attaches one set. The host attaches `residency.set` to its queue once. Host frames and targets stay the host's to make resident (`MonitorFrame.addResidency(to:)` when a texture is first wrapped, e.g. in an IOSurface-keyed cache, never per frame). Call `feed.updateResidency()` before other Metal 4 work reads a feed's LUTs outside MonitorKit.
- **Argument tables.** Each object owns one table, made on its first Metal 4 encode (pass 7 textures / 5 buffers, feed 6 / 4, accumulator 5 / 6, group 5 / 15, renderer 2 / 3), or ahead of it for the scope objects (`ScopeAccumulator`, `ScopeGroup` and `ScopeRenderer.prepareMetal4()`). Metal 4 snapshots bindings at each draw or dispatch, so reusing a table across encodes is safe. In a host encoder the library binds its own table; hosts rebind theirs afterwards.
- **Uniform sizes per encode** (`uniformLength`, 256-byte offsets): `MonitorPass` 5120 B (the frame block holds the 160 B `mk_PassFrames`: the source and the output reading's `FrameParameters`; two LUT blocks, `PassParameters` 1520 at offset 768, `GuideParameters` 2592 at 2304), `MonitorFeed` 1024, `ScopeAccumulator` 1280, `ScopeGroup` 2048 (fused pass; unfused members ask their own), `ScopeRenderer` 768 per `prepare` plus `graticuleUniformLength` 2304 only when the graticule changes. Use the constants, not hand-computed struct sizes.
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

- **Warm-up.** `MonitorEngine.warmUp(targets:layouts:surfaces:)` builds, on the calling thread, every pipeline a first frame could need: for each target format (default `MonitorEngine.standardTargetFormats`: `bgr10a2Unorm`, `rgba16Float`, `bgra8Unorm`) and layout, the all-tools picture pipeline, the focus kernels and Freeze's copy kernels; for each `MonitorSurfaceConfiguration`, the pipeline specialized to that surface's tool set and colour path (peaking counted as drawn when `state.focus.enabled`; until a frame is analysed the surface draws with the all-tools pipeline). `ScopeEngine.prepare(pixelFormats:)` (default `ScopeEngine.drawablePixelFormats`) does the same for scope render pipelines; `isPrepared(pixelFormat:)` reports it. Call them off the frame path at start-up; a switch to an HLG layer then never waits for a compile. With a pipeline archive, `warmUp` and the bulk `ScopeEngine.prepare(pixelFormats:)` / `prepare(settings:layouts:pixelFormats:)` save it before returning (a few hundred milliseconds on a cold key, a no-op when nothing was compiled); pass `save: false` to warm several engines and then call `pipelineArchive?.save()` on each once, so one engine's save never delays the next one's builds. `ScopeEngine.prepare(target:)` leaves the save to the scheduled one. Pipelines built later are saved 2 s after the last one, from a utility-priority task.

### Thread safety

- `MonitorEngine`, `MonitorLUT`, `MonitorResidency`, `MonitorPipelineArchive` and `ScopeEngine` are immutable after init (apart from locked caches) and safe to share (`Sendable`). Specialized pipelines are cached behind a lock and built on Metal's compiler threads.
- Feeds, passes, multiviews, accumulators, groups and renderers are confined: one thread at a time, no internal locks, and not `Sendable` (compile-time protection against sharing). Create and use them on the render thread, move them with `sending`, or keep them on a global actor whose executor is the render thread. A `ScopeRenderer` and the accumulators it draws stay on one thread (its Metal 4 `prepare` updates their residency). `ScopeStatisticsReader` is the `Sendable` reader for UI threads.
- `MonitorSubmission` is a per-frame value and not `Sendable`. State types are values.
- `MonitorKitUI`'s scene handles (`MonitorScene`, `MonitorSource`, `MonitorSurface`, `MonitorScopeOverlay`, `MonitorCompletionReporter`) are `Sendable` and lock-protected; `MonitorSource.submit` never waits for the GPU.
- `MonitorTextureCache` is `Sendable` (one short lock per lookup; the idle sweep runs inside a lookup).

### Lifetimes

- **Classic path.** Per-frame encodes may go into command buffers created without retained references. Hosts keep frames and `MonitorLUT`s alive until those buffers complete. A feed keeps a replaced or released focus mask in a ring of `MonitorFeed.retiredFrames` (3) slots, each aged by later `analyze` calls; scopes keep replaced bins (`ScopeAccumulator`, aged per accumulation) and replaced trace and graticule textures (`ScopeRenderer`, aged per `prepare`) the same way. Retired resources are not counted in `persistentMemoryBytes`; `MonitorFeed.retiredMemoryBytes` shows them, and `releaseRetired()` drops them once every command buffer that used the feed has completed (a feed nobody analyses any more never ages them). Hosts using unretained command buffers keep accumulators, groups and renderers alive until their last command buffer completes.
- **Metal 4.** The library releases nothing early and needs no retain or retire hooks from the host. A replaced mask, Freeze plane, LUT texture, ring or bin buffer, and everything a feed, pass, accumulator, group or renderer owns when it is deallocated with work in flight, stays alive and resident until the submission that last used it completes (`MonitorResidency`, keyed by submission index). Keep the engines alive until their work completes. Resources retired after the host's last encode wait for the next `observe`; hosts can call `residency.release(through:)` from their completion handler. A LUT replaced with `feed.burnInLUT = nil` stays referenced until the feed's next Metal 4 encode or deinit (by design). `ScopeEngine` retires its placeholders from a shared residency set on deinit.
- **Frame texture cache.** `MonitorTextureCache` adds each texture to its `MonitorResidency` once, when made, and retires it (released once the submissions that may read it complete) after `idleLifetime` seconds unused, on `flush(owner:)`, `removeAll()` or deinit. A texture retains its IOSurface, not the pixel buffer; the returned frame retains the pixel buffer, so hosts keep frames until their work completes, as with any frame.
- **Frozen frames.** A `MonitorFrame` returned by `freeze` is valid while the host holds it. `unfreeze()` releases the planes by default (`unfreeze(keepingMemory: true)` keeps them for a host that toggles Freeze often). On Metal 4 the released planes leave residency once their last submission completes, and every MonitorKit Metal 4 encode that reads a held frozen frame (pictures, analysis, Freeze, scope accumulations and groups) calls `MonitorFrame.keepResidentIfReleased(in:)` to make it resident again for that submission. A re-freeze into the same planes needs no host ordering on Metal 4 (the library waits for earlier readers); on the classic path encode it after every command buffer that still reads the previous frozen frame.
- **UI tier.** `MonitorRenderer` holds replaced frames and LUTs for `max(3, framesInFlight)` classic encodes, or until `completedIndex` passes them on Metal 4. An encode may span two command buffers (`encodePictures`, then `encodeScopes` committed after it on the same queue); completion (`noteCompleted(through:)` or `MonitorCompletionReporter`, thread-safe and monotonic) is reported only after the later one completes. A paused or hidden convenience view commits one empty marker command buffer with a single completion handler per pause, then releases idle frames and focus masks.

## Modules and ownership

| Target | Contents |
| --- | --- |
| `MonitorKitCore` | `MonitorState` (fail-closed JSON: `kind` + `schemaVersion` 2) and settings (`pictureStage`, zebras, false colour, focus, guides, geometry, display adjustments with white-point trim, `DisplayTransformSettings`, `ClipIndicatorSettings`), `SignalDescription` (with `primaries` and `outputReading`, a `SignalReading`), `PixelLayout`, `LogCurve`, `MonitorFrameGeometry`, `MonitorLayout` (with the clean `aperture`) and `GuideRaster`, `CubeLUT`, the CPU LUT reference and `LUTOutputEncoding`, false-colour tables (`FalseColorTable`, `usesFullRangeARRI(signal:layout:)`), `MonitorOutputColor` / `MonitorLayerColor` (`OutputColor.swift`), `ColorPrimaries` / `ColorMatrix` (`Colorimetry.swift`), the reference math (`ColorMath`, `DecodeReference`, `MonitorColorPipeline`, `DisplayAssist`, `HDRToSDR`, `BT2446MethodC`, `ToneMapEETF`, `WhitePointTrim`, transfer functions, Sony, ARRI, EL Zone) |
| `MonitorKit` | `MonitorFrame` (with `cleanAperture`, `isProcessed`, `geometry`), `MonitorShaders` (`lutLayoutVersion`), `MonitorLUT`, `MonitorEngine` (optional `MTL4Compiler` or `cacheDirectory`; `warmUp` and `MonitorSurfaceConfiguration` in `MonitorWarmUp.swift`), `MonitorPipelineArchive` (the persistent warm start, shared with `MonitorKitScopes`), `MonitorFeed` (analysis, Freeze), `MonitorPass`, `MonitorMultiview`, `MonitorStatus`, `MonitorTextureCache`, the Metal 4 types (`Metal4.swift`: `MonitorSubmission`, `MonitorUniformAllocator`, `MonitorUniformRing`, `MonitorResidency`) and the Metal 4 encode paths (`MonitorFeedMetal4.swift`, `MonitorPassMetal4.swift`). Shaders: `MKLUT`, `MKDecode`, `MKMonitor` |
| `MonitorKitScopes` | `ScopeSettings` (with `ScopeLevelRange`, `ScopeTracePalette` and the `ultracamLegacy` preset), `ScopeEngine`, `ScopeAccumulator`, `ScopeGroup` (one fused pass for a stage's waveform, histogram and vectorscope), `ScopeRenderer` (HDR-aware via `colorPipeline`), `ScopeStatisticsReader`, graticules, `RetiredResources`, and the Metal 4 paths (`Scope*Metal4.swift`, `ScopeMetal4.swift`). Shader: `MKScopes` (compiled after `MKLUT` + `MKDecode`) |
| `MonitorKitAudio` | `AudioMeter`, `AudioMeterConfiguration`, `AudioMeterSnapshot`, `LoudnessMeter`, `LoudnessEngine`, `MeterScale` (marks and zones per meter type), reset generations. Pure Swift + Accelerate |
| `MonitorKitUI` | Scene handles (`MonitorScene`, `MonitorSource`, `MonitorSurface`, `MonitorScopeOverlay`, `MonitorRegion`), `MonitorRenderer` (drawable-free, classic or Metal 4), `MonitorMetalView` (CAMetalLayer, `CAMetalDisplayLink`), layer colour (`MonitorLayerColor.apply(to:)`, exact ICC spaces), headroom, `MonitorMagnifier`, SwiftUI views (`MonitorView`, `MonitorSceneView`, `ScopeView`, `ScopeStackView`, `ClipReadout`, `MonitorStatusOverlay`, `ScopeIREScaleView`, `MonitorTileToolbar`), controls, `FalseColorLegend` / `FalseColorLegendView` (list and captioned styles), `AudioMeterView` |

## Data flow per frame (Encode tier)

```
host frame (CVPixelBuffer) ──wrap──▶ MonitorFrame (borrowed textures)
                                         │
       feed.analyze(frame, focus, into:)  ◀──┤ once per frame: focus mask at source resolution (only while some surface shows peaking)
       scopes.accumulate(frame, feed:, into:) once per frame per scope stage (or one ScopeGroup), at the host's scope rate
                                         │
 for each surface: pass.encode(frame, feed, state, target, viewport, into:)   (or MonitorMultiview: all surfaces in one render pass)
       one fragment pass (or compute kernel), its pipeline specialized to the surface's tool set and colour path:
                      decode (separable filter: nearest 1:1, Catmull-Rom magnified, box minified),
                        inside the clean aperture
                      → burn-in LUT (output stage) → monitor LUT (monitor stage)
                      → the picture stage the surface shows (source, output or monitor)
                      → false colour | display transform → display adjustments (incl. white-point trim)
                        → output conversion (linearize, 3×3 in linear light, optional roll-off, target encode)
                      → zebras → clip indicators → peaking → matte/guides (analytic strokes)
                      → navigator inset while magnified
       scopeRenderer.render(accumulator, display, target, viewport, into:)
```

- Signal stages (one decode per pixel feeds all three, or two when the signal has a distinct `SignalDescription.outputReading`): `source` (the camera signal, range-expanded, matrix-decoded with the declared `range` and `matrix`, never clipped); `output` (after the feed's burn-in LUT: what the real output carries; a host that burns the LUT in its own kernel uses the same `MonitorLUT` and `mk_applyLUT`, so preview and output are identical); `monitor` (after the monitor-only LUT). The Output and Monitor stages decode the same filtered codes with `outputReading` (the reading the host's burn-in and real output use, e.g. legal range for a camera declared full on a legal link, BT.709 for a SMPTE 240M source), with or without a LUT; `MonitorFrame.parameters(for:)` gives each stage's `FrameParameters` to single-stage kernels (focus analysis, scopes). A specialized pipeline compiles the second decode only when something drawn reads those stages (MATH.md §13).
- **Picture stage.** `MonitorState.pictureStage` (default `.monitor`) picks the stage the picture itself shows: `.output` shows what the output carries (burn-in LUT, no monitor LUT), `.source` the camera signal with no LUT, so a display transform can apply even while the feed burns a LUT in. Tools keep measuring their own stages. The choice is function constant 16 (`MK_PICTURE_STAGE`) in a specialized pipeline; the all-tools pipeline (constant value 3) reads it from `PassParameters.falseColor.z`. `MonitorStatus.pictureStage` reports it, and the `.picture` entry of `activeLabels` names a non-default stage and a code-value view ("Source · S-Log3 code values"): a log or unlabelled signal on a stage no LUT touched with no display transform (`MonitorStatus.isCodeValueView`, `codeValueViewNote`).
- **Clean aperture.** `MonitorFrame.cleanAperture` (frame pixels, top-left origin; ISO/IEC 14496-12 `clap`, see MATH.md §12) crops what is shown: the layout, the picture, the focus footprint, guides, the navigator and the display aspect follow it, while analysis and scopes still cover the whole frame. A magnified picture's bicubic taps at the aperture edge read the frame's real pixels just outside it (it is the continuous image). `MonitorLayout.aperture` is the region shown and `pictureWidth`/`pictureHeight` its size; the layout's maps return frame pixels, and `pictureFraction`/`picturePoint` convert to the aperture fractions magnification uses. A pixel aspect ratio outside `MonitorFrameGeometry.pixelAspectRatioRange` (1/16…16) or not finite is drawn with square pixels and reported as `.unsupportedGeometry` on `.picture`.
- **Processed frames.** `MonitorFrame.isProcessed` marks a picture that is not the camera's own signal (a programme mix, a scaled or graded render): log false colour and peaking then report `.requiresCameraSignal`, and `MonitorFeed.analyze` encodes nothing for it.
- Tools measure their own `SignalStage`, never the transformed or output-encoded picture. Log false-colour modes always classify the source with the per-channel native-log decode. Zebras, the six-band and custom false colour, clip indicators, focus peaking and scopes each choose a stage.
- **LUT convention.** LUT output is Rec.709 display R'G'B' on every stage. A LUT on the picture's stage (the burn-in LUT unless `pictureStage` is `.source`; the monitor LUT too on `.monitor` when `state.monitorLUT`) makes the picture Rec.709 SDR and every display transform unavailable (`.lutOnMonitorStage`), matching Sony's Gamma Display Assist, which is off while a LUT is applied. `MonitorFeed.monitorStageHasLUT(for:)` (that is, `MonitorState.pictureHasLUT(burnInLUT:monitorLUT:)`) is the public rule; pass it to `MonitorOutputColor.layer(for:…)` and `MonitorEngine.prepare(…)`, and re-tag the layer when LUTs change. HDR-to-HDR LUTs are not modelled.
- **One decode convention across modules** (tested end to end in `ScopePictureAgreementTests` and, with a distinct output reading, `ScopeOutputReadingTests`): every stage decodes with its own reading (`SignalDescription.signal(for:)`: the source reading on Source, `outputReading` on Output and Monitor); stage luma is that reading's decoded transport Y' when no LUT touched the stage, else Rec.709 Y' of the LUT result (`mk_stageLuma` in the pass, the same rule in `MKScopes`). Boundaries are inclusive at the lower edge, so a 940 code is 100 IRE for zebras, false colour, clip indicators and scope clip counts alike. Scope statistics (Y' clip counts, luma min/max/average) always use this rule whatever `ScopeColorimetry` is; colorimetry drives only the drawn luma, the Y'CbCr parade and the vectorscope. Scope clip counts compare R', G', B' and Y' in percent with the same Float operations as the picture's clip indicator (`v·100 ≥ level`), so `ScopeStatistics.clippedHigh/Low` count exactly the pixels `ClipIndicatorSettings` marks.
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
  public let compiler: (any MTL4Compiler)?             // nil: the device builds; with a cacheDirectory, the archive's
  public let pipelineArchive: MonitorPipelineArchive?  // the persistent warm start (nil without a cacheDirectory)
  /// Compiles the library and compute pipelines (Freeze copy kernels start building
  /// at init on an asynchronous engine). Specialized per-tool-set picture pipelines
  /// build asynchronously by default; until one is ready a surface draws with the
  /// all-tools pipeline, which reads the output colour and transform from the
  /// uniforms (function constant 15): one per target format and layout, pixels
  /// identical to the specialized pipeline for native SDR and within 1e-5 otherwise.
  public init(device: MTLDevice, specialization: PipelineSpecialization = .asynchronous, framesInFlight: Int = 3,
              compiler: (any MTL4Compiler)? = nil) throws
  /// The same with a persistent warm start in the host's caches directory (nil: none).
  public init(device:, specialization: = .asynchronous, framesInFlight: = 3, compiler: = nil, cacheDirectory: URL?) throws
  /// Optional warm-up: the colour-independent all-tools render pipelines, three
  /// focus pipelines per layout (source, burn-in, both LUTs) and the Freeze copy kernels.
  public func prepare(pixelFormat: MTLPixelFormat, layouts: [PixelLayout]? = nil) throws
  public func prepare(target: MonitorRenderTargetFormat, layouts: [PixelLayout]? = nil) throws
  public func prepare(target:layouts:outputColor:signal:displayTransform:monitorStageHasLUT:) throws
  public func prepareCompute(pixelFormat:layouts:outputColor:signal:displayTransform:monitorStageHasLUT:) throws
  /// Everything a first frame could need, on the calling thread, off the frame path. Returns pipelines built.
  public static let standardTargetFormats: [MTLPixelFormat]   // bgr10a2Unorm, rgba16Float, bgra8Unorm
  @discardableResult public func warmUp(targets: [MonitorRenderTargetFormat] = …, layouts: [PixelLayout]? = nil,
                                        surfaces: [MonitorSurfaceConfiguration] = [], save: Bool = true) throws -> Int
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
  public func monitorStageHasLUT(for state: MonitorState) -> Bool   // follows state.pictureStage
  public func hasFocusMask(for frame: MonitorFrame) -> Bool
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

```swift
/// The persistent pipeline warm start (`MonitorPipelineArchive.swift`).
public final class MonitorPipelineArchive: @unchecked Sendable {
  public struct Statistics { filesLoaded, filesRejected, staleFilesRemoved, hits, misses, saves, lastError }
  public static let saveDelay: TimeInterval            // 2 s after the last newly built pipeline
  public let directory: URL; public let name: String; public let key: String; public let maximumFiles: Int  // 3
  public var statistics: Statistics; public var files: [URL]   // files in use for lookups, newest first
  @discardableResult public func save() -> Bool        // off the frame path; a no-op when nothing new was compiled
}
// Files: <name>-<gpu hash>-<key hash>-<content hash>.mtl4archive. The key hashes the shader source,
// compile options, GPU, OS version and build, validation settings and format version; the content
// hash is verified before Metal reads a file.

public struct MonitorFrame: @unchecked Sendable {
  public init(layout:width:height:packed:luma:chroma:signal:pixelAspectRatio: = 1, cleanAperture: MonitorRect? = nil) throws
  public static func wrap(_ pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache, signal: SignalDescription? = nil) throws -> MonitorFrame
  public static func layout(for pixelFormat: OSType) -> (layout: PixelLayout, range: CodeRange)?
  public static func signal(of: CVPixelBuffer, range: CodeRange) -> SignalDescription
  public static func cleanAperture(of: CVPixelBuffer) -> MonitorRect?     // clap, y down, clipped
  public static func geometry(of: CVPixelBuffer) -> MonitorFrameGeometry
  public var id: UInt64; public var signal: SignalDescription; public var pixelAspectRatio: Double
  public var cleanAperture: MonitorRect?; public var isProcessed: Bool; public var geometry: MonitorFrameGeometry { get }
  public var parameters: FrameParameters                       // the source reading
  public func parameters(for stage: SignalStage) -> FrameParameters  // that stage's reading (outputReading on Output/Monitor)
}

// MonitorKitCore (Signal.swift)
public struct SignalReading: Hashable, Codable, Sendable { range: CodeRange; matrix: YCbCrMatrix }
extension SignalDescription {
  public var outputReading: SignalReading?             // the Output and Monitor stages' reading; nil: the source's
  public var sourceReading: SignalReading; public var effectiveOutputReading: SignalReading
  public var hasDistinctOutputReading: Bool; public var outputSignal: SignalDescription
  public func signal(for stage: SignalStage) -> SignalDescription
}

public final class MonitorTextureCache: @unchecked Sendable {   // IOSurface-keyed, residency-aware (Metal 4 hosts)
  public init(device:, residency:, idleLifetime: Double = 2, capacity: Int = 64)
  public func frame(_ pixelBuffer: CVPixelBuffer, signal: SignalDescription? = nil, owner: UInt64 = 0, now: Double? = nil) throws -> MonitorFrame
  public func makeTexture(iosurface:plane:format:width:height:owner:now:) throws -> MTLTexture
  public func sweep(now:); public func flush(owner:); public func removeAll()
}

extension MonitorLayout { public init(frame: MonitorFrame, state: MonitorState, viewport: MonitorViewport) }
public enum MonitorShaders { static let lutLayoutVersion = 2; static var compileOptions; source(_:); makeLibrary(…); libraryDescriptor(…) }
public final class MonitorLUT { init(device:cube:interpolation: = .tetrahedral, outputEncoding: = .rec709) throws; texture; parameters }
```

`MonitorFrame.id` is fresh per wrapped frame (a host reusing one `MonitorFrame` value across pictures sets it). `MonitorFrame.signal(of:)` reads the colour-primaries attachment (709, 2020 and P3 D65; others stay nil; `SignalDescription` equality includes `primaries`, so compare `effectivePrimaries`). `FrameParameters.matrix.w` is the 4:2:0 vertical chroma offset; `PassParameters.luts.w` the source transfer code; `LUTParameters` carries the 1D shaper rows (`shaperLow`, `shaperScale`).

**Function constants of `mk_picture`** (`MonitorEngine.specializationPrefix`): 0 layout (`MK_LAYOUT`), 1 LUTs read (bit 0 burn-in, bit 1 monitor, bit 2 no distinct output reading is read: the Output and Monitor stages share the source decode), 2 zebras, 3 false colour tiers (bit 0 log modes, bit 1 stage modes), 4 interpolating filter, 5 navigator, 6 peaking, 7 guides, 8 display adjustments, 9 sRGB-encoded target, 10 display transform, 11 picture transfer, 12 target transfer, 13 roll-off, 14 clip indicators, 15 colour stages read from the uniforms (`PassParameters.color`, the all-tools stand-in), 16 picture stage (0 source, 1 output, 2 monitor, 3 read from `PassParameters.falseColor.z`). A specialized pipeline binds all of them; the all-tools pipeline turns every tier on and reads 10–13 and 16 from the uniforms, so one per target format and layout serves every colour setting and stage.

### Scopes

```swift
public final class ScopeEngine: @unchecked Sendable {
  public init(device:, specialization: = .asynchronous, framesInFlight: = 3, residency: MonitorResidency? = nil) throws
  public init(device:, specialization: = .asynchronous, framesInFlight: = 3, residency: = nil, cacheDirectory: URL?) throws
  public let residency: MonitorResidency               // pass MonitorEngine.residency to share one set
  public let pipelineArchive: MonitorPipelineArchive?  // with a cacheDirectory
  public func prepare(pixelFormat:) / prepare(target: MonitorRenderTargetFormat) / prepare(settings:layouts:target:)
  public static let drawablePixelFormats: [MTLPixelFormat]   // bgr10a2Unorm, rgba16Float, bgra8Unorm
  public func prepare(pixelFormats: [MTLPixelFormat] = drawablePixelFormats, save: Bool = true) throws
  public func prepare(settings:layouts:pixelFormats:save: = true) throws
  public func isPrepared(target:) -> Bool; public func isPrepared(pixelFormat:) -> Bool
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
// prepareMetal4() on accumulators, groups (and their members) and renderers makes the argument tables up front.
// ScopeSettings: levelRange (ScopeLevelRange .standard -7…109 % | .minus10To110), display.palette
//   (ScopeTracePalette .standard | .ultracamLegacy), ScopeSettings.ultracamLegacy(mode:stage:) (768 × 256, −10…110,
//   legacy palette, opaque background). Codable, lenient, schemaVersion 1 (no `kind` yet).
```

In `.asynchronous`, scopes never compile on the frame thread: the `bgra8Unorm`, `bgra8Unorm_srgb`, `rgba16Float`, `bgr10a2Unorm` and `rgba8Unorm` general render pipelines start building at init; any other format draws nothing until built (call `ScopeEngine.prepare(target:)` up front). In `.off`, the four all-tools fused kernels build at init on compiler threads and groups run unfused until they are ready. A `.synchronous` engine records a failed build and falls back the same way (a group to per-member accumulation); only a failed general render pipeline makes drawing throw.

Status, not failure: a tool that cannot run on the given signal shows an explicit reason in `MonitorStatus` and is skipped. Examples: a log false-colour mode on a non-log source, stops on an unlabelled source (`requiresKnownTransfer`), peaking without an analysed mask, a display transform under a LUT (`lutOnMonitorStage`), an HDR transform on an SDR source (`requiresHDRSource`), HDR passthrough into an SDR output (`requiresHDROutput`), log false colour or peaking on a processed frame (`requiresCameraSignal`), or a pixel aspect ratio that cannot be shown (`unsupportedGeometry` on `MonitorTool.picture`). The picture is still drawn.

### Persistence

`MonitorState` is fail-closed: it writes `"kind": "MonitorKit.MonitorState"` (`MonitorState.codingKind`) and `schemaVersion` 2, and decoding throws `DecodingError.dataCorrupted` for anything without that `kind` or with a schema below 2 (another type's JSON, such as Ultracam's old `MonitorConfiguration`, which also said `schemaVersion` 1, and MonitorKit's own W1/W2 JSON). Inside a genuine blob every field decodes leniently and is normalized, and newer schemas decode field by field (changes within one `kind` are additive). Hosts catch the error and fall back to defaults or their legacy decoder; `MonitorState(decodingOrDefault:)`, `decodedOrDefault(from:)` and the `@LenientMonitorState` property wrapper do it for them, so a host's own synthesized `Codable` settings survive a foreign blob (a throwing field would fail the whole outer value). `ScopeSettings` (schema 1, no `kind` yet; it never throws), `MonitorOutputColor` and `SignalDescription` stay lenient: missing or malformed fields decode as defaults. The latter two are embedded values with no schema of their own.

## Target encoding and HDR

- The pass writes values in `MonitorPass.outputColor`'s encoding. `.signalNative` (the default) draws SDR sources exactly as W1 did (bit-exact test against the committed W1 shader); PQ and HLG sources stay in their own transfer and primaries. Other encodings: `.sdr(.bt1886 | .sRGB | .gamma22)`, `.extendedLinear` (keeps negative and above-white values), `.pq`, `.hlg`, on Rec.709, Display P3 or Rec.2020 primaries. Graphics white defaults to 203 cd/m² (BT.2408).
- Tag the layer with `outputColor.layer(for:displayTransform:monitorStageHasLUT:)` (`MonitorLayerColor`: pixel format, `kCGColorSpace…` name, EDR flag, suggested `CAEDRMetadata`); MonitorKitUI applies it (`apply(to: CAMetalLayer)`, exact power-law ICC spaces where Core Graphics names none or decodes differently, e.g. BT.1886 on P3). HDR encodings want an `rgba16Float` EDR layer.
- Each encoding and display transform is its own specialized pipeline (`PipelineKey.color`, function constants 10–14: transform, picture transfer, target transfer, roll-off, clip). The EDR headroom is a uniform outside every pipeline and cache key: changing it rebuilds nothing and allocates nothing. An output whose transfer and primaries equal the picture's (and that does not roll off) needs no conversion (`MonitorColorPipeline.convertsToTarget` false) and uses the native pipeline.
- A signal-native linear picture (an extended-linear layer) keeps values up to ±65504; every other picture written without conversion is clipped to 0…1. For `*_srgb` targets the pass linearizes first, so the hardware encode is correct (fixed per pipeline, not branched per pixel).
- Overlays (zebras, false-colour grey, peaking, guides, clip indicators, navigator) are authored as Rec.709 SDR at graphics white and encoded on the CPU for the target only when settings change: 58 % PQ / 75 % HLG on HDR layers, so they are never blinding. On native layers they stay as authored only for BT.1886 or sRGB on Rec.709 primaries.
- Scope colours are authored as Rec.709 BT.1886 SDR; on any other encoding each pixel is un-premultiplied, decoded, converted to the target primaries, encoded and premultiplied again (within 1e-3 of `MonitorColorPipeline.overlayColor`; graphics white 58.07 % PQ, 75 % HLG, 1.0 extended linear). A host drawing a scope into the same layer as a PQ/HLG picture sets `renderer.colorPipeline = pass.colorPipeline`; otherwise it writes SDR values onto an HDR-tagged layer.
- HLG is always encoded and decoded for the 1000 cd/m² reference display; `hlgNominalPeak` is only the PQ-to-HLG roll-off target (at most 1000).
- Display transforms (`MonitorState.displayTransform`, applied after the monitor LUT): `logToRec709` (MonitorKit display assist v1), `hdrToSDR` (PQ: BT.2408 Annex 5 EETF; HLG: Report ITU-R BT.2446-1 Method C; both then BT.2407 §2 into BT.709), `hdrPassthrough` (roll-off to the EDR headroom). The math is in MATH.md §5.1.

## Quality bars

- **Correctness:** every GPU path matches the CPU reference in Core within documented tolerances: exact for classification boundaries, ≤ 1/1023 for decode at integral codes, ≤ 1e-4 for LUT interpolation, ≤ 1e-5 for the output-colour paths. Tests cover every layout, bit depth, range, matrix, chroma siting, LUT size (2/17/33/65) and interpolation mode. Metal 4 and classic produce bit-identical bytes (16 picture cases × 2 frames, every scope kind, draws in 5 formats).
- **Shader precision:** decode and classification use correctly rounded division so boundaries at integral codes are exact (940 is exactly 100 IRE; the W1 bit-for-bit tests enforce it, so never turn them into reciprocal multiplications). Output-colour transfer math uses `fast::pow`, `fast::exp2`, `fast::log2`, `fast::divide` and reciprocal constants, bounded by the GPU-vs-CPU tolerance tests. Integer remainders by a run-time divisor go through an exact float quotient (`mk_modulo`): integer division by a run-time value is very slow on Apple GPUs.
- **Math:** constants trace to primary sources (Sony S-Log3 technical summary, ARRI LogC3/LogC4 white papers, ITU-R BT.709/1886/2020/2100, Report BT.2408, SMPTE ST 2084, RP 177, CIE 15, EBU R128/Tech 3341/3342, ITU-R BS.1770, IEC 60268-10/17/18). The sources are listed in `Docs/MATH.md`.
- **Performance** (GPU timestamps on the dev machine, M4 Max, minimum of N interleaved runs; the GPU is shared, so budgets carry margin). Enforced by the benchmark tests:
  - Picture pass, 4K v210 with every tool: ≤ 0.35 ms to 1080p (measured 0.29), ≤ 0.40 ms to 1600×900 (0.33), ≤ 0.5 ms at any smaller window (720p 0.22, 540p 0.14). Not budgeted: 2560×1440 0.56 ms, 4K 1:1 0.70 ms.
  - Every output encoding, PQ and HLG included, within 1.10× + 10 µs of signal-native SDR. Display transforms are not part of that bar (tools off: HLG → SDR about +9.5 %, PQ → SDR about +16 %).
  - A distinct output reading costs nothing while only the Source is read (0.1320 ms either way with the picture, two zebra sets and clip indicators) and one more decode on the Output stage (+7.4 %), bounded at +5 % / +15 % (`testOutputReadingGPUTime`).
  - Focus mask at 4K on the source stage ≤ 0.24 ms (0.113). On a LUT stage with a 33³ LUT it measures 0.48 ms tetrahedral / 0.55 ms trilinear, guarded at 0.52 / 0.6 ms (over the old 0.4 ms target; see PROGRESS open items).
  - Four feeds (4 analyses, 4 × 1080p with every tool, 4 × 540p) into one 4K target ≤ 2.0 ms in one `MonitorMultiview` pass (1.56; eight chained passes 1.96).
  - Scope accumulation of every 4K pixel ≤ 1 ms (single scopes 0.32–0.42, fused three-scope group 0.62 source / 0.78 output stage).
  - Freeze of a 4K v210 frame ≤ 0.5 ms (0.043; 22.3 MB of planes while frozen).
  - CPU per surface in steady state: classic encode < 30 µs in a debug build (median 7.6–8.8 µs debug, 6.5 µs release); Metal 4 render encode ≤ 15 µs debug / 10 µs release (9.4 / 5.3), compute encode, host prepare + draw and analysis ≤ 10 µs (7.2, 4.8, 4.7 debug). Zero heap allocations beyond the Metal calls themselves (measured).
  - Audio: all meters on 16 channels at 48 kHz cost 0.30 % of a core in release (the bound scales with the sample rate: K-weighting and the true-peak FIR grow with fs, the PPM stops growing above about 192 kHz).
- **Memory:** persistent memory is documented and tested (`persistentMemoryBytes`). A feed owns one r8 focus mask at source size (8.3 MB at 4K) only while peaking is on (`analyze` with focus off releases it after the frames in flight), Freeze planes only while frozen, and on Metal 4 one 16 KB ring page. A surface owns nothing on the classic path (guides are analytic) and one ring page on Metal 4. Scope bins and trace textures are sized to the scope resolution, not the frame; the graticule texture is r8 rounded up to 64-px multiples (it shrinks only when more than 2× too big); on minified axes the resolve writes a plot-pixel sub-rect of the bins-sized trace.
- **Tests:** XCTest. GPU tests skip cleanly (`XCTSkip`) when no Metal device is present; Metal 4 tests skip without a Metal 4 device. Allocation-count tests skip under `MTL_DEBUG_LAYER` (the debug layer allocates inside Metal's calls). The suite runs clean under `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1`.
