# MonitorKit integration map

Date: 2026-10-22. A read-only survey for two goals:
- (a) design MonitorKit's Metal 4 encode path so it drops into the app's monitor seam with zero overhead;
- (b) let W4 replace `Packages/MonitorTools` with `Packages/MonitorKit` without regressions.

It replaces the 2026-10-21 version, which predates the app's Metal 4 rewrite (`2270aca`).

> **MonitorKit 0.1.0 (2026-10-24).** MonitorKit is now the published library
> [github.com/andrewfitz/MonitorKit](https://github.com/andrewfitz/MonitorKit), a git submodule at
> `Packages/MonitorKit`. Against this map it renames `ScopeSettings.ultracamLegacy(mode:stage:)` to
> `plainWaveform(mode:stage:)` (`ultracamLegacyImageWidth/Height` to `plainWaveformImageWidth/Height`,
> palette `.ultracamLegacy` to `.plain`; the app reads a saved "ultracamLegacy" palette as `.plain`),
> renames the six-band profile ID to `monitorkit-six-band-v1`, and removes EL Zone false colour
> (`FalseColorMode.elZone`, `ELZoneProfile`, `ELZonePublicReference`, `ELZoneReferenceStatus`). The app
> dropped EL Zone too: a saved EL Zone selection reads as off. EL Zone mentions below are history.

Related: [Monitor library plan](MONITOR_LIBRARY_PLAN.md), [GPU pipeline plan](GPU_PIPELINE_PLAN.md), [MonitorKit architecture](../Packages/MonitorKit/Docs/ARCHITECTURE.md), [MonitorKit progress](monitorkit/PROGRESS.md).

## 0. Baseline

- **Line numbers are against HEAD `dbddd91`.** `dbddd91` changed only the S-Gamut3 weights in MonitorTools (`ColorAnalysis.swift`, `MonitorTools.metal.txt`, `ELZoneProfileTests.swift`). Every app file below is as committed in `2270aca`.
  - While this map was written, another session began uncommitted edits to Program, recording and switcher files: `ProgramNormalizer.swift`, `RecordingModel.swift`, `Sources/Recording/*`, `FeedRuntime.swift`, `ProgramTimestampMapper.swift`, `SwitcherCoordinator.swift` and their tests.
  - None of those edits touch a monitor symbol. Line numbers in `FeedRuntime.swift` may drift.
- **MonitorKit** is at W1 (`e82659f`, 320 tests).
  - It encodes into **classic** `MTLCommandBuffer`s with `set*Bytes` (`MonitorPass.swift:131-222`, `MonitorFeed.swift:55-107`).
  - There is no `MTL4` symbol anywhere in the package yet.
  - `MonitorKitUI` is a 40-byte stub.
  - W2 (`wf_bf60cab5-302`) is building the HDR output, Freeze and the Metal 4 path now.
- **The app's monitor is already all GPU, all Metal 4.**
  - Every picture is a `CAMetalLayer` drawn by a `CAMetalDisplayLink`: camera tiles, Program, the workspace, detached windows and the menu bar preview. There is no `AVSampleBufferDisplayLayer` picture any more. `VideoPreview.swift` survives only as the `VideoPreviewRenderer` the `CaptureController` feeds.
  - So W4 is a renderer swap behind an existing seam (§1), not a re-architecture.

---

## 1. The monitor seam today (Packages/MonitorTools)

### 1.1 Objects and threads

| Object | File:lines | Role |
| --- | --- | --- |
| `MonitorRuntime` (`@unchecked Sendable`, one per `MonitorCoordinator`) | `MonitorToolsMetal/MonitorRuntime.swift:11-245` | Lazily built GPU context. Owns the `MonitorRenderThread`, the GPU-timing hook (→ `AppGPUActivity`, `MonitorCoordinator.swift:48-50`), `attachDrawables`/`detachDrawables`, `flushTextures(for:)`, and the test-only `renderSnapshot` (offscreen, waits) |
| `MonitorMetalContext` (internal, thread-safe) | `MonitorRuntime.swift:423-634` | Device. **One `MTL4CommandQueue`** (label "MonitorTools") for every surface. `MTL4Compiler` pipelines compiled with `mathMode = .safe` (`:461-479`): `sourceFocus`, `compose`, `scopeColumns`, `clearTarget`. One `MTLResidencySet` added to the queue (`:480-484`). A pool of `MonitorEncodeContext`s. A 1 s residency "graveyard" for retired allocations (`:525-549`). A 1 Hz maintenance timer (`:487-493`) |
| `MonitorEncodeContext` (public, pooled) | `MonitorRuntime.swift:308-372` | One reusable submission: `MTL4CommandBuffer` + `MTL4CommandAllocator` + **one `MTL4ArgumentTable` (max 4 buffers, 8 textures; `:328-331`)** + a **4 KB shared uniforms buffer (16 slots × 256 B; `:319-320`)** + a `retained` list (capacity 32) + `retiredResidents` |
| `MonitorSurfaceTextureCache` | `MonitorRuntime.swift:642-801` | IOSurface → `MTLTexture` via `device.makeTexture(descriptor:iosurface:plane:)`, keyed by IOSurface ID, plane, format and size. Textures are added to the residency set **once**, swept after 2 s idle, and flushed per target. Retains only the `IOSurfaceRef`, so capture pools still recycle |
| `MonitorRenderThread` | `MonitorRuntime.swift:805-853` | One `Thread` ("MonitorTools.render", `.userInteractive`) with a run loop. **Every display link and every encode runs here.** `perform(_:)` hops onto it |
| `MonitorToolsRenderer` (one per surface, plus one freeze copier per presenter) | `MonitorToolsMetal/MonitorToolsRenderer.swift:10-498` | Conforms to `MonitorPictureRenderer` and `MonitorScopeRenderer`. Owns the per-surface source-resolution focus mask. Caches the kernel parameters behind an `Equatable` key (`:262-287`) |
| `MonitorSurfacePresenter` (`ObservableObject`, `@unchecked Sendable`) | `MonitorToolsUI/MonitorSurfacePresenter.swift:39-770` | Latest-frame slot (`accept`, any thread, short `NSLock`). Freeze state machine (`frozen`, `lingering`, `pendingFreeze`). Clean flag. Visibility. Statistics. `@Published` status strings for SwiftUI |
| `MonitorPictureNSView` / `MonitorScopeNSView` / `MonitorSurfaceRenderLoop` | `MonitorSurfacePresenter.swift:840-1265` | The layers, and the per-surface `CAMetalDisplayLinkDelegate` on the render thread |

### 1.2 The renderer protocols (`MonitorRuntime.swift:404-420`)

```swift
public protocol MonitorPictureRenderer: AnyObject {
  func encode(frame: MonitorGPUFrame, state: MonitorRenderState, target: MTLTexture,
              viewport: MonitorViewport, into context: MonitorEncodeContext) throws
  var status: [String] { get }
  func invalidate()
}
public protocol MonitorScopeRenderer: AnyObject {
  func wantsScopes(_ state: MonitorRenderState) -> Bool
  func encodeScopes(frame: MonitorGPUFrame, state: MonitorRenderState, target: MTLTexture,
                    into context: MonitorEncodeContext) throws
}
```

`MonitorRenderState` is `{configuration: MonitorConfiguration, clean: Bool, aperture: MonitorRect?}` (`:389-399`). There is exactly one conformer, `MonitorToolsRenderer`. The seam was built so MonitorKit can slot in. It is internal to MonitorTools, though: the app never names these protocols. Only `MonitorSurfaceRenderLoop` calls them.

### 1.3 One picture frame, step by step (render thread, per surface, per vsync)

`MonitorSurfaceRenderLoop.metalDisplayLink(_:needsUpdate:)` (`MonitorSurfacePresenter.swift:1074-1137`):
1. Asks `presenter.renderWork(after: versions, force: sizeChanged)` for work.
   - It returns nil when neither the frame nor the state changed, so **an unchanged surface encodes nothing**. It still burns the vsync's drawable.
2. `runtime.beginEncoding()` pops a pooled context.
   - `allocator.reset()` then `commandBuffer.beginCommandBuffer(allocator:)` (`:340-344`).
   - The pool grows only while the GPU is behind (`acquire`, `:565-585`). The new context's uniforms are added to the residency set.
3. `runtime.gpuFrame(bundle)` maps the frame's planes through the IOSurface texture cache.
   - That cache is already resident, so there is no per-frame residency commit.
   - Formats: v210 = `rgba32Uint` at width/6. BGRA = `rgba8Uint`. 8-bit biplanar = `r8Uint`/`rg8Uint`. 10-bit biplanar = `r16Uint`/`rg16Uint`, high-aligned and shifted down by 6 in the shader (`MonitorFrame.swift:87-99`, `MonitorRuntime.swift:690-729`).
4. `applyColor(signal)` sets the layer's pixel format, colour space and EDR when the shown signal's colour changes (§2), and re-attaches the layer's drawable residency set if the layer made a new one.
5. `renderer.encode(…)` (`MonitorToolsRenderer.swift:43-100`), all on **one compute encoder**:
   - Retains the frame's textures and pixel buffers, and the target, in the context (`frame.retainResources(in:)`, `MonitorFrame.swift:164-173`).
   - If peaking is on, a *consumer* barrier comes first: `barrier(afterQueueStages: .dispatch, beforeStages: .dispatch)`, because the one mask is shared by this surface's in-flight frames. Then a `sourceFocus` dispatch at source resolution writes the r8 mask, then `barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)`.
   - Then `compose` (16×16 groups over the viewport) **writes the drawable texture directly** (`texture2d<float, access::write>`).
   - Bindings: the one argument table is rebound between the two dispatches. Textures 0-5 are picture planes 0/1, source planes 0/1, the mask and the target. Addresses 0-1 are `context.uniform(KernelParameters)`, a 160-byte struct.
   - This works because Metal 4 snapshots argument-table bindings at dispatch encode time; the app relies on that today.
6. `runtime.commit(context, drawable:, completion:, kind:)` (`MonitorRuntime.swift:589-609`):
   - `endCommandBuffer`, `queue.waitForDrawable`, then `queue.commit([cb], options:)` with a feedback handler (GPU times → `AppGPUActivity` and the presenter's statistics; the context returns to the pool).
   - Then `queue.signalDrawable`, then `drawable.present()`.
7. If scopes are wanted and a scope layer is in a window, the frame is parked as `scopePendingFrame`. The scope link draws it at the user's rate:
   - Its own `CAMetalDisplayLink` on the scope layer, with `preferredFrameRateRange` = 10/15/30 Hz.
   - Its own context and command buffer.
   - **At most 2 scope commits in flight.** Beyond that the update is skipped and counted (`scopeSkippedBusy`). This is the one "skip when busy" left. It applies to scopes only; the picture never waits.

### 1.4 Freeze (the only copy)

- `MonitorToolsRenderer.encodeFreezeCopy` (`:122-170`):
  - On the render thread, the *compute* encoder's `copy(sourceTexture:destinationTexture:)` copies the source planes, and the output planes when they are a different image, into new `.private`, `.shaderRead` textures.
  - These are made resident at once (`metal.makeResident`).
  - Then a producer barrier: `afterStages: .blit, beforeQueueStages: [.dispatch, .blit], visibilityOptions: .device`.
- The presenter swaps the held producer buffer for the owned copy as soon as the copy is committed (`makeFreezeCopy`/`adoptOwnedFreeze`, `MonitorSurfacePresenter.swift:306-352`), so **a freeze never pins a capture buffer**.
- Release: `MonitorRuntime.release(_:)` retires the copies through an empty commit; residency ends about 1 s later (the graveyard).
- The freeze state machine:
  - `requestFreezeOnNextFrame` / `cancelPendingFreeze` (cancel wins).
  - `toggleFreeze`.
  - A "lingering" hold keeps the frozen picture on screen after unfreeze until the next live frame, so there is no black flash.
  - It keeps the configuration captured at freeze time.

### 1.5 CAMetalLayer configuration

| Layer | Settings (file:lines) |
| --- | --- |
| Picture (`MonitorPictureNSView`, `MonitorSurfacePresenter.swift:840-908`) | `framebufferOnly = false` (compute writes it). `maximumDrawableCount = 3`. `isOpaque = true`. Actions disabled. `device = runtime.layerDevice`. Initial colour `MonitorPictureColor.rec709.apply`. `contentsScale` = the window's backing scale. **The layer frame is the aspect-fit rectangle** of `pictureAspectRatio` (clean aperture × PAR, `:651-667`, `:866-887`); `drawableSize` = frame × scale. The display link runs on the render thread, `preferredFrameLatency = 2`, and is paused while the view is not drawable (occluded, minimized, hidden, closing; `MonitorVisibilityNSView`, `:781-834`) |
| Scope (`MonitorScopeNSView`, `:912-960`) | `bgra8Unorm`. `colorspace = sRGB` (display graphics). `framebufferOnly = false`. 3 drawables. Fixed `drawableSize` 768×256 (`MonitorToolsRenderer.scopeWidth/Height`). `contentsGravity = .resize`. Not opaque |
| Drawable residency | `layer.residencySet` is attached to the monitor queue (`runtime.attachDrawables`; held as pending until the context exists, `MonitorRuntime.swift:161-177`). It is re-attached when a pixel-format change makes a new set (`applyColor`, `:1141-1154`) and detached on `deinit` from the render thread |

### 1.6 Where frames come from (the app's producers)

- **Camera feeds.** `CaptureController` (`Sources/App/CaptureController.swift`):
  - The capture queue validates and encodes each frame on `LUTProcessor`'s own `MTL4CommandQueue`, commits, and returns.
  - The completion goes to the delivery queue in commit order (`:1042-1046`). `deliver` (`:1086-1110`) offers the **source capture buffer**, plus the **processed output buffer** when the monitor wants it, to `MonitorCaptureSink.offer`.
  - When the monitor wants output (`needsOutput`, `MonitorCaptureSink.swift:118-127`: `pictureStage == .processedOutput`, which is the **default**, or output-stage scopes), processing is kept alive just for the monitor (`CaptureController.swift:386-388, 1001, 1008`).
  - The output offer carries a `MonitorCorrespondence` scale (`:1102-1104`), so focus and log false colour can map back to source pixels.
  - Frames that skip the GPU (no other consumer, or removed by the frame-rate gate) get a source-only offer **ordered behind the frames still on the GPU** with `LUTProcessor.afterCommittedFrames` (`CaptureController.swift:1069-1081`, `LUTProcessor.swift:726-737`).
  - `monitorProcessingRevision` is bumped on a LUT load (`:294`), on reconfigure (`:532`), on a format change (`:970`) and on a pipeline change (`:989-991`). It goes into every stamp, so the presenter rejects frames from an older processing state.
  - `setMonitorSink` (`:558-561`). Stop invalidates the sink and rejects that capture generation (`:563-590`).
- **The sink.** `MonitorCaptureSink` (`Sources/App/MonitorCaptureSink.swift`, 353 lines, `@unchecked Sendable`) runs on the delivery queue:
  - Stamps each frame with `MonitorFrameStamp` (target, generation, sequence, PTS, host time, configuration revision, processing revision).
  - Interprets the signal: the YCbCr matrix, transfer and primaries tags, the range from the pixel format or a user override, and the declared log profile. The `Interpretation` cache keeps the steady state allocation-free (`:205-257`, `:319-352`).
  - Reads the geometry: clean aperture and pixel aspect, cached per IOSurface (`:260-300`).
  - Then, **under the sink lock**, calls `presenter.accept(bundle, configuration:)` for every live consumer (`:192`).
  - `MonitorCoordinatorChecks.testSteadyOffersReadColorimetryWithoutAllocating` guards the allocation-free path.
- **Program.** `ProgramMonitorTap` (`ProgramOutputBridge.swift:423-451`):
  - Offers the processed Program frame as both source and output, with `correspondence: nil`.
  - That disables focus and log false colour (`MonitorToolsRenderer.swift:370-384`). The sink also forces Program's stages to `.processedOutput` (`MonitorCaptureSink.swift:91-94`).
  - The generation is bumped on every cut, so a cut never shows a frame from the previous source.
- **The menu bar preview** is a compact monitor surface: no scopes and no chrome (`UIAppProviders.swift:9-18`).

---

## 2. The colour model today (`MonitorToolsUI/MonitorPictureColor.swift`)

The picture pass writes **signal-native non-linear R′G′B′**: the YCbCr matrix undone, no transfer applied, clamped to [0,1] (`MonitorTools.metal.txt:199`). The layer is then *tagged* with the signal's colour space, and Core Animation colour-matches and tone-maps, as `AVSampleBufferDisplayLayer` did.

| Shown signal (`MonitorPictureColor.init(signal:)`, `:26-42`) | Space | Layer pixel format | `colorspace` | `wantsExtendedDynamicRangeContent` | `edrMetadata` |
| --- | --- | --- | --- | --- | --- |
| A declared camera log profile (`profileID != nil`), or no signal | rec709 | `bgr10a2Unorm` | `CGColorSpace.itur_709` | false | nil |
| Transfer tag `ITU_R_2100_HLG` | hlg | `rgba16Float` | `itur_2100_HLG` | true | `CAEDRMetadata.hlg` |
| Transfer tag `SMPTE_ST_2084_PQ` | pq | `rgba16Float` | `itur_2100_PQ` | true | `CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 100)` |
| Primaries tag `ITU_R_2020`, SDR transfer | rec2020 | `bgr10a2Unorm` | `itur_2020` | false | nil |
| Anything else (709, sRGB, linear, unknown) | rec709 | `bgr10a2Unorm` | `itur_709` | false | nil |

How it is applied:
- In its own `CATransaction` with actions disabled, from the render thread, and only when the space changes (`apply(to:)`, `:64-84`).
- The signal is taken from the **picture stage**.
- After a burned-in LUT, `LUTProcessor.stampAttachments` tags the output Rec.709 matrix, primaries and transfer (`LUTProcessor.swift:911-924`). So an Output picture of a LUT'd camera is a Rec.709 layer, and a Source picture of an HLG camera is an EDR HLG layer.

Overlay colours:
- They are mixed **in the signal's code space**. A zebra stripe mixes toward 1.0, and false-colour and peaking colours are code values.
- So on a PQ layer a zebra stripe is 10,000-nit code white, and on HLG it is peak. This is today's behaviour.

Tests that pin this model:
- `MonitorToolsUITests.testPictureLayerPresentationFollowsSignalColorimetry` (`:614`)
- `testDrawnHLGFrameSwitchesThePictureLayerToEDR` (`:662`)
- `MonitorMetalTests.testUnknownOrHDRTransferDoesNotGetRetaggedAsSDR` (`:223`)

**What MonitorKit's output colour must match for W4:**
1. The same five-way decision, from the *stage* signal:
   - The stage signal is the source when no LUT touched it.
   - After a LUT it is the LUT's output encoding, Rec.709 by default, which matches `stampAttachments`.
2. A **signal-native write mode**: no transfer conversion, so a PQ code goes out as the same PQ code into an `itur_2100_PQ` `rgba16Float` layer.
   - Converting to extended-linear sRGB would change the look relative to today and add ALU.
3. The same `CAEDRMetadata`.
4. **`SignalDescription` must carry primaries.** Today it has range, matrix, siting and encoding only (`MonitorKitCore/Signal.swift:218-250`), and `MonitorFrame.signal(of:range:)` ignores `kCVImageBufferColorPrimariesKey` (`MonitorFrame.swift:214-246`). Without primaries the rec2020 row cannot be derived.
5. Log sources stay a code-value view by default. The planned analytic S-Log3→709 transform must be opt-in, or the default picture changes.
6. Recommended (a deliberate change): draw overlay whites at BT.2408 graphics white in HDR modes, which is 203 cd/m², about 0.58 PQ or 0.75 HLG ([ITU-R BT.2408](https://www.itu.int/rec/R-REC-BT.2408)). The alternative is to keep today's code-1.0 overlays for parity.

The current MonitorKit pass writes "display-encoded SDR" and, for `*_srgb` targets, linearizes (`ARCHITECTURE.md`, Target encoding). For a 709 source that is the same R′G′B′ the app writes today. HDR is W2.

---

## 3. App files that consume MonitorTools

`rg -n "import MonitorTools" Sources Tests Tools`: 14 sources, 3 tests and 7 tools.

| File | MonitorTools symbols (lines) | Role today | W4 action |
| --- | --- | --- | --- |
| `Sources/App/MonitorCaptureSink.swift` (all) | `MonitorRuntime`, `MonitorSurfacePresenter`, `MonitorConfiguration`, `MonitorFrameStamp`, `MonitorFrameBundle`, `MonitorFrameSignal`, `MonitorGeometry`, `MonitorRect`, `MonitorCodeRange`, `MonitorYCbCrMatrix`, `MonitorCorrespondence` | Delivery-queue endpoint (§1.6) | **Rewrite as `MonitorFeedHost`** (§6.2). Keep the stamp, out-of-order, generation and allocation-free colorimetry logic. Signal → `SignalDescription`. Delete `needsOutput`, the output buffer and the correspondence |
| `Sources/App/MonitorCoordinator.swift` (286) | `MonitorRuntime` (26, 48-56), `MonitorSurfacePresenter` (31, 205-215), `MonitorTargetOption` (17, 150-157), `MonitorDiagnostics` (24, 59-103), `MonitorWorkspaceState` (9-16), `MonitorConfiguration` (18, 105-132) | Main-actor control: configurations per target, `copySettings` (117-132, which keeps the destination's calibration), preview enable, `updateTargets`, `captureSink`, surface registry, `refreshSink` (242-253), demand (255-265), `sourceStateChanged` | **Retype in place.** Same public surface: `state(for:)` replaces `configuration(for:)`, and `targets`, `workspace`, demand and preview enable stay. Owns the GPU context, the `MonitorEngine` and the feed hosts |
| `Sources/App/MonitorWorkspaceView.swift` (285) | `MonitorTileChrome` (29, 251), `MonitorSurfaceVisibility` (39), `MonitorNativePicture` (44), `MonitorGuideOverlay` (52), `MonitorPictureZoom` (58), `MonitorDiagnosticsView` (132), `MonitorNativeScope` (144), `MonitorScopeGraticule` (145) | Workspace tiles and detached monitor windows (`MonitorDetachedWindows` 192, `MonitorWindowOwner` 217) | Swap to the app-owned picture and scope views. Delete the guide overlay (MonitorKit draws guides in-shader). Zoom → `geometry.magnification`. The chrome, legend and toolbar come from MonitorKitUI or app ports |
| `Sources/App/UIAppProviders.swift` (150) | `MonitorConfiguration` (34-39, 69-77), `MonitorTargetID`, `MonitorSurfacePresenter` (62), `MonitorSurfaceVisibility` (83), `MonitorNativePicture` (86), `MonitorGuideOverlay` (88), `MonitorNativeScope` (97), `MonitorScopeGraticule` (98) | Every in-window picture, Program's toolbar, registration (142-149) | Same structure on the new views. Remove the `MonitorGuideOverlay` and `MonitorScopeGraticule` overlays. Registration semantics are unchanged |
| `Sources/App/UISupport.swift` (86-208) | `MonitorSurfacePresenter`, `MonitorConfiguration`, `SonySLog3FalseColor`, `ELZoneProfile`, `MonitorTargetID` | `UIMonitorBridge`: the presenter registry, `activeTools` (102-111), master-switch emulation in `toggled` (122-157), freeze, clean and detach (165-181) | Retarget to `MonitorState` plus app-side scope prefs (§5). The master switch (`toolsEnabled`) no longer exists, so `toggled` loses the master logic |
| `Sources/App/UIMonitorTools.swift` (349) | `MonitorConfiguration`, `MonitorZebraMode`, `MonitorPeakingColor`, `MonitorScopeMode`, `MonitorStage`, `MonitorFalseColorMode`, `MonitorCodeRange`, `MonitorSourceLogMapping`, `SonySLog3FalseColor`, `ELZoneProfile` | Tool buttons (6-87); the settings popover binds every field (178-266) | Bind to `MonitorState`, the per-feed signal declaration and the scope prefs. Zebra width becomes a half-width. Offset stepper range is −6…6 |
| `Sources/App/UICameraColumn.swift` | `MonitorPictureZoom` (64; zoom `@State` 45, picker 300-308), `MonitorStage` (262-285, the "Output (as published) / Source (camera signal)" menu) | Picture zoom and picture stage | Zoom → ephemeral `geometry.magnification`. **The picture stage has no MonitorKit field** (§7, item 1) |
| `Sources/App/UIContext.swift` (19-21, 89-101) | `MonitorConfiguration` | `UIMonitorSettingsProviding`; fixtures | Retype |
| `Sources/App/UISessionBridge.swift` (142-144, 371-382) | `MonitorTargetID`, `MonitorConfiguration` | `activeTools` in the snapshot; reset and copy actions | Retype |
| `Sources/App/UIDiagnostics.swift` (101, 174, 223-260) | `MonitorDiagnostics`, `MonitorAvailability` | "Monitoring" section: source rate, presented fps, scope fps, offered/presented, superseded, scope skips, GPU ms, failures | Keep the rows. `MonitorDiagnostics` becomes app-owned. Optionally add `MonitorStatus` reasons |
| `Sources/App/AppModel.swift` (2, 188-189, 231, 259-263, 291-328, 615, 637, 773, 1035, 1042, 1194, 1213, 1245, 1387, 1447) | `MonitorTargetID`, `MonitorConfiguration` (through the coordinator) | Builds the coordinator from the snapshot; callbacks write back into the descriptors; `setMonitorSink`; demand into `reconcileAutomaticFeed`; Program tap | Retype. The `setMonitorSink` call (1035) takes the feed host. The LUT load path also hands the `MonitorLUT` to the feed (§4.4) |
| `Sources/App/AppSettingsStore.swift` (2, 235, 242, 256, 291-315, 327-328, 334-342, 366-379) | `MonitorConfiguration`, `MonitorWorkspaceState` | Persistence (§5) | New keys plus a legacy decoder (§5.3) |
| `Sources/Shared/FeedRuntime.swift` (4, 207, 744-763, 1233) | `MonitorConfiguration`, `MonitorWorkspaceState` | `FeedCoordinator.programMonitorConfiguration` and `monitorWorkspace`; `onMonitorFrame` for Program | Retype to the app-owned types in `Sources/Shared/MonitorWorkspace.swift` (Shared, because `FeedRuntime` is in Shared; the camera extension does not compile `FeedRuntime`) |
| `Sources/App/CaptureController.swift` (5, 145-149, 294, 386-388, 532, 558-590, 970, 989-1041, 1069-1110, 1323-1326) | `MonitorCaptureSink`, `MonitorCorrespondence` | §1.6 | §6.2 step 6 |
| `Sources/App/ProgramOutputBridge.swift` (423-451) | `MonitorCaptureSink` (app type) | `ProgramMonitorTap` | Offer the source only (no output twin) |
| `Sources/App/UISettings.swift` (635-656) | — | Monitor pane text. Line 648: "Under heavy load, new monitor analysis pauses…" | Rewrite: only the scope skip-when-busy remains, and MonitorKit's scopes run at the host rate |
| `Tests/MonitorCoordinatorChecks.swift` (14 tests), `Tests/MonitorLifecycleChecks.swift` (2 monitor tests), `Tests/CaptureRecordingIsolationChecks.swift` (121, 285, 362, 720) | sink, presenter, runtime, configuration | §8 | Retarget or delete (§8.1) |
| `Tools/MonitorAppIntegration/main.swift`, `Tools/UIVerify/main.swift` | `MonitorTargetID`, `MonitorWorkspaceState`, `MonitorConfiguration` | Real `AppModel` with `hardware: .offline` (`MonitorAppIntegration/main.swift:40-42`, `UIVerify/main.swift:394-396`) | Retype; keep `.offline` |
| `Tools/CameraSmoke/main.swift:380-460` (`MonitorComparison`), `Tools/MonitorToolsSmoke`, `Tools/MonitorToolsRecording` (+`MonitorGPUWorkload.swift`), `Tools/MonitorToolsRecordingTests`, `Tools/MonitorToolsBenchmark` | `MonitorRuntime`, `MonitorToolsRenderer`, `renderSnapshot` | Qualification harnesses | Rewrite `--monitor` over MonitorKit or drop it. Retire the `MonitorTools*` tools; MonitorKit's own benchmarks replace them |

---

## 4. The LUT path

### 4.1 The parser (`Sources/Shared/CubeLUT.swift`, 138 lines)

- An internal `struct CubeLUT: Sendable`:
  - `title`, `dimension` (2…65), `domainMin`/`domainMax`, `rgba` (red fastest, alpha 1), `data`.
  - **3D only:** a 1D or shaper table throws "1D/shaper LUTs are unsupported" (`:110`). `Tests/main.swift:66` asserts that `LUT_1D_SIZE` throws.
- `MonitorKitCore.CubeLUT` (`Packages/MonitorKit/Sources/MonitorKitCore/CubeLUT.swift`) is the same parser, made public and `Equatable`, plus:
  - 1D and shaper + 3D tables (`shaper`, `shaperDomainMin/Max`, `shaperSize`)
  - `hasCube`, where `dimension == 0` for a 1D-only table
  - `LUT_3D_INPUT_RANGE`
- **Name collision.** The app's module-internal `CubeLUT` shadows the imported one. Delete the app file in the same change that adds the import; never keep both.
- File access: `LoadedLUT` and `actor LUTFileLoader` (`AppSettingsStore.swift:458-520`), with security-scoped bookmarks, a 32 MB bound and UTF-8 only. Unchanged by W4.

### 4.2 `LUTProcessor.swift` and `LUTShaders.metal` now

- **Is `LUTShaders.metal` a verbatim copy of `MKLUT.msl`?** It is a verbatim copy of an **older** `MKLUT.msl` (lines 11-63, under the same `MK_LUT_MSL` guard). It differs from the current file (`diff`, comments ignored):

| | App copy (`LUTShaders.metal:11-63`) | Current `MKLUT.msl` |
| --- | --- | --- |
| `mk_LUTParams` | **3 rows, 48 B**: `domainLow`, `domainScale`, `shape` | **5 rows, 80 B**: adds `shaperLow` (w = 1 when 1D-only) and `shaperScale`; `shape.w` = shaper entries |
| 1D shaper | none | `mk_shaper`, with the entries in extra texture slices after the lattice |
| Trilinear (`shape.y == 1`) | 8 reads, mix x, then y, then z | **identical** |
| Tetrahedral (`shape.y == 0`) | branchy six-case | branch-free; same weights and summation order |
| Hardware (`shape.y == 2`) | normalized by `n` | normalized per axis by `(n, n, depth)` |
| Include | none (`metal_stdlib` at the top of the app file) | `#include <metal_stdlib>` inside the file |

- **Interpolation in use: trilinear, hard-coded.** `lutShape = SIMD4(dimension, 1, applyLUT ? 1 : 0, 0)` (`LUTProcessor.swift:518`).
- **Struct layout.** Swift `Parameters` (`LUTProcessor.swift:167-176`) has 8 rows (128 B): `geometry`, `decodeRange`, `decodeMatrix`, `encodeMatrix`, `chroma`, `lutDomainLow`, `lutDomainScale`, `lutShape`. It is mirrored by MSL `Parameters` (`LUTShaders.metal:67-74`), which **embeds `mk_LUTParams lut` last**. Each frame writes it into a 256 B slot of `parameterBuffer` (`parameterStride = 256`, `:89`), bound through the argument table address 0.
- **The LUT texture.** `makeLUTTexture` (`:288-306`) builds a `type3D rgba32Float`, `.shared`, `.shaderRead` texture of n³, `replace`d with `bytesPerRow n*16` and `bytesPerImage n*n*16`. For a 3D-only cube that is byte-for-byte what `MonitorLUT` builds. A 2³ identity placeholder is bound when no LUT is loaded (`:273-277`).
  - It is bound at `texture(2)` of the first table (`:571`) and is in `persistentResidency`.
  - `load(_ cube:)` (`:308-317`) **blocks the capture queue for up to 2 s** (`waitUntilIdle`) before swapping, because in-flight frames reference the old texture.
- **Compile options.**
  - `MTL4LibraryDescriptor` with **no `options`** (`:228-233`), so the defaults apply, i.e. fast math.
  - MonitorKit compiles with `mathMode = .safe` and MSL 4.0, or 4.1 on macOS 27 (`MonitorShaders.swift:30-42`). So burn-in and monitor `mk_applyLUT` can differ by a few ULPs.
  - `ULTRACAM_METALLIB` (`:222-223`) loads a prebuilt metallib instead. That path would need the same concatenation.
- **The device.** Each `LUTProcessor` calls `MTLCreateSystemDefaultDevice()` (`:205`); so does `MonitorRuntime` (`:36`). On this single-GPU Mac they return the same device. A `MonitorLUT` can be shared only within one device. Assert `===` in W4, or inject the device.
- `CubeLUT` call sites:
  - `AppSettingsStore` (`LoadedLUT`, `LUTFileLoader.read`)
  - `CaptureController.load(_:expectedGeneration:completion:)` (`:286-298`)
  - `LUTProcessor.load`
  - `Tests/main.swift` (`CubeTests`, `testTenBitPrecision`, …), `EndToEndChecks`, `GPUExtendedChecks`, `CaptureRecordingIsolationChecks`
  - by path in `scripts/camera-smoke.sh:36` and `scripts/monitor-tools-recording.sh:24`

### 4.3 The include-guard trap

Prepending `MonitorShaders.source([.lut])` to `LUTShaders.metal`, the "one-line change" its comment promises, silently skips the app's guarded copy. MSL `Parameters.lut` becomes 80 B while Swift still writes 48 B.

- **Today this is safe only by accident.** `shape.w` sits in the same row in both layouts, and Swift writes it as 0, so `mk_shaper` and `shaperLow.w` are never read. The bytes past Swift's 128 are whatever the 256 B slot holds.
- **It breaks the moment the parser is swapped**:
  - A shaper LUT parses with `shaperSize > 0`.
  - `makeLUTTexture` uploads only n³, with no shaper slices.
  - Swift never sets `shape.w`, so the shaper is ignored.
  - The burned-in output is then wrong, with no error.
- The parser swap, the `MonitorLUT` texture, `MKLUT.msl` and the Swift struct must land in **one change**. Until then, guard in the app: reject `!cube.hasCube || cube.shaperSize > 0` in `LUTFileLoader` or `CaptureController.load`.

### 4.4 W4 LUT target (fused tier)

- `LUTShaders.metal`: delete lines 4-63 and build the library from `MonitorShaders.source([.lut]) + LUTShaders.metal`.
- Swift `Parameters`: replace `lutDomainLow`/`lutDomainScale`/`lutShape` with `lut: LUTParameters`, which has the same 5-row layout as `mk_LUTParams`. That makes 10 rows, 160 B, which fits the 256 B stride.
- `cube`/`lutTexture`/`makeLUTTexture` → `lut: MonitorLUT?`, plus a placeholder `MonitorLUT` (identity 2³) or `LUTParameters.disabled`.
  - Parameters: `lut.parameters`, with `shape.z = 0` when `applyLUT` is off.
  - Interpolation: `MonitorLUT.interpolation` (default `.trilinear` in the app for bit-compatibility; tetrahedral is a product decision).
- Compile with MonitorKit's options (library requirement R6) so burn-in and preview are the same code under the same math mode.
- `load(_ lut: MonitorLUT)` needs no `waitUntilIdle`: `MonitorLUT` is immutable, so retain the old one in the in-flight frame records and swap at once. Keep a `load(_ cube: CubeLUT)` convenience for the tests.
- **One `MonitorLUT` per file load**, built on the main actor from the `LoadedLUT` with the shared device, and given to both `CaptureController.load` (burn-in) and the feed host (`MonitorFeed.burnInLUT`). Its texture must be in **both** residency sets: `LUTProcessor.persistentResidency` and the monitor's.
- Golden check: trilinear output must equal the pre-change kernel, either exactly (same options) or within the existing tolerances (`Tests/main.swift:89-192`, `EndToEndChecks.swift:50-150`, `GPUExtendedChecks.swift:128-371`, `CaptureRecordingIsolationChecks.swift` LUT cases). Also against `CubeLUT.apply` ≤ 1e-4.

---

## 5. Settings model and persistence

### 5.1 Where monitor and LUT settings live

- Defaults key `ultracam.settings.v2` holds the JSON `AppSettingsSnapshot` (`currentVersion = 2`, `AppSettingsStore.swift:320-381`, store `:386-457`).
  - `feeds: [FeedDescriptor]`. Each has `version = 1`, enforced by `validated()` (`:353-357`). Fields include `applyLUT`, `lutBookmark: Data?`, `gamut` (default `"S-Gamut3.Cine / S-Log3"`, used to default the source profile, `UISupport.swift:116-120`), `previewEnabled` and **`monitorConfiguration: MonitorConfiguration`** (`decodeIfPresent`, `:315`).
  - `programMonitorConfiguration: MonitorConfiguration` (`:378`).
  - `monitorWorkspace: MonitorWorkspaceState`: `schemaVersion 1`, `isConfigured`, `layout` (`single`/`sideBySide`/`fourUp`), `tileBindings: [MonitorTargetID?]` (padded to 4), `splitRatio` (0.2…0.8).
- The legacy `ultracam.settings.v1` (`AppSettings`) has no monitor fields. It is migrated once.
- LUT *contents* are never persisted; only bookmarks are. `resetAll` (`:395-404`) removes `ultracam.settings.*`, `ui.*` and the recording bookmarks.
- The installed app's settings live in its sandbox container. The Debug build uses `~/Library/Preferences/org.ultracam.app.plist`. **Never run `defaults` against `org.ultracam.app`**: it resolves to the installed app's container. Back up the Debug plist by explicit path.

### 5.2 The migration trap (verified)

- Both schemas say `schemaVersion: 1`.
- `MonitorState.init(from:)` is lenient and never throws (`MonitorState.swift:395-409`).
- **Decoding an old `MonitorConfiguration` blob as `MonitorState` does not yield defaults. It yields a partial, wrong state.** Verified by compiling MonitorKitCore with a probe, decoding a saved configuration that has `toolsEnabled: false`:
  - `guides` decodes `enabled`, `thirds`, `centerCross`, `opacity` and `contrast`; `safeArea` is dropped.
  - `focus` decodes `enabled`, `color`, `sensitivity`, `noiseRejection` and `opacity`.
  - `falseColor.mode` decodes `off`/`sonySLog3`/`elZone`, while `"arri"` becomes `.off`. `referenceOffsetStops` decodes, then clamps to ±6.
  - `zebra` (singular) is ignored, so the zebras stay off.
  - **`toolsEnabled` is ignored.** Guides, peaking and false colour that the user had switched off with the master switch **come back on**.
- **Rules:**
  1. Never decode the old key as `MonitorState`.
  2. Decode the old key with an app-private `LegacyMonitorConfiguration`, a verbatim copy of `MonitorConfiguration.swift:1-247` including `normalized()` and the nested settings types. It needs the profile IDs from `MonitorKitCore.Reference` (`SonySLog3FalseColor`, `ELZoneProfile`, `ARRIFalseColorProfile`, `SonyARRIStyleFalseColor`).
  3. Write `MonitorState` under **new keys**, and prefer them when present.
  4. **Do not bump `FeedDescriptor.version`.** `validated()` rejects `version != 1`, and a rejected snapshot falls back to the v1 path, losing all feeds.
  5. Keep round-tripping the old `monitorConfiguration` blob unchanged as opaque data, so a downgrade still finds its tools. It is cheap and avoids a one-way migration.
- Optional MonitorKit hardening (R13): a type discriminator or `schemaVersion` 2 before any host persists `MonitorState`, so a foreign v1 blob fails closed to defaults.

### 5.3 Field-by-field: `MonitorConfiguration` → MonitorKit

New per-feed keys, all `decodeIfPresent`:
- `FeedDescriptor.monitor` holds `MonitorFeedPreferences` with:
  - `state: MonitorState`
  - `signal: MonitorSignalDeclaration?`
  - `scopes: MonitorScopePreferences`
  - `pictureStage`, until MonitorKit has it (R9)
- `AppSettingsSnapshot.programMonitor`, the same type.
- These types are app-owned, in `Sources/Shared/MonitorWorkspace.swift`.

| Old field (default) | New home | Conversion / note |
| --- | --- | --- |
| `schemaVersion` (1) | `MonitorState.schemaVersion` (1) | The trap above |
| `toolsEnabled` (false) | none (no master switch) | When false: `zebras[*].enabled = false`, `guides.enabled = false`, `focus.enabled = false`, `falseColor.mode = .off`, `scopes.enabled = false`; sub-values kept. **Not** `MonitorState.clean`: Clean View is ephemeral |
| `guides.enabled` (false), `.thirds` (true), `.centerCross` (false), `.opacity` (0.65), `.contrast` (1) | `guides.` same names | Same ranges (0…1) |
| `guides.safeArea` (false) | `guides.safeAreas` | `true` → `[90]`: the old overlay insets 5% per side (`MonitorToolsToolbar.swift:266-267`) |
| — | `guides.frameGuides`, `squareGrid`, `diagonals`, `centerDot`, `color`, `lineWidth`, `followsFrameGuide` | MonitorKit defaults |
| `zebra.enabled` (false) | `zebras[0].enabled` | `zebras[1]` stays off |
| `zebra.thresholdIRE` (95; −20…120) | `zebras[0].level` | Same clamp. The UI slider is 0…109 |
| `zebra.widthIRE` (5; 0…30, **full** width) | `zebras[0].range` (**half** width) | `range = widthIRE / 2`. Old band `[t−w/2, t+w/2)` (`MonitorTools.metal.txt:196`) equals new `[level−range, level+range)` |
| `zebra.mode` `.aboveThreshold` / `.band` | `zebras[0].mode` `.lowerLimit` / `.band` | |
| `zebra.opacity` (0.65) | `zebras[0].opacity` | |
| (implicit) zebra measured the *picture* stage | `zebras[0].stage` | `pictureStage == .source ? .source : .output` |
| `effectiveZebraEnabled`: false colour suppresses zebra | none | MonitorKit draws both. Keep the suppression in the app glue (`state` derived at encode), or accept the change |
| `falseColor.mode` `.off` / `.sonySLog3` / `.elZone` | `falseColor.mode` same | |
| `.arri` + `SonyARRIStyleFalseColor.profileID` | `.sonySLog3` | The old `normalized()` already rewrote these (`MonitorConfiguration.swift:203-209`), so saved data is already Sony. `.arriStyleSLog3` exists if wanted |
| `.arri` + `logC3EI800`/`alexa35LogC4EI800`, EI 800, `sourceProfileID == profile` | `.arriLogC` + signal `.log(LogEncoding(profileID:))` | Otherwise `.off`, as old `normalized()` did |
| `falseColor.profileID`, `.specificationVersion` | dropped | Derived from mode + signal |
| `falseColor.exposureIndex` (800) | dropped | Only 800 was ever valid |
| `falseColor.referenceOffsetStops` (0; −10…10) | `falseColor.referenceOffsetStops` (−6…6) | Values clamp. Change the UI stepper (`UIMonitorTools.swift:260`) |
| — | `falseColor.stage` (.output), `customUnit`, `customBands` | Log modes always classify the source |
| `focus.enabled`, `.color`, `.sensitivity` (0.5), `.noiseRejection` (0.02), `.opacity` (0.85) | `focus.` same | Same raw colour values. Same `edgeThreshold = 0.02 + (1−s)·0.3` (`MonitorState.swift:212` = `MonitorToolsRenderer.swift:478`) |
| — | `focus.style` (.coloredEdges), `focus.stage` (.source) | Old peaking was always source luma |
| `scopes.enabled` (false) | `MonitorScopePreferences.enabled` (app) | MonitorKit leaves scope scheduling to the host |
| `scopes.refreshHz` (15; 10/15/30) | `MonitorScopePreferences.refreshHz` (app) | |
| `scopes.mode` `.rgbParade` / `.lumaWaveform` | `ScopeSettings(kind: .waveform)` with `waveformMode = .rgbParade` / `.luma` | |
| `scopes.gain` (1; 0.25…4) | `ScopeSettings.display.gain` (0.05…20) | Same number. The trace curve differs (old: `1−exp(−n·gain·30.72/population)`) |
| `scopes.graticule` (true) | `ScopeSettings.display.showsGraticule` | The old IRE labels are SwiftUI (`MonitorScopeGraticule`) |
| `scopeStage` (.processedOutput) | `ScopeSettings.stage` | `.processedOutput` → `.output` |
| `pictureStage` (.processedOutput) | **no MonitorKit field** | App-side until R9. `.source` = "show without burn-in"; `.processedOutput` = output stage |
| `sourceProfileID` (nil) | per-feed `MonitorSignalDeclaration.encoding` → `SignalDescription.encoding = .log(LogEncoding(profileID:transport:))` (`Signal.swift:168-178`) | nil → display transfer from tags. **Per feed, not per surface** |
| `sourceCodeRange` (nil) | `MonitorSignalDeclaration.range` → `SignalDescription.range` | nil → from the pixel format (`MonitorFrame.layout(for:)`) |
| `sourceLogMapping` `.native10Bit` / `.fullRescaledToLegal10Bit` | `LogEncoding.transport` `.native` / `.fullRescaledToLegal` | |
| — | `clean` | **Ephemeral**: Clean View is per presenter today. Set at encode; strip before persisting |
| — | `geometry.magnification` | **Ephemeral**: zoom is `@State` today. Strip before persisting |
| — | `geometry.desqueeze`, `.flip`, `display.*`, `monitorLUT` (true) | MonitorKit defaults (new features) |
| Program's `programMonitorConfiguration` | `programMonitor.state` | Old stages were forced to output. Program has no burn-in, so `.source == .output` |
| `monitorWorkspace` | unchanged, app-owned type with the same Codable keys | `MonitorTargetID` stays a single-value `RawRepresentable` String, so the JSON is unchanged |

`copySettings` (`MonitorCoordinator.swift:117-132`): the source's tools are copied and the destination's calibration is kept. With signal declarations per feed, calibration is simply not part of `MonitorState`. Copy `state` and `scopes` only, and keep the destination's `signal`. `referenceOffsetStops` stays per destination, as today.

---

## 6. The Metal 4 seam MonitorKit must fit

### 6.1 What "zero overhead" means here

Per surface per vsync the app spends:
- one pooled `MTL4CommandBuffer`, `allocator.reset`
- **no** per-frame residency commits (the frames come from the resident IOSurface cache)
- one compute encoder, a few hundred bytes of uniforms, one commit with a drawable

MonitorKit's Metal 4 path must add **nothing** to that:
- no command buffer, queue, allocator, residency set or argument table created per frame
- no residency commit per frame
- no `waitUntil*`, no commit, no feedback handler
- no heap allocation on the encode path (the existing contract tests)

### 6.2 The exact shape MonitorKit should expose (library requirements R1-R8)

```swift
/// One host submission. The app's MonitorEncodeContext conforms.
public protocol MonitorMetal4Encoding: AnyObject {
  var commandBuffer: MTL4CommandBuffer { get }
  /// Transient constant memory, valid until this submission completes. 256-byte aligned.
  func allocateUniforms(length: Int) -> (contents: UnsafeMutableRawPointer, address: MTLGPUAddress)
  /// Keeps `object` alive until this submission completes (resource replacement only, never per frame).
  func retainUntilCompleted(_ object: AnyObject)
  /// Ends `allocation`'s residency once this submission (and earlier work on the queue) completes.
  func retireAfterCompletion(_ allocation: MTLAllocation)
}
/// Device-wide residency the host owns. Thread-safe. The app's MonitorMetalContext conforms.
public protocol MonitorResidencyHost: AnyObject, Sendable {
  func makeResident(_ allocation: MTLAllocation)      // add + commit; called only on allocation
}
```

Calls:
- `MonitorEngine(device:, residency: MonitorResidencyHost)`. Placeholders, focus masks, scope bins, stats and trace textures, LUT textures and freeze copies are added through it once, when they are created.
- `feed.analyze(frame, focus:, into: some MonitorMetal4Encoding)`
- `pass.encode(frame:feed:state:target:viewport:clear:into:)`
- `scopeGroup.accumulate(frame, feed:, into:)` and `scopeRenderer.render(…, into:)`
- `freeze(frame, into:) -> MonitorFrame`

Details:
1. **Command buffers (R1).** Only the host's `MTL4CommandBuffer`. Encoders are created inside it, and only for the library's own passes:
   - a compute encoder for focus, scopes and freeze
   - an `MTL4RenderCommandEncoder` from an `MTL4RenderPassDescriptor` on `target` for the picture and the scope image
   - optionally `prepare` + `draw(with: MTL4RenderCommandEncoder)` inside a host pass
2. **Argument tables (R3).** MonitorKit owns them: one per `MonitorPass`, `MonitorFeed`, `ScopeAccumulator`/`ScopeGroup` and `ScopeRenderer`, created at init and sized to its shaders. The app's table (4 buffers, 8 textures) is too small:
   - the pass binds 6 textures and 5 buffers (`MonitorPass.swift:208-221`)
   - focus binds 6 and 4 (`MonitorFeed.swift:86-98`)
   - `ScopeGroup` binds up to buffer 10 and `ScopeAccumulator` up to index 11 (`ScopeGroup.swift:234-248`, `ScopeAccumulator.swift:238-270`)

   Reusing a table across frames and command buffers is safe, because Metal 4 captures the bindings at draw/dispatch encode time. `MonitorToolsRenderer.swift:68-98` already depends on that.
3. **Uniforms (R2).** No `set*Bytes` in Metal 4: everything goes through `setAddress`. Size a host allocator from the shipped `uniformLength` constants (each block at a 256-byte offset), never from hand-computed struct sizes, which change:
   - `MonitorPass.uniformLength` **5120 B** per picture encode (the frame block, which holds the 160 B `mk_PassFrames`: the source and the output reading's `FrameParameters`; two LUT blocks; then `PassParameters`, 1520 B, at offset 768 and `GuideParameters` at 2304).
   - `MonitorFeed.uniformLength` **1024 B** per focus analysis.
   - `ScopeAccumulator.uniformLength` **1280 B** per accumulation; `ScopeGroup.uniformLength` **2048 B** per fused pass (each unfused member asks its own 1280).
   - `ScopeRenderer.uniformLength` **768 B** per `prepare`, plus `ScopeRenderer.graticuleUniformLength` **2304 B** only when the graticule changes.

   **The app's `MonitorEncodeContext.uniform` cannot hold these.** Its stride is 256 B, a precondition (`MonitorRuntime.swift:347-358`), and its capacity is 4 KB. W4 changes it to a variable-size bump allocator: about 32 KB per context, 256-B aligned, reset in `begin()`, resident as today. That is still zero allocation per frame. 32 KB holds a picture and its analysis (6144 B) five times over, and a scope tick of three scopes in one group with every graticule rebuilt (2048 + 3 × 768 + 3 × 2304 = 11,264 B). Without a host allocator (`MonitorSubmission.uniforms` nil) each object uses its own ring of `framesInFlight` slots instead.
4. **Residency (R4).**
   - The library's persistent allocations go into the host's set once (`MonitorResidencyHost.makeResident`). Retirement, on a size change or a freeze release, goes through `retireAfterCompletion`. The app maps that onto its existing graveyard (`MonitorRuntime.swift:525-549`).
   - A `MonitorLUT` texture must be addable to several sets (the processor's and the monitor's). It already exposes `texture`.
   - The host keeps the drawable residency: `layer.residencySet` on the queue (§1.5). MonitorKit is not involved.
5. **Barriers (R5).** Metal 4 tracks no hazards, so the library encodes its own:
   - **Focus mask, write after read** across frames and surfaces: at the start of `analyze`, `barrier(afterQueueStages: [.fragment, .dispatch], beforeStages: .dispatch)`.
   - **Mask read after write**: in the picture's render encoder, `barrier(afterQueueStages: .dispatch, beforeStages: .fragment, visibilityOptions: .device)` before the draw. It is a *queue* barrier because `analyze` may sit in another surface's command buffer on the same queue.
   - **Scope bins**: the same around clear → accumulate → resolve or render.
   - **Freeze copy**: `afterStages: .blit, beforeQueueStages: [.dispatch, .fragment, .blit]`.
   - These are only correct because **all monitor work shares one `MTL4CommandQueue`** (the app's design). Document that in the contract. The capture frames are written by `LUTProcessor`'s queue or by DMA *before* delivery hands them over, so the monitor needs no cross-queue event.
6. **Pipelines (R6).** Build them with `MTL4Compiler` (`MTL4LibraryDescriptor` with MonitorKit's `MTLCompileOptions`; `MTL4RenderPipelineDescriptor`/`MTL4ComputePipelineDescriptor`), as both app paths do.
   - Use the compiler's asynchronous tasks for specialization.
   - Expose `MonitorShaders.compileOptions` publicly for `LUTProcessor`.
   - Unverified: whether device-made `MTLRenderPipelineState`s are accepted by `MTL4RenderCommandEncoder`. Test it before relying on the classic pipelines.
   - Warm at start-up for the three layer formats in use: `bgr10a2Unorm` and `rgba16Float` (picture), `bgra8Unorm` (scope). A switch to HLG must not stall on a compile.
7. **Render, not compute, into the drawable.** MonitorKit draws a fullscreen triangle with a fragment shader. With every write a render-target write, the app can set **`framebufferOnly = true`** on both layers, which allows lossless framebuffer compression and drops `.shaderWrite` on drawables. One exception: an offscreen snapshot target in tests needs `.renderTarget` usage instead of today's `[.shaderRead, .shaderWrite]` (`MonitorRuntime.swift:199-205`).
8. **Frames (R12).** `MonitorFrame.wrap(_:cache:)` maps through `CVMetalTextureCache` **per frame**. Under Metal 4 those textures would need a residency set per frame, as `LUTProcessor` does (`:684-689`). The app instead builds `MonitorFrame` with its public `init(layout:width:height:packed:luma:chroma:signal:pixelAspectRatio:)` from its **resident IOSurface cache**, created in MonitorKit's formats:
   - v210: `rgba32Uint` at w/6
   - 8-bit biplanar: `r8Unorm`/`rg8Unorm`
   - 10/16-bit biplanar: `r16Unorm`/`rg16Unorm` (not the `r16Uint` the old cache makes)
   - BGRA: `bgra8Unorm`

   The init validates without allocating. Better still, MonitorKit could ship that IOSurface-keyed, residency-aware cache, a port of `MonitorSurfaceTextureCache`, because every Metal 4 host needs it.
9. **Threads and isolation.**
   - Every `MonitorFeed`, `MonitorPass`, `ScopeAccumulator`/`ScopeGroup` and `ScopeRenderer` lives on the app's render thread (`MonitorRenderThread`). That satisfies "confined".
   - Main-actor changes hop with `renderThread.perform`: `burnInLUT`/`monitorLUT` swaps and the signal declaration.
   - `MonitorEngine` and `MonitorLUT` are `@unchecked Sendable` and can be built anywhere.
   - `ScopeStatisticsReader` serves the UI.
10. **Once-per-frame analysis across surfaces.**
    - The app wraps one `MonitorFrame` per arriving frame per feed. It caches it by the frame's stamp, so every surface of the feed sees the same `MonitorFrame.id`.
    - Whichever surface first draws a new frame encodes `feed.analyze` in its own command buffer.
    - Scopes accumulate once per feed per scope tick.
    - Limitation: one focus stage per feed per frame (`MonitorFeed.swift:55-107`). Two surfaces of one feed peaking on different stages will show "mask unavailable" on one. Today each surface computes its own source-stage mask.
11. **Retention.** The host keeps frames and LUTs alive, as today (`frame.retainResources(in:)` + `context.retain`). MonitorKit retains nothing per frame. `retainUntilCompleted` is for replaced persistent objects only.
12. **Freeze (R11).**
    - `freeze(frame, into:)` allocates owned `.private` textures with the same formats and sizes (only on request), registers them through `makeResident`, copies with the compute encoder's `copy`, and adds the producer barrier.
    - It returns a `MonitorFrame` with a stable `id`, so it is analysed once.
    - `release` goes through `retireAfterCompletion`.
    - Only the source planes are copied, since the output stage is computed in-shader. That halves today's freeze memory when an output buffer existed: 4K v210 ≈ 22 MB.
13. **Status.** The app keeps its status strings; `MonitorStatus` reasons map onto them.

### 6.3 What stays app-owned glue (answer: delete `Packages/MonitorTools` entirely)

**Yes, W4 should delete `Packages/MonitorTools` entirely.** MonitorKit covers its pixels, math and settings. The rest is app plumbing, which moves into these app files:

| New app file | Ported from | Contents |
| --- | --- | --- |
| `Sources/App/MonitorGPUContext.swift` | `MonitorRuntime` + `MonitorMetalContext` + `MonitorSurfaceTextureCache` + `MonitorRenderThread` + `MonitorEncodeContext` | Shared device, one `MTL4CommandQueue`, residency set + graveyard, IOSurface texture cache (MonitorKit formats), encode-context pool (bump uniform allocator, conforming to `MonitorMetal4Encoding`), render thread, drawable attach/detach, GPU timing → `AppGPUActivity`, `MonitorEngine`/`ScopeEngine` |
| `Sources/App/MonitorFeedHost.swift` | `MonitorCaptureSink` | Per target: `MonitorFeed`, `MonitorSignalDeclaration` → `SignalDescription`, burn-in and monitor `MonitorLUT`, stamps and out-of-order rules, latest `MonitorFrame` cache, analysed frame id, consumer list |
| `Sources/App/MonitorSurface.swift` | `MonitorSurfacePresenter`, `MonitorPictureNSView`, `MonitorScopeNSView`, `MonitorSurfaceRenderLoop`, `MonitorVisibilityNSView`, `MonitorNativePicture`/`Scope`/`SurfaceVisibility` | Slot, freeze state machine, clean, visibility and demand, statistics, layers, display links; calls `MonitorPass`/`ScopeRenderer` instead of `MonitorToolsRenderer` |
| `Sources/App/MonitorPictureColor.swift` | `MonitorPictureColor` | Kept until MonitorKit's output-colour resolver (R8) replaces it |
| `Sources/Shared/MonitorWorkspace.swift` | `MonitorTargetID`, `MonitorWorkspaceLayout`, `MonitorWorkspaceState`, `MonitorTargetOption`, `MonitorDiagnostics`, `MonitorAvailability`, `MonitorFrameStamp` | Same Codable keys. Plus `LegacyMonitorConfiguration`, `MonitorFeedPreferences`, `MonitorSignalDeclaration`, `MonitorScopePreferences` |
| UI ports, until MonitorKitUI covers them | `MonitorWorkspaceShell`/`MonitorTileChrome` (split layout), `MonitorToolsToolbar` (detached tiles), `MonitorFalseColorLegend`, `MonitorDiagnosticsView`, `MonitorScopeGraticule` (IRE labels) | SwiftUI only |

MonitorKitUI's `MonitorMetalView` should not replace the app's surfaces unless it can use the host's queue, render thread and shared feeds. The app needs one queue for the barrier rules (§6.2, item 5) and one feed per camera.

---

## 7. Features the app has that MonitorKit lacks

1. **Picture stage per surface:** "Output (as published)" vs "Source (camera signal)" (`UICameraColumn.swift:262-285`). `mk_picture` always shows the monitor stage. Needs `MonitorState.pictureStage` or a per-surface "bypass burn-in" (R9).
2. **"As published" pixels.** The app shows the real processed buffer: 1080p, Lanczos, 4:2:0 8-bit when configured. MonitorKit computes output as source resolution + LUT in-shader. That is a semantic change, and an intended one: no monitor-only processing, and no `needsOutput` keeping the GPU busy. Rename the menu item to "Output (LUT)" or similar. If exact published pixels are ever wanted, wrap the processed buffer as a separate `MonitorFrame` with no burn-in.
3. **Clean aperture**: read from CV attachments and used for the shown region and the aspect (`MonitorCaptureSink.swift:277-300`, `MonitorToolsRenderer.swift:481-487`). MonitorKit has PAR only. Needs a crop rect in `MonitorFrame` (R10).
4. **A display-aspect query before encode**, for layer sizing on the main thread (`pictureAspectRatio`). MonitorKit computes `MonitorLayout` inside `prepare`. Needs a public static (R10).
5. **Signal-native HDR output and the layer tagging decision** (§2), plus **primaries in `SignalDescription`** (R8). W2.
6. **Freeze**: pending-freeze-on-next-frame, cancel wins, a lingering hold on unfreeze, a GPU-owned copy that releases the capture buffer, and the configuration frozen with it. MonitorKit has no Freeze yet (R11). The state machine stays in the app.
7. **Scope scheduling**: enable, 10/15/30 Hz, its own display link, ≤ 2 in flight. Host-side by design; keep it in the app.
8. **Master tools switch** (`toolsEnabled`) and the "turning back on doesn't resurrect" rule (`UISupport.swift:122-157`). No MonitorKit field; the UI logic simplifies.
9. **False colour suppresses zebra** (`effectiveZebraEnabled`). MonitorKit draws both. Glue rule, or accept.
10. **Program rules**: focus and log false colour disabled on Program, with the UI text "needs a camera's source picture" (`UIMonitorTools.swift:150-151`). MonitorKit would allow peaking on Program frames. Glue rule (`state.focus.enabled = false` for "program"), or lift the restriction deliberately.
11. **Qualification gates**: false colour refused unless the source profile, transfer string, geometry and correspondence all qualify, with explicit status strings (`MonitorToolsRenderer.swift:363-463`). MonitorKit has `MonitorStatus` reasons (`requiresKnownTransfer`, log mode on a non-log source). Map the strings; check that every old refusal has a MonitorKit reason.
12. **Per-surface diagnostics**: accepted, presented and superseded counts, scope fps, scope skips (busy, no drawable), GPU ms per picture and per scope, failures, live/stale/frozen, PTS age. App glue; MonitorKit only needs nothing per frame.
13. **Visibility-driven demand**: occlusion, minimize, hide and close pause the display link and drop the slot, then feed `AppModel.monitorDemand` and automatic start (`MonitorSurfacePresenter.swift:424-462`, `MonitorCoordinator.swift:255-276`). App glue.
14. **Workspace**: single, side-by-side and 4-up layouts, tile bindings, split ratio, detached windows. App-owned.
15. **Tile chrome, the toolbar for detached tiles, the false-colour legend (Sony, EL Zone, ARRI captions) and the scope IRE labels**. MonitorKitUI is empty; port them or build them in W2.
16. **Out-of-order and generation rejection** (`acceptsInOrder`, `MonitorFrameStamp`; `MonitorSurfacePresenter.swift:220-233`). App glue.
17. **Allocation-free colorimetry and geometry caching per IOSurface on the delivery thread** (`MonitorCaptureSink.swift:205-275`). Keep it in the feed host. `MonitorFrame.signal(of:range:)` is allocation-free but re-reads the attachments every frame.
18. **Resident IOSurface texture cache with idle sweep and flush per target** (`MonitorRuntime.swift:642-801`). App glue, or a MonitorKit helper (R12).
19. **Old scope look**: 768×256 image, −10…110 % range (`scopeBin`), parade colours. MonitorKit's waveform defaults to 1024×512 with other trace curves. A visual change only.
20. **Old zebra look**: a single 45° stripe in target pixels, `(x+y) % 16 < 8`, mixed to white. MonitorKit's stripes differ per set. A visual change only.

---

## 8. Tests

### 8.1 App tests (`Tests/`, run by `scripts/test.sh` and `monitor-app-integration.sh`)

| Test | Action |
| --- | --- |
| `MonitorCoordinatorChecks`: `testFreezingTheOnlySurfacePreservesDemandUntilHideOrClose` (44), `testWindowVisibilityFreezeAndPreviewHideHaveIndependentDemand` (121), `testRebindingSurfaceReleasesOldSinkAndIgnoresOldTeardown` (144), `testNativeToolsAndHiddenPreviewTransitionsPreserveIndependentDemand` (160), `testUnavailableTargetCannotReactivateMonitorConsumers` (195), `testRemovedAndDisabledTargetsReleaseOutputConsumersImmediately` (206), `testLocalScopeVisibilityUnionsDemandWithoutChangingFeedSettings` (225), `testExplicitlyEmptyWorkspaceIsNotRepopulatedByPreferenceUpdates` (257) | Retarget to the rewritten coordinator. The demand semantics are unchanged |
| `…testPausedDiagnosticsAndLayoutCapsFollowCurrentState` (80) | Retarget the diagnostics part; drop any caps |
| `…testCopySettingsPreservesDestinationCameraCalibration` (271), `testCopyFalseColorModeUsesItsProfileWhilePreservingDestinationCalibration` (297) | Retarget: calibration = the per-feed signal declaration; there is no exposure index |
| `…testNativePreviewRejectsLateFramesAfterSourceRebinding` (328) | Keep while `VideoPreviewRenderer` lives |
| `…testProgramMonitoringPreservesProcessingRevisionAndSelectedPixels` (352) | Retarget: Program reaches its feed with `burnInLUT == nil` |
| `…testSteadyOffersReadColorimetryWithoutAllocating` (384) | **Keep**, against `MonitorFeedHost` |
| `MonitorLifecycleChecks.testLegacySnapshotsDefaultMonitoringOff` (6), `testIndependentFeedProgramAndWorkspaceRoundTrip` (14) | Retarget to the new keys. **Add:** a migration test per row of §5.3, a test that the old blob never decodes as `MonitorState`, a test that the legacy key round-trips untouched, and `FeedDescriptor.version` stays 1 |
| `CaptureRecordingIsolationChecks.testProductionMonitorTapsPreserveRecordingAndRejectRetiredDemand` (121), `testPacedProcessedCameraAndRecordingWithMonitorGPUEnabled` (362) | Retarget to the feed host and surfaces |
| `…testActualDownscaleKeepsSourceFocusAlignedAcrossAsymmetricAperture` (285), `testNeedsOutputTreatsABusyLockAsWanted` (720) | Delete: there is no output tap or correspondence. Aperture alignment becomes a MonitorKit pixel test (clean-aperture crop) |
| `Tests/main.swift:66` (`LUT_1D_SIZE` throws) | Retarget: 1D/shaper now parses, so assert it burns in correctly, or assert the app guard (§4.3) |
| `Tests/main.swift`, `EndToEndChecks`, `GPUExtendedChecks`, `CaptureRecordingIsolationChecks` LUT cases | Must pass unchanged with trilinear `MonitorLUT` (§4.4 golden) |
| `Tools/MonitorAppIntegration` (`MonitorAppIntegrationChecks`) | Retype; keep `hardware: .offline` |

### 8.2 `Packages/MonitorTools/Tests` (goes with the package)

- **Port as MonitorKit pixel and reference tests** (owner: MonitorKit):
  - `MonitorQualityTests` (9): Sony Pattern 2 at every native code, colour signal IRE, minification box average, focus impulse rejection, Scharr against a CPU oracle, thin focus at 2:1, fractional minification, scope density stability.
  - `ELZoneMetalTests` (2), `SonyARRIStyleMetalTests` (6), `ProcessedFalseColorGeometryTests` (1), `SourcePictureGeometryTests` (3), `MonitorSamplingTests` (2), `SourceInterpretationGuardTests` (2).
  - The `MonitorMetalTests` cases: GPU zebra + scope (97), ARRI source before LUT (117), source focus despite flat output (145), scope RGB order and extended axes (176), centred zebra band (195), HDR not retagged as SDR (223), ARRI full rescaled table (243), asymmetric clean aperture (282), graticule toggle (315), malformed planar height (336), every ARRI 10-bit boundary (359), declared log code view with zebra and source focus (414).
  - `MonitorCoreTests` geometry and migration cases (8-160, 179-217), against `MonitorLayout` and the app's legacy decoder.
  - Core `ColorAnalysisTests`, `ELZoneProfileTests` and `SonyFalseColorTests` are already ported (`Packages/MonitorKit/Tests/MonitorKitCoreTests`).
- **Move into app tests** for the ported glue: the `MonitorToolsUITests` presenter, freeze, visibility and colour cases (27). Freeze/hold (15, 32, 254, 297, 312, 347, 712, 802, 852), visibility/display link (326, 372, 750), layer colour (614, 662), out-of-order (828), scope locality (877), layouts (179, 200, 558), zoom (903). Plus `SonyFalseColorUITests` (5), against the ported legend and settings.
- **Delete:** `MonitorMetalTests` 36, 51 and 75 (build retry and texture cache; re-home 75 if the cache is ported), `TiledMonitorKernelTests` (2), `MonitorCoreTests` revision/gate cases (167, 219) if the stamp logic changes.

---

## 9. Build, project and scripts

### 9.1 Project generation

- **`scripts/generate_project.py` is the only source of truth.** `scripts/build.sh` regenerates `Ultracam.xcodeproj` on every build; never hand-edit the pbxproj.
  - Today: `XCLocalSwiftPackageReference(relativePath="Packages/MonitorTools")` and products `MonitorToolsCore`/`Metal`/`UI` (`:87-89`), linked into **the app target only** (`:95`, `:114`), with `packageReferences` at `:125`.
  - W4: `Packages/MonitorKit` with `MonitorKitCore`, `MonitorKit`, `MonitorKitScopes` and `MonitorKitUI` (+ `MonitorKitAudio` only if the meters are used). Both references can coexist during the transition. **No single Swift file may import both packages**: `MonitorRect`, `ELZoneProfile`, `SonySLog3FalseColor`, `ARRIFalseColorProfile` and others exist in both.
  - `LUTShaders.metal` stays a copied app resource ("Copy GPU Shader Source", `:109`).
- **`scripts/validate_bundle.py:59-65`** (run by `build.sh`): today it requires `*MonitorToolsMetal.bundle` containing `MonitorTools.metal.txt` and forbids "MonitorTools" in the extension. W4 requires:
  - `MonitorKit_MonitorKit.bundle` containing `Shaders/MKLUT.msl`, `MKDecode.msl` and `MKMonitor.msl` (`Package.swift` `.copy("Shaders")`)
  - `MonitorKit_MonitorKitScopes.bundle` containing `Shaders/MKScopes.msl`
  - no "MonitorKit" anywhere in the camera extension
- **Camera extension version bump rule** (commits `0ccf83c`, `52d21ab`, `94d0ec5`):
  - Bump `Config/Camera-Info.plist` `CFBundleVersion` (now 6) when anything the extension compiles or ships changes, along with the app's `CFBundleVersion` (now 18). Otherwise macOS keeps the installed extension.
  - That covers `Sources/CameraExtension/*`, `Sources/Shared/VideoContract.swift`, `VideoBufferLayout.swift`, `VirtualCameraRegistry.swift` and `VirtualCameraRegistryTransport.swift` (`generate_project.py:31-35`), plus its plist, its entitlements and the deployment target.
  - **W4 should touch none of these**, so no extension bump is needed. If it does, bump; installing needs the user.
- Swift settings:
  - The app is Swift 5 mode with complete concurrency checking and warnings as errors; MonitorKit is Swift 6 with `.treatAllWarnings(as: .error)`. Importing works.
  - A new compiler warning in MonitorKit breaks the app build.
  - `@_exported import MonitorKitCore` (`MonitorKit.swift`) brings Core names into every importing file.

### 9.2 Scripts (all need `/Volumes/8TB` mounted)

| Script | What it does | Safe without asking? | W4 change |
| --- | --- | --- | --- |
| `scripts/ui-typecheck.sh` | `swiftc -typecheck` of the Shared, Recording and App sources against the package | **Yes** (fastest gate) | Switch the sourced helper |
| `scripts/test.sh` | Builds the package and runs its `swift test` (`:21-27`), Rust, the DeckLink backend in testing mode, and the `lut-tests` binary (app subset + `Tests/*`). Synthetic only | **Yes** | Helper → MonitorKit (scratch path). Replace `MonitorCoordinator.swift`/`MonitorCaptureSink.swift` (`:60`) with the new glue files |
| `scripts/ui-verify.sh` (`FORCE=1`) | Offscreen render of every screen; real `AppModel(…, hardware: .offline)` with a throwaway suite | **Yes** | **The input hash (`:21-23`) walks `Packages/MonitorTools/Sources` and no `*.msl`.** Walk `Packages/MonitorKit/Sources` and add `-name '*.msl'`, or shader edits won't invalidate the cache |
| `scripts/monitor-app-integration.sh` | Real `AppModel` (`.offline`) + `MonitorCoordinatorChecks` + capturing registry; no CMIO | **Yes** | Helper + source list |
| `scripts/monitor-tools-package.sh` (sourced) | Builds the 3 products into a shared scratch, sets `monitor_link_args`, copies the bundles | n/a | Add `monitor-kit-package.sh`: products `MonitorKitCore MonitorKit MonitorKitScopes MonitorKitUI`; `-lMonitorKitUI -lMonitorKitScopes -lMonitorKit -lMonitorKitCore` (+ `-lMonitorKitAudio -framework Accelerate`) `-framework Metal -framework QuartzCore -framework CoreVideo -framework SwiftUI`; bundle check for both `.bundle`s. Callers: `test.sh:21`, `ui-typecheck.sh:16`, `ui-verify.sh:33`, `monitor-app-integration.sh:19`, `camera-smoke.sh`, `monitor-tools-recording.sh`, `monitor-tools-smoke.sh` |
| `scripts/camera-smoke.sh` (no args) | Build only | Yes | Drop the `CubeLUT.swift` path (`:36`), link MonitorKitCore. `--run`/`--full`/`--consumer`/`--monitor*` use the installed extension: **ask** |
| `scripts/monitor-tools-{smoke,recording,benchmark,admission-checks,stress}.sh`, `monitor-tools-fingerprint.py` | Synthetic harnesses for the old runtime | Yes | Retire with the package (`monitor-tools-recording.sh:24` also compiles `CubeLUT.swift`) |
| `scripts/build.sh --debug` | Regenerates the project and builds the Debug app into `agent-work`; runs `validate_bundle.py` | Yes, when nobody else has project edits in flight | — |
| `scripts/app-self-test.sh` (`SKIP_BUILD=1`) | Launches a second, Debug app with `--ui-self-test`; never starts cameras | Yes **without `LIVE=1`**; it uses the Debug preferences, so back them up first | — |
| `scripts/ui-tour.sh` | Drives the Debug build by its own PID; saves and restores its preferences | Yes **without `LIVE=1`** | — |
| `swift test --package-path Packages/MonitorKit --scratch-path <own>` | MonitorKit's tests; GPU tests skip without Metal | Yes | — |
| Anything with `LIVE=1`, installer actions, or quitting or killing the installed app | Real UltraStudio or extension | **No** | — |

**MonitorKit test retries** (`monitor-kit-package.sh`, used by `test.sh`): a failed `swift test` run is retried once, from the same build, only when the log accounts for every case and each failed case is allowlisted *and* every assertion it failed is a numeric less-than timing budget (CPU or GPU); in the two mixed cases (the inline-shader contract test and the handoff stress test) it must also carry that budget's own message. A pixel-identity, pipeline, deadlock, leak, race or order check (`XCTAssertEqual`/`True`/`Nil`, a floor, a thrown error), a failed case with no assertion line, or an incomplete run fails at once. Each retried case is logged as FLAKY. `monitor-kit-package.sh selftest` (run by `test.sh`) holds the fixtures.

**`AppHardware`** (`AppModel.swift:23-50`): `AppModel.init` defaults to `hardware: .live`. **Any tool or test that builds an `AppModel` must pass `.offline`**, as `MonitorAppIntegration` and `UIVerify` do. Only `UIAppEnvironment.model` (the real app) uses `.live`.

---

## 10. Ordered W4 plan

Gates:
- **T** = `ui-typecheck.sh`
- **U** = `test.sh`
- **V** = `ui-verify.sh FORCE=1`
- **I** = `monitor-app-integration.sh`
- **K** = MonitorKit `swift test`
- **B** = `build.sh --debug` (+ `validate_bundle.py`)
- **S** = `app-self-test.sh` (non-live)

0. **Preconditions.**
   - W2 has landed and been audited: the Metal 4 path (R1-R7), HDR/output colour (R8), Freeze (R11), `pictureStage` (R9), clean aperture and the aspect query (R10).
   - Re-run the greps in §3 and refresh the line numbers.
   - Back up `~/Library/Preferences/org.ultracam.app.plist` by path.
   - Gate: T, U, I, V green on the baseline.
1. **Plumbing, no behaviour change.**
   - `generate_project.py`: add the MonitorKit reference beside MonitorTools.
   - Add `monitor-kit-package.sh`.
   - `validate_bundle.py`: accept the new bundles.
   - `ui-verify.sh`: fix the hash.
   - `test.sh`: also run MonitorKit `swift test`.
   - Gate: T U V B K.
2. **LUT, atomic** (§4.3, §4.4): `Sources/Shared/CubeLUT.swift` (delete), `LUTShaders.metal` (drop the copy), `LUTProcessor.swift` (`MonitorLUT`, `LUTParameters`, compile options, no wait on load), `CaptureController.swift` (`load(MonitorLUT)` + cube convenience), `AppSettingsStore.swift` (import), `Tests/main.swift:66`, the two scripts' `CubeLUT.swift` paths.
   - Golden trilinear equality.
   - Risk: the include guard and struct size; `ULTRACAM_METALLIB` concatenation.
   - Gate: U (every LUT test), T.
3. **Shared device and one `MonitorLUT` per load**: `AppModel.swift` (`uploadLUT`, `restoreHeadlessLUT`) builds the LUT once and gives it to the controller and the feed host; `LUTProcessor` takes the device. Gate: U T, then a Debug build that loads, restores and forgets a LUT.
4. **Settings schema** (§5): `Sources/Shared/MonitorWorkspace.swift` (app-owned workspace types + `LegacyMonitorConfiguration` + new preference types), `AppSettingsStore.swift` (new keys, legacy decode, legacy passthrough), `FeedRuntime.swift`, `AppModel.swift`.
   - The coordinator still runs on MonitorTools; convert at its boundary.
   - Gate: U (`MonitorLifecycleChecks` + new migration tests), I, V.
5. **GPU context + feed host**: add `MonitorGPUContext.swift` (bump uniforms ≥ 32 KB per context; MonitorKit conformances) and `MonitorFeedHost.swift`.
   - `CaptureController.swift`: delete `needsOutput` (386-388, 1001, 1008, 1025), the output offer and correspondence (1098-1110), `monitorWantsOutput` (`DeliveryItem` 1323-1326) and the `monitorProcessingRevision` stamps.
     - Keep the in-order source offer, including `afterCommittedFrames` (1069-1081).
     - The monitor no longer forces GPU processing.
   - `ProgramOutputBridge.swift` `ProgramMonitorTap`: source only.
   - Gate: U, I.
6. **Surfaces**: add `MonitorSurface.swift` (render loop on `MonitorPass`/`ScopeRenderer`; layers `framebufferOnly = true`; pipelines warmed for `bgr10a2Unorm`/`rgba16Float`/`bgra8Unorm`), port `MonitorPictureColor` or use R8, rewrite `MonitorCoordinator.swift`, delete `MonitorCaptureSink.swift`.
   - UI: `UIAppProviders.swift`, `MonitorWorkspaceView.swift`, `UICameraColumn.swift` (zoom → magnification; the stage menu), `UIMonitorTools.swift`, `UISupport.swift`, `UIContext.swift`, `UISessionBridge.swift`, `UIDiagnostics.swift`, `UISettings.swift:648`.
   - Tests §8.1.
   - Gate: U I V S, plus counters: 0 copies per frame, presented fps = the source rate on a 60 Hz display, 0 allocations per steady frame, GPU per 4K→1080p pass within the 0.5 ms budget, and the HLG/PQ layer switch as in §2.
7. **Optional routing UI**: monitor-only LUT (`FeedDescriptor.monitorLUTBookmark`/`monitorLUTEnabled`/`lutInterpolation`), wired to `MonitorFeed.monitorLUT`. Gate: V S.
8. **Retire MonitorTools**:
   - Remove its reference from `generate_project.py`.
   - Delete `Packages/MonitorTools`, `Tools/MonitorTools*`, `scripts/monitor-tools-*.sh` and `monitor-tools-fingerprint.py`.
   - Drop the old checks in `validate_bundle.py`.
   - Port the package tests (§8.2).
   - Gate: T U V I K B S.
9. **Hands-on with the UltraStudio** only with the user's explicit go-ahead: it needs `LIVE=1` or the installed app quit.

**Top risks:**
1. Settings data loss through the partial decode (§5.2).
2. The LUT struct and include guard (§4.3).
3. Uniform capacity and argument-table bind counts (§6.2) cause precondition crashes or silent mis-binding.
4. Missing barriers or residency under Metal 4 show up as intermittent garbage, not errors. Test with the Metal validation layer (`MTL_DEBUG_LAYER=1`) in `test.sh` runs.
5. Behaviour changes that need sign-off: the in-shader output vs "as published", zebra together with false colour, peaking on Program, overlay white level in HDR, the trilinear vs tetrahedral default.
6. Preview vs output differ by ULPs until the compile options match (R6).
7. One focus stage per feed.
8. Warnings as errors in the package on a toolchain change.

---

## 11. Library requirements before W4 (beyond what exists)

Status as of 2026-10-22, before W4 (W2 is `a1b652a`; the W3 gap work landed in the MonitorKit commits after it). Each requirement keeps its original wording; the indented line says what shipped.

- **R1** A Metal 4 encode path for `MonitorFeed.analyze`, `MonitorPass.encode`/`prepare`/`draw`, `ScopeGroup`/`ScopeAccumulator.accumulate`, `ScopeRenderer.render` and Freeze. It takes the host's `MTL4CommandBuffer` through a confined host protocol (`MonitorMetal4Encoding`, §6.2) and never creates command buffers or queues, commits, waits or adds handlers.
  - **Done (W2).** As a value, not a protocol: `MonitorSubmission` (the host's `MTL4CommandBuffer`, its index ≥ 1, the contiguous `completedIndex`, optional `uniforms`) is taken by `MonitorFeed.analyze`/`freeze`, `MonitorPass.encode`/`prepare`/`draw`/`encodeCompute`, `MonitorMultiview.encode`, `ScopeAccumulator`/`ScopeGroup.accumulate` and `ScopeRenderer.render`/`prepare`/`draw`, each also with a host-encoder overload. No queue, command buffer, allocator, commit, wait or handler (source-scan contract test).
- **R2** Uniforms through a host transient allocator (`allocateUniforms(length:) -> (pointer, gpuAddress)`, 256 B aligned; ≈ 3.4 KB per picture, ≈ 250 B per focus pass, plus the scope sizes, documented). No `set*Bytes`.
  - **Done (W2).** `MonitorUniformAllocator.allocateUniforms(length:) -> MonitorUniformAllocation` in `MonitorSubmission.uniforms`, or the library's own `MonitorUniformRing`s when nil. Sizes are the `uniformLength` constants (§6.2 item 3): `MonitorPass` 5120, `MonitorFeed` 1024, `ScopeAccumulator` 1280, `ScopeGroup` 2048, `ScopeRenderer` 768 + `graticuleUniformLength` 2304.
- **R3** Library-owned `MTL4ArgumentTable`s, one per pass, feed or scope object, created at init with documented bind counts. Reused across frames, relying on Metal 4's binding snapshot at encode time.
  - **Done (W2).** One table per object, made on its first Metal 4 encode or ahead of it (`ScopeAccumulator`/`ScopeGroup`/`ScopeRenderer.prepareMetal4()`): pass 7 textures / 5 buffers, feed 6 / 4, accumulator 5 / 6, group 5 / 15, renderer 2 / 3. Hosts rebind their own table after a library draw in their encoder.
- **R4** Residency through a host hook (`MonitorResidencyHost.makeResident` when an allocation is created; `retireAfterCompletion` when one is replaced). No residency commit per frame. All persistent allocations are enumerable (placeholders, masks, bins, stats, trace and graticule textures, freeze copies).
  - **Done (W2), shaped differently.** The library owns a `MonitorResidency` (`MonitorEngine.residency`, shared with `ScopeEngine(…, residency:)`): the host attaches `residency.set` to its queue once. Allocations are added once and committed only when membership changes; replaced or deinitialised resources are retired by submission index (`retire`, `observe`, `release(through:)`). Host frames stay host-resident (`MonitorFrame.addResidency(to:)`, `MonitorTextureCache`).
- **R5** Correct Metal 4 barriers inside the library's encoders (§6.2, item 5). Documented requirement: all MonitorKit work for an engine goes on one `MTL4CommandQueue`.
  - **Done (W2).** Barriers per ARCHITECTURE.md "Barriers", skipped once the writer's submission is known complete; the one-queue rule is in the contract.
- **R6** `MTL4Compiler`-built pipelines with `mathMode = .safe` and MSL 4.0/4.1, asynchronous specialization through compiler tasks, and a public `MonitorShaders.compileOptions` so `LUTProcessor` compiles `mk_applyLUT` identically. Verify whether classic `MTLRenderPipelineState`s work with `MTL4RenderCommandEncoder`.
  - **Done (W3 gap work), picture engine only.** `MonitorEngine(…, compiler: (any MTL4Compiler)?)` builds the library and every picture, focus and Freeze pipeline with the host's compiler and `MonitorShaders.compileOptions` (public; safe math, MSL 4.0/4.1); asynchronous specialization awaits the compiler's async API from `Task.detached`. Device-built pipeline states are verified to draw in MTL4 encoders. `ScopeEngine` builds with the device unless made with a `cacheDirectory` (W6, below).
  - **Done (W6): persistent warm start.** `MonitorEngine(device:cacheDirectory:)` and `ScopeEngine(device:residency:cacheDirectory:)` build through a `MonitorPipelineArchive`: its own plain `MTL4Compiler`, every pipeline looked up first in the Metal 4 archive files of earlier launches, the session recorded by a second, serializer compiler at each save (synchronously: an asynchronous build by a serializer compiler crashes on macOS 27). The app passes `MonitorGPUContext.appPipelineCacheDirectory` (`Library/Caches/<bundle id>/MonitorKitPipelines`, nil in tests and tools) to both; `Core.compiler` is `engine.compiler`. `Core.warmUp` warms both engines with `save: false` and saves each archive once at the end. Only the newest file per key is opened at launch (about 3 ms; older ones at the first miss; 3 kept). With a warm system shader cache the archive costs about 3 ms more at launch than the plain compiler (init 3.0–3.4 ms + warmUp 2.8–3.1 ms against 0.2–0.3 + 2.9–3.4 ms, flat from 1 to 5 launches' files); its gain is a launch after the system cache was purged.
- **R7** Render-target picture and scope passes into `bgr10a2Unorm`, `rgba16Float` and `bgra8Unorm` drawables with `framebufferOnly = true`; a warm-up API for those formats.
  - **Done.** Render passes into `framebufferOnly` drawables in all three formats (tested for the picture). Warm-up: `MonitorEngine.warmUp(targets:layouts:surfaces:)` with `MonitorEngine.standardTargetFormats` and `MonitorSurfaceConfiguration`; `ScopeEngine.prepare(pixelFormats:)` with `ScopeEngine.drawablePixelFormats`, `isPrepared(pixelFormat:)`. Still open: a Metal 4 scope test into a `framebufferOnly` drawable.
  - A Program surface's `MonitorSurfaceConfiguration` sets `isProcessed: true`. `warmUp` builds each surface's own all-tools stand-in (the compute one for a compute surface), so hosts no longer list a compute surface's format in `targets` or call `prepareCompute` separately (12e6b11).
- **R8** HDR/EDR output that matches §2:
  - a signal-native write mode
  - an output-colour resolver (pixel format, `CGColorSpace` name, `wantsExtendedDynamicRangeContent`, `CAEDRMetadata` kind) from the stage signal
  - `SignalDescription.primaries`, read from `kCVImageBufferColorPrimariesKey` in `signal(of:range:)`
  - a declared output encoding per `MonitorLUT`, default Rec.709
  - the overlay white level in HDR, defined and documented
  - **Done (W2).** `MonitorOutputColor.signalNative` (pixel-identical to W1), `MonitorOutputColor.layer(for:displayTransform:monitorStageHasLUT:)` → `MonitorLayerColor` (pixel format, `ColorSpace`, EDR, `EDRMetadata`; MonitorKitUI's `apply(to:)`), `SignalDescription.primaries` read independently of the transfer, `MonitorLUT.outputEncoding` (`LUTOutputEncoding.rec709`), overlays at BT.2408 graphics white (203 cd/m²: 58 % PQ, 75 % HLG).
- **R9** A picture-stage selection per surface (`MonitorState.pictureStage: SignalStage` or equivalent), so the app's Source/Output picture menu survives.
  - **Done (W3 gap work).** `MonitorState.pictureStage` (default `.monitor`), function constant 16 (`MK_PICTURE_STAGE`); `MonitorStatus.pictureStage`; `MonitorState.pictureHasLUT(burnInLUT:monitorLUT:)`, and `MonitorFeed.monitorStageHasLUT(for:)` now follows the picture stage.
- **R10** A clean-aperture or region-of-interest crop on `MonitorFrame`, and a public, allocation-free display-aspect query (`MonitorLayout` for frame + state) for sizing the layer on the main thread.
  - **Done (W3 gap work).** `MonitorFrame.cleanAperture` (validated in `init`; read by `wrap`, `MonitorTextureCache.frame` and static `MonitorFrame.cleanAperture(of:)`), `MonitorFrameGeometry` (`shownRect`, `displayAspectRatio(for:)`), `MonitorFrame.geometry(of:)`, `MonitorLayout(frame:state:viewport:)` and `MonitorLayout.aperture`. The aperture's vertical offset points down (ISO/IEC 14496-12 `clap`): the app's `(H−h)/2 − verticalOffset` in `MonitorCaptureSink` is mirrored; use `MonitorFrame.cleanAperture(of:)`.
- **R11** Freeze:
  - Encoded into the host's buffer with the compute encoder's copy.
  - Owned `.private` textures registered through R4 and released through `retireAfterCompletion`.
  - A stable `MonitorFrame.id` for the frozen frame.
  - Copies only the source planes.
  - Documented memory.
  - **Done (W2), with two differences.** `MonitorFeed.freeze(_:into:)` (classic and Metal 4) copies with a compute kernel (`mk_copyUint`/`mk_copyFloat`), not the encoder's `copy`, into `.private` feed-owned planes made resident in `engine.residency` and retired by submission index; only the source planes are copied; the frozen frame keeps a stable `id`; 22.3 MB for 4K v210 (`persistentMemoryBytes`). `unfreeze(keepingMemory:)` releases them.
- **R12** Documented texture formats for host-built `MonitorFrame`s. Optionally an IOSurface-keyed, residency-aware texture cache helper (a port of `MonitorSurfaceTextureCache`), because `wrap(cache:)` per frame does not suit Metal 4 residency.
  - **Done.** The format table is on `MonitorFrame`; `MonitorTextureCache` (IOSurface-keyed, residency-aware, idle sweep, `flush(owner:)`) is the port of `MonitorSurfaceTextureCache`.
- **R13** Optional: make foreign `schemaVersion: 1` JSON fail closed (a type discriminator or schema 2) before any host persists `MonitorState`.
  - **Done (W3 gap work).** `MonitorState` writes `"kind": "MonitorKit.MonitorState"` and `schemaVersion` 2 and throws `DecodingError.dataCorrupted` for anything else, MonitorKit's own discriminator-less W1/W2 JSON included. `ScopeSettings` is still lenient (schema 1, no `kind`).
- **R14** `MonitorStatus` reasons covering every old refusal string (§7, item 11), and a "code-value view" label for declared log sources shown without a transform.
  - **Done (W3 gap work).** New `MonitorUnavailableReason.requiresCameraSignal` (with `MonitorFrame.isProcessed`) and `.unsupportedGeometry` (on the new `MonitorTool.picture`); `MonitorStatus.isCodeValueView` and `codeValueViewNote`, with a `.picture` label such as "S-Log3 code values". The EI ≠ 800 and profileID/specVersion refusals have no equivalent by design.
  - An untagged buffer (no `kCVImageBufferTransferFunctionKey`, or one MonitorKit does not read, such as ST 428-1 or a plain gamma) is BT.709 under `signal(of:range:)`, and when `wrap`/`MonitorTextureCache.frame` get no `signal`. For MonitorTools' refusal ("unsupported transfer; showing code values"), the host passes `MonitorFrame.signal(of: pb, range: r, untaggedTransfer: .unknown)` as the frame's `signal` (12e6b11).
- **R15** MonitorKitUI parity, or a decision that the app keeps its ports: the false-colour legends (Sony Pattern 2, EL Zone, ARRI), the scope scale labels (−10…110 IRE), the tile toolbar.
  - **Done (W3 gap work).** `FalseColorLegendView(legend:style: .captioned, unavailable:)` with the captioned legend fields, `ScopeIREScale`/`ScopeIREScaleView` (−10…110 IRE), `MonitorTileToolbar` with `MonitorTileTool`, `MonitorFreezeState`, `MonitorMagnifyChoice`; `ScopeSettings.ultracamLegacy(mode:stage:)` (now `plainWaveform(mode:stage:)`) for the old 768 × 256 scope look.
  - Program tile glue: pass `falseColorModes: FalseColorMode.allCases.filter { !$0.needsLogSource }` to `MonitorTileToolbar` on Program, so six band and custom stay available (as `MonitorWorkspace.falseColorModeIsAvailable` does), and pass `layout:` (the shown frame's `PixelLayout`) so the ARRI legend's range matches the GPU (12e6b11).
- **R16 (W6)** Per-stage decode, for a camera declared with another range than its format's (or a SMPTE 240M camera whose burn-in reads BT.709): the Source stage reads the declared range and tagged matrix, the Output and Monitor stages what Program, recording and the virtual camera get.
  - **Done (W6).** `SignalDescription.outputReading` (`SignalReading(range:matrix:)`), set in `MonitorFeedHost.interpret` to the pixel format's range and the matrix `LUTProcessor.parameters` decodes (BT.709 for any but BT.2020 and BT.601; an untouched frame keeps its tag), nil when equal. Every pass gets the same frame with both readings (`MonitorFeedHost.frame(_:in:core:)`, no per-stage relabelling); a Freeze's owned copy keeps both, so a held picture's tools read every stage as the live one. MonitorKit decodes the Output and Monitor stages a second time with that reading (exact at 940/64), and binds each stage's reading for focus and scopes (`MonitorFrame.parameters(for:)`). `UIScopeDescription` labels the stage it measures (`signal.signal(for: stage)`), as `ScopeAccumulator` does. The specialized pipeline compiles the second decode only when a drawn tool reads those stages (+7.4 % of a 4K picture with zebras and clip indicators there, nothing otherwise).
- **R17 (W6)** HLG → SDR by a published method.
  - **Done (W6).** Report ITU-R BT.2446-1 Method C (38 % HLG → 53.2 % SDR, 50 % → 70 %, 75 % → 96 %; 100 % SDR at about 82.9 % HLG), then BT.2407 §2 into BT.709; PQ → SDR stays BT.2408 Annex 5. MATH.md §5.1.
