# Integrating MonitorKit

A step-by-step guide for hosts that own their GPU work: the Encode tier on classic Metal and on Metal 4, then the parts every monitor needs (HDR layers, multiview, Freeze, scopes, audio), the pitfalls, migration notes, and a worked example modelled on Ultracam, MonitorKit's first host. For the batteries-included view (`MonitorView`), the [README](../README.md#1-a-monitor-view-monitorkitui) is enough.

Every Swift sample here is compiled against the package. The rules behind each step are in [ARCHITECTURE.md](ARCHITECTURE.md).

Contents:

1. [The objects and where they live](#1-the-objects-and-where-they-live)
2. [Frames](#2-frames)
3. [Classic Metal, step by step](#3-classic-metal-step-by-step)
4. [Metal 4, step by step](#4-metal-4-step-by-step)
5. [HDR and layer colour](#5-hdr-and-layer-colour)
6. [Several surfaces](#6-several-surfaces)
7. [Freeze](#7-freeze)
8. [Scopes and their cadence](#8-scopes-and-their-cadence)
9. [Audio meters](#9-audio-meters)
10. [Worked example: an Ultracam-style monitor](#10-worked-example-an-ultracam-style-monitor)
11. [Pitfalls](#11-pitfalls)
12. [Migration notes](#12-migration-notes)

## 1. The objects and where they live

| Object | How many | Thread |
| --- | --- | --- |
| `MonitorEngine` | One per GPU | Any (`Sendable`) |
| `ScopeEngine` | One per GPU, sharing the engine's `MonitorResidency` | Any |
| `MonitorLUT` | One per loaded `.cube`, shared by the output path and the monitor | Any |
| `MonitorTextureCache` | One per GPU (Metal 4 hosts) | Any |
| `MonitorFeed` | One per video feed (camera, Program) | Render thread |
| `MonitorPass` | One per surface (a tile, a window, a thumbnail) | Render thread |
| `ScopeAccumulator`, `ScopeGroup`, `ScopeRenderer` | Per scope surface | Render thread |
| `AudioMeter` | One per audio stream | `process` on the audio thread |

The confined objects have no locks: keep them on one thread (one render thread for every surface is simplest, and it is what makes "one queue" natural on Metal 4). Changes from the main thread (a new LUT, a new signal declaration, a state edit) hop to the render thread with the values; `MonitorState` and `SignalDescription` are values and `MonitorLUT` is immutable.

## 2. Frames

A `MonitorFrame` borrows the textures of one picture. Three ways to get one:

- `MonitorFrame.wrap(_:cache:signal:)` through a `CVMetalTextureCache`. Simple, fine for the classic path. Each call maps fresh textures.
- `MonitorTextureCache.frame(_:signal:owner:now:)`: textures made once per IOSurface and kept, already in the engine's residency set. The Metal 4 path should use this (or its own equivalent): per-frame textures would each need a residency change.
- `MonitorFrame(layout:width:height:packed:luma:chroma:signal:pixelAspectRatio:cleanAperture:)` over textures you made, in the formats of the table in [API §3.2](API.md#32-monitorframe).

Declare what the codes mean. CoreVideo attachments give the matrix, transfer, primaries and chroma siting (`MonitorFrame.signal(of:range:)`); a log profile is never inferred, so declare it per feed:

```swift
import CoreVideo
import MonitorKit

func cameraSignal(_ pixelBuffer: CVPixelBuffer, declaredLog: LogEncoding?) -> SignalDescription {
  let range = MonitorFrame.layout(for: CVPixelBufferGetPixelFormatType(pixelBuffer))?.range ?? .legal
  var signal = MonitorFrame.signal(of: pixelBuffer, range: range)
  if let declaredLog { signal.encoding = .log(declaredLog) }
  return signal
}
```

When your output path reads the codes differently from the camera's declaration, give the signal both readings rather than drawing each stage from a relabelled frame: `signal.outputReading = SignalReading(range:matrix:)` is how your burn-in LUT and real output decode them (for example the pixel format's legal range when the user declares a camera full range, or BT.709 when your processing decodes a SMPTE 240M source as BT.709). The Source stage and log false colour keep `range` and `matrix`; the Output and Monitor stages, and every tool, scope and focus analysis on them, use `outputReading`, all in one pass of one frame. Leave it nil when the readings agree. Hand the same frame to every pass (picture, analysis, scopes, Freeze): MonitorKit resolves each stage itself (`SignalDescription.signal(for:)`, `MonitorFrame.parameters(for:)`), and a frozen copy keeps both readings. Labels that describe one stage (a scope's graticule, an interpretation line) use `signal.signal(for: stage)`.

```swift
import MonitorKit

/// A camera the user declared full range, on a legal-range link that the burn-in reads as legal.
func declaredFull(_ native: SignalDescription) -> SignalDescription {
  var signal = native
  signal.range = .full
  let output = SignalReading(range: native.range, matrix: native.matrix)
  signal.outputReading = output == signal.sourceReading ? nil : output
  return signal
}
```

Mark processed pictures (a programme mix, a scaled or graded render) with `frame.isProcessed = true`: log false colour and peaking need the camera's own signal and then report `.requiresCameraSignal`. Each new picture needs a new `MonitorFrame` (a fresh `id`); the focus mask belongs to the `id`.

Keep every frame alive until the GPU work that reads it has completed.

## 3. Classic Metal, step by step

1. **Engine and warm-up, at start-up.** `MonitorEngine(device:)` compiles the library. `warmUp()` (call it off the main thread) builds the all-tools pipelines for `bgr10a2Unorm`, `rgba16Float` and `bgra8Unorm`, the focus kernels and Freeze's copy kernels, so no frame waits for a compile. Specialized pipelines then build asynchronously while the all-tools one draws (identical pixels for signal-native SDR, within 1e−5 otherwise).
2. **A feed per source, a pass per surface.** `engine.makeFeed()`, `engine.makePass()`. Set `feed.burnInLUT` / `feed.monitorLUT` when LUTs load.
3. **Per frame, per feed: analyse once.** `feed.analyze(frame, focus:, into:)` before any pass that shows peaking. Pass the focus settings of the surfaces showing peaking (one stage per feed per frame), or `enabled = false` when none does: that releases the mask.
4. **Per surface: encode.** `pass.encode(frame:feed:state:target:viewport:clear:into:)` into the drawable or any texture; or `prepare` + `draw(with:)` inside your own render pass.
5. **Commit and present.** Yours to do. Keep the frame alive until the command buffer completes.

```swift
import Metal
import MonitorKit
import QuartzCore

final class ClassicSurface {
  let pass: MonitorPass
  var state = MonitorState()

  init(engine: MonitorEngine) { pass = engine.makePass() }

  func draw(_ frame: MonitorFrame, feed: MonitorFeed, drawable: any CAMetalDrawable, queue: MTLCommandQueue) throws {
    guard let commandBuffer = queue.makeCommandBuffer() else { return }
    try feed.analyze(frame, focus: state.focus, into: commandBuffer)
    let viewport = MonitorViewport(width: drawable.texture.width, height: drawable.texture.height, pixelsPerPoint: 2)
    try pass.encode(frame: frame, feed: feed, state: state, target: drawable.texture, viewport: viewport,
                    into: commandBuffer)
    commandBuffer.addCompletedHandler { _ in _ = frame }
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
```

**Unretained command buffers.** With `makeCommandBufferWithUnretainedReferences()`, also keep the LUTs, feeds, passes and scope objects alive until their last command buffer completes. Replaced focus masks, bins and textures stay referenced for three more uses (`MonitorFeed.retiredFrames`); a feed nobody analyses any more keeps them until `releaseRetired()`, which you call once its last command buffer completed.

## 4. Metal 4, step by step

The library never begins, ends or commits a Metal 4 command buffer and never creates a queue, allocator, residency set or argument table per frame. What it needs from you:

1. **One queue.** All of an engine's work goes on one `MTL4CommandQueue`. The library's barriers are queue barriers; they order nothing across queues. Frames written by another queue (an output encoder) or by DMA must be complete before you hand them over, as they are when delivery follows completion.
2. **Residency, once.** `queue.addResidencySet(engine.residency.set)`: everything MonitorKit owns or reads for you (placeholders, focus masks, Freeze planes, uniform rings, argument tables' resources, LUT textures, and the frames of a `MonitorTextureCache` built on that residency). Give the `ScopeEngine` the same `MonitorResidency`. Your drawables are in `layer.residencySet`: add it too, and add it again when a pixel-format change gives the layer a new set. Host-made textures (frames, offscreen targets) are yours to make resident, once when they are made, never per frame (`MonitorFrame.addResidency(to:)`).
3. **Submission indices.** Number command buffers from 1 (0 means "none"; `MonitorSubmission.init` traps on 0). Every encode into one command buffer shares its index. Commit every index you hand out, even when encoding failed, or the watermark below stops moving.
4. **The completion watermark.** `completedIndex` is the highest index such that it and every earlier one have completed (or were abandoned). Feedback handlers can arrive out of order, so keep a done-set and advance through contiguous indices; reporting a non-contiguous maximum would reuse uniform slots and free resources still in flight. Call `engine.residency.release(through:)` from the handler, so resources retired after your last encode are released without waiting for the next one. A host that never has more than N submissions in flight (a semaphore) can use `MonitorSubmission(commandBuffer:index:framesInFlight:)` instead.
5. **Uniforms.** By default each object writes a small ring of `framesInFlight` slots (made on first use, rewritten only when its parameters change). To use your own transient memory, pass a `MonitorUniformAllocator` in `MonitorSubmission.uniforms`: 256-byte-aligned, resident, valid until the submission completes, sized from the constants (`MonitorPass.uniformLength` 5120 per picture, `MonitorFeed.uniformLength` 1024 per analysis, `ScopeAccumulator.uniformLength` 1280, `ScopeGroup.uniformLength` 2048, `ScopeRenderer.uniformLength` 768 plus `graticuleUniformLength` 2304 when the graticule changes). Never size them from struct sizes.
6. **Argument tables.** Each object owns one and binds it itself. When it draws or dispatches inside your encoder, rebind your own table afterwards. `prepareMetal4()` on scope objects makes theirs ahead of the first frame.
7. **Barriers.** The library encodes the barriers its own reads and writes need (focus mask, Freeze planes, scope bins, loads of shared targets), and skips them once the writer's submission is known complete. You order your own writes to frames and targets. A host that reads a persistent target MonitorKit writes (samples or blits a multiview texture) ends its reading encoder with a producer barrier, so the next frame's write does not overtake the read. Drawables are covered by `waitForDrawable`.
8. **Warm-up.** As on the classic path, plus `MonitorEngine(device:compiler:)` with your `MTL4Compiler` if your pipelines go through its lookup archives (asynchronous specialization uses it from compiler tasks; a compiler with a pipeline data set serializer crashes there on macOS 27, so give MonitorKit a plain one). For a warm start across launches, make both engines with a `cacheDirectory` instead (a subdirectory of your caches directory; the same one may serve both): they then build through their own `MonitorPipelineArchive` and a host `compiler` is unused. Warm them with `save: false` and save each archive once at the end (`engine.pipelineArchive?.save()`, `scopeEngine.pipelineArchive?.save()`), off the main thread; pipelines built later are saved by themselves a couple of seconds after the last one.

The minimal host is in the [README](../README.md#3-encode-tier-metal-4); [section 10](#10-worked-example-an-ultracam-style-monitor) is a complete one. The submission clock:

```swift
import Synchronization

/// Submission indices from 1, and the highest contiguous completed index.
final class SubmissionClock: Sendable {
  private let state: Mutex<(next: UInt64, completed: UInt64, done: Set<UInt64>)>

  init() {
    var done = Set<UInt64>()
    done.reserveCapacity(64)
    state = Mutex((next: 1, completed: 0, done: done))
  }

  /// The next index and what has completed so far.
  func reserve() -> (index: UInt64, completed: UInt64) {
    state.withLock { s in
      defer { s.next += 1 }
      return (s.next, s.completed)
    }
  }

  /// Records `index` as completed (in any order); returns the new watermark.
  func complete(_ index: UInt64) -> UInt64 {
    state.withLock { s in
      s.done.insert(index)
      while s.done.remove(s.completed + 1) != nil { s.completed += 1 }
      return s.completed
    }
  }

  var completed: UInt64 { state.withLock { $0.completed } }
}
```

**Compute into the drawable.** `pass.encodeCompute(…)` writes a shader-writable, non-sRGB target from a kernel (needs `framebufferOnly = false`). With `sharesTarget: true` (the default) it waits for earlier fragment and dispatch work, since another surface's render pass stores whole tiles; pass `false` when it is the only writer of a fresh drawable. Render passes (`encode`) work with `framebufferOnly` drawables, which allows framebuffer compression; prefer them.

## 5. HDR and layer colour

`MonitorPass.outputColor` says what the target's values mean; the layer must be tagged to match.

- **Signal-native** (`MonitorOutputColor.signalNative`, the default) writes the picture's own R'G'B'. Tag the layer with `pass.outputColor.layer(for: frame.signal, displayTransform: state.displayTransform.mode, monitorStageHasLUT: feed.monitorStageHasLUT(for: state))`: PQ and HLG signals get an `rgba16Float` EDR layer in their BT.2100 space with HDR10 or HLG metadata; SDR signals a `bgr10a2Unorm` layer in their primaries. `MonitorLayerColor.apply(to:)` (MonitorKitUI) sets pixel format, colour space, EDR and metadata. Re-tag only when the result changes: a new pixel format reallocates the drawables (and the layer's residency set).
- Any LUT on the picture's stage makes the picture Rec.709 SDR (LUT output is Rec.709 display R'G'B'); that is why `monitorStageHasLUT` is an argument.
- **Explicit encodings** (`.sdr`, `.extendedLinear`, `.pq`, `.hlg`) convert in linear light to the target, for a layer whose colour you fix. For `.extendedLinear` with `.hdrPassthrough`, keep `outputColor.headroom` at the screen's current EDR headroom (a uniform: changing it rebuilds nothing). `MonitorDisplayHeadroom.current(for:)` reads it.
- Overlays (zebras, guides, peaking, false-colour grey) land at BT.2408 graphics white on HDR layers (203 cd/m²: 58 % PQ, 75 % HLG), never at peak.
- A scope drawn into the same layer as an HDR picture needs `scopeRenderer.colorPipeline = pass.colorPipeline`, or it writes SDR values onto an HDR-tagged layer. A scope on a layer of its own uses `setOutputColor(_:signal:displayTransform:monitorStageHasLUT:)` or keeps the SDR default.

```swift
import MonitorKit
import MonitorKitUI
import QuartzCore

/// Re-tags `layer` when the picture's colour changes; returns the tag in effect.
@discardableResult
func tag(_ layer: CAMetalLayer, pass: MonitorPass, frame: MonitorFrame, feed: MonitorFeed, state: MonitorState,
         current: MonitorLayerColor?) -> MonitorLayerColor {
  let color = pass.outputColor.layer(
    for: frame.signal, displayTransform: state.displayTransform.mode, monitorStageHasLUT: feed.monitorStageHasLUT(for: state))
  if color != current {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    color.apply(to: layer)
    CATransaction.commit()
  }
  return color
}
```

## 6. Several surfaces

- **Several surfaces of one feed** share its `MonitorFeed`: one analysis per frame, each surface sampling the mask with its own footprint. `feed.analyze` encodes nothing when the mask already holds that frame with those settings, so calling it from each surface's submission is free after the first. One focus stage per feed per frame: two surfaces peaking on different stages need two feeds.
- **Several surfaces in one target** (a 2-up or 4-up workspace) go in one `MonitorMultiview` render pass: one clear and one store of the attachment instead of one per surface (four 4K feeds into a 4K target: 1.56 ms against 1.96 ms as eight passes). Each surface keeps its own `MonitorPass`. With `clear: false` on Metal 4, one barrier first waits for earlier work into the target.
- **One drawable per surface** is also fine: each its own `pass.encode`, in one or several submissions on the one queue.

## 7. Freeze

`feed.freeze(frame, into:)` copies the frame's planes into feed-owned textures with one compute pass (22.3 MB for 4K v210, made once per size and format) and returns a frame that works everywhere a live one does; the copy keeps its `id` while frozen, so it is analysed once. Draw `feed.frozenFrame` until the user unfreezes. The source buffer is free once the submission completes: a freeze never pins a capture buffer.

The state machine is yours. Freeze planes belong to the feed, so surfaces of one feed that freeze independently need a feed each. A pattern that matches the hardware monitors:

- `live` → (press) → `pending`: the next frame drawn is frozen (or, if you prefer, the next new frame to arrive); a second press cancels.
- `pending` → (draw) → `frozen`: `freeze` in that frame's submission; draw the returned frame from then on.
- `frozen` → (press) → `live`: `feed.unfreeze()` releases the planes (`keepingMemory: true` keeps them for a host that toggles often); keep drawing the frozen frame until the next live frame arrives, so there is no black flash.

On Metal 4 a re-freeze into the same planes needs no ordering from you (the library waits for earlier readers); on the classic path encode it after every command buffer that still reads the previous frozen frame.

## 8. Scopes and their cadence

Scopes are counted on the GPU from every pixel of a frame into bins sized to the scope, then resolved and drawn; nothing is read back.

1. `ScopeEngine(device:residency: engine.residency)`, then `prepare(pixelFormats:)` at start-up. An asynchronous engine draws nothing into a format until its pipeline is built (`isPrepared(pixelFormat:)`, `renderer.isReady`).
2. One `ScopeAccumulator` per scope, grouped per feed and stage in a `ScopeGroup`: a waveform, a vectorscope and a histogram of one stage are fused into one pass that decodes each pixel once.
3. **Cadence is the host's.** Accumulate at the scope rate you choose (10, 15 or 30 Hz is typical) and redraw from the last bins in between; the renderer resolves bins only when they change. Accumulate in the submission that draws the scope, or in an earlier one on the same queue.
4. **Never delay the picture.** Encode scopes in a separate submission committed after the picture's (MonitorKitUI's renderer does this with `encodePictures` then `encodeScopes`): the picture shows its frame at once, the scope one tick later.
5. Pass the surface's `state.monitorLUT` as `monitorLUTEnabled`, so a monitor-stage scope measures what that surface shows.
6. Statistics (clip %, luma extremes) are read from any thread through `accumulator.statisticsReader`; for a readout without a drawn scope, accumulate a hidden one (a histogram is cheapest) with the picture's clip levels.

## 9. Audio meters

`AudioMeter` runs on your audio thread: `process(…)` from one thread at a time (a tap, an `AVAudioSinkNode`, a capture callback). It allocates nothing, takes no lock and never blocks. The UI reads `snapshot()` at display rate from any thread (lock-free); resets and loudness pause are requests from any thread that take effect at the next 5 or 10 ms tick of audio. Call `flush()` on the audio thread when a stream stops, so its last few milliseconds (and any over in them) reach the snapshot. Show `programmeMaximumTruePeak` as R 128's "Max TP". Rebuild the meter when the sample rate or channel count changes.

## 10. Worked example: an Ultracam-style monitor

Ultracam shows several cameras and its Program output in tiles, detached windows and a menu-bar preview, every picture a `CAMetalLayer` driven by a `CAMetalDisplayLink` on one render thread, all GPU work on one `MTL4CommandQueue`. Its output encoder (a compute kernel that decodes, applies the burned-in LUT and encodes the virtual camera's frame) is the fused tier: it prepends `MKLUT.msl` and calls `mk_applyLUT` with the same `MonitorLUT` the monitor shows. The monitor then needs:

- a GPU context: the device, the queue, the engines, the texture cache, a pool of encode contexts (command allocator, bump uniforms, frames to keep alive) and the submission clock;
- a feed host per camera and one for Program: the feed, the declared signal, the LUTs and the latest frame;
- a tile per picture: the pass, the layer's colour, the freeze state machine; and a scope tile at 15 Hz.

All of it lives on the render thread except the context's pools and clock, which are thread-safe because feedback handlers run elsewhere.

```swift
import CoreVideo
import Foundation
import Metal
import MonitorKit
import MonitorKitScopes
import MonitorKitUI
import QuartzCore

/// Transient uniforms of one submission: a bump allocator over one shared buffer.
final class ContextUniforms: MonitorUniformAllocator {
  let buffer: MTLBuffer
  private var offset = 0

  init(device: MTLDevice, length: Int) throws {
    guard let buffer = device.makeBuffer(length: length, options: [.storageModeShared, .cpuCacheModeWriteCombined])
    else { throw MonitorKitError.gpu("Cannot allocate \(length) bytes of uniforms.") }
    self.buffer = buffer
  }

  func reset() { offset = 0 }

  func allocateUniforms(length: Int) -> MonitorUniformAllocation {
    precondition(offset + length <= buffer.length, "uniform budget exceeded")
    let a = MonitorUniformAllocation(contents: buffer.contents() + offset, gpuAddress: buffer.gpuAddress + UInt64(offset))
    offset += (length + 255) / 256 * 256
    return a
  }
}

/// One reusable submission. Taken by the render thread, returned by the feedback handler.
final class EncodeContext: @unchecked Sendable {
  let allocator: any MTL4CommandAllocator
  let uniforms: ContextUniforms
  /// What this submission's GPU work reads: kept alive until it completes.
  var frames: [MonitorFrame] = []

  init(device: MTLDevice) throws {
    guard let allocator = device.makeCommandAllocator() else { throw MonitorKitError.gpu("No command allocator.") }
    self.allocator = allocator
    // Five pictures and their analyses (6 KB each), or a scope tick of three scopes.
    uniforms = try ContextUniforms(device: device, length: 32 * 1024)
    frames.reserveCapacity(4)
  }
}

/// The app's GPU context: one device, one queue, the engines and the pools.
final class MonitorGPUContext: @unchecked Sendable {
  let device: MTLDevice
  let queue: any MTL4CommandQueue
  let engine: MonitorEngine
  let scopeEngine: ScopeEngine
  let frames: MonitorTextureCache
  let clock = SubmissionClock()
  private let hostResidency: any MTLResidencySet
  private let lock = NSLock()
  private var free: [EncodeContext] = []

  init(device: MTLDevice) throws {
    guard device.supportsFamily(.metal4), let queue = device.makeMTL4CommandQueue() else {
      throw MonitorKitError.gpu("This monitor needs a Metal 4 device.")
    }
    self.device = device
    self.queue = queue
    // Pipelines compiled once load from the caches directory at the next launch.
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let pipelines = caches.appendingPathComponent("MonitorKit pipelines", isDirectory: true)
    engine = try MonitorEngine(device: device, cacheDirectory: pipelines)
    scopeEngine = try ScopeEngine(device: device, residency: engine.residency, cacheDirectory: pipelines)
    frames = MonitorTextureCache(device: device, residency: engine.residency)
    let d = MTLResidencySetDescriptor()
    d.label = "Monitor host"
    hostResidency = try device.makeResidencySet(descriptor: d)
    queue.addResidencySet(engine.residency.set)
    queue.addResidencySet(hostResidency)
  }

  /// At start-up, off the main thread. Each archive is saved once, after both
  /// engines are warm (a no-op when nothing new was compiled).
  func warmUp() throws {
    defer {
      engine.pipelineArchive?.save()
      scopeEngine.pipelineArchive?.save()
    }
    try engine.warmUp(save: false)
    try scopeEngine.prepare(save: false)
  }

  /// A layer's drawables; call again after a re-tag that changed its pixel format.
  func attach(_ set: any MTLResidencySet) { queue.addResidencySet(set) }
  func detach(_ set: any MTLResidencySet) { queue.removeResidencySet(set) }

  private func take() throws -> EncodeContext {
    if let context = lock.withLock({ free.popLast() }) { return context }
    let context = try EncodeContext(device: device)
    hostResidency.addAllocation(context.uniforms.buffer)
    hostResidency.commit()  // only when the pool grows, never per frame
    return context
  }

  /// Encodes one submission and commits it, presenting `drawable` if given.
  func submit(drawable: (any CAMetalDrawable)?, keeping frame: MonitorFrame?, _ body: (MonitorSubmission) throws -> Void)
    throws
  {
    let context = try take()
    context.uniforms.reset()
    if let frame { context.frames.append(frame) }
    let commandBuffer = device.makeCommandBuffer()!
    commandBuffer.beginCommandBuffer(allocator: context.allocator)
    let (index, completed) = clock.reserve()
    var failure: (any Error)?
    do {
      try body(
        MonitorSubmission(commandBuffer: commandBuffer, index: index, completedIndex: completed,
                          uniforms: context.uniforms))
    } catch {
      failure = error  // still committed below: every index must complete
    }
    commandBuffer.endCommandBuffer()
    let options = MTL4CommitOptions()
    options.addFeedbackHandler { [self] _ in
      engine.residency.release(through: clock.complete(index))
      context.frames.removeAll(keepingCapacity: true)
      context.allocator.reset()
      lock.withLock { free.append(context) }
    }
    if let drawable { queue.waitForDrawable(drawable) }
    queue.commit([commandBuffer], options: options)
    if let drawable {
      queue.signalDrawable(drawable)
      drawable.present()
    }
    if let failure { throw failure }
  }
}

/// One camera, or Program: its feed, declared signal and latest frame (render thread).
final class MonitorFeedHost {
  let feed: MonitorFeed
  /// The camera's log profile, which attachments cannot tell (nil: read the attachments).
  var declaredLog: LogEncoding?
  /// Program is a mix, not a camera's signal: no log false colour, no peaking.
  let isProgramme: Bool
  private(set) var latest: MonitorFrame?
  /// The focus settings of the first tile showing peaking this frame (peaking off
  /// until one does). Tiles of one feed share this one analysis stage.
  var focus = FocusSettings()
  /// Whether a tile showed peaking on the previous frame: until a frame passes with
  /// none, a tile without peaking must not release the mask the others use.
  private var peakingClaimed = false

  init(engine: MonitorEngine, isProgramme: Bool = false) {
    feed = engine.makeFeed()
    self.isProgramme = isProgramme
  }

  /// A new frame from the delivery queue, handed to the render thread.
  func accept(_ pixelBuffer: CVPixelBuffer, owner: UInt64, gpu: MonitorGPUContext) throws {
    let range = MonitorFrame.layout(for: CVPixelBufferGetPixelFormatType(pixelBuffer))?.range ?? .legal
    var signal = MonitorFrame.signal(of: pixelBuffer, range: range)
    if let declaredLog { signal.encoding = .log(declaredLog) }
    var frame = try gpu.frames.frame(pixelBuffer, signal: signal, owner: owner)
    frame.isProcessed = isProgramme
    latest = frame
    peakingClaimed = focus.enabled
    focus = FocusSettings()  // the tiles drawing this frame claim it again
  }

  /// Once per frame; free for the second surface (the mask already holds the frame).
  /// With peaking off on every tile for a whole frame, the call releases the mask.
  func analyze(_ frame: MonitorFrame, into submission: MonitorSubmission) throws {
    guard focus.enabled || !peakingClaimed else { return }
    try feed.analyze(frame, focus: focus, into: submission)
  }
}

/// One picture tile: its tools, its layer's colour and its freeze state (render thread).
final class MonitorTile {
  enum FreezeState { case live, pending, frozen }

  let pass: MonitorPass
  let layer: CAMetalLayer
  var state = MonitorState()
  private(set) var freeze = FreezeState.live
  /// The frame this tile froze. Freeze planes belong to the feed: tiles of one feed
  /// that freeze independently need a feed each.
  private(set) var frozen: MonitorFrame?
  private var tagged: MonitorLayerColor?
  private var attachedSet: (any MTLResidencySet)?

  init(engine: MonitorEngine, layer: CAMetalLayer) {
    pass = engine.makePass()
    self.layer = layer
    layer.framebufferOnly = true  // render passes only: framebuffer compression stays on
  }

  /// The freeze button: live → pending (freeze the next frame), pending → live (cancel), frozen → live.
  func toggleFreeze(feed: MonitorFeed) {
    switch freeze {
    case .live: freeze = .pending
    case .pending: freeze = .live
    case .frozen:
      feed.unfreeze()
      frozen = nil
      freeze = .live
    }
  }

  /// One display tick.
  func draw(drawable: any CAMetalDrawable, host: MonitorFeedHost, gpu: MonitorGPUContext) throws {
    guard let live = host.latest else { return }
    retag(for: live, feed: host.feed, gpu: gpu)
    try gpu.submit(drawable: drawable, keeping: live) { submission in
      var frame = frozen ?? live
      if freeze == .pending {
        frame = try host.feed.freeze(live, into: submission)
        frozen = frame
        freeze = .frozen
      }
      // The first tile with peaking on picks the feed's analysis; the others reuse it.
      if state.focus.enabled, !host.focus.enabled { host.focus = state.focus }
      try host.analyze(frame, into: submission)
      try pass.encode(frame: frame, feed: host.feed, state: state, target: drawable.texture, into: submission)
    }
  }

  private func retag(for frame: MonitorFrame, feed: MonitorFeed, gpu: MonitorGPUContext) {
    let color = pass.outputColor.layer(
      for: frame.signal, displayTransform: state.displayTransform.mode,
      monitorStageHasLUT: feed.monitorStageHasLUT(for: state))
    if color != tagged {
      tagged = color
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      color.apply(to: layer)
      CATransaction.commit()
    }
    // A new pixel format gives the layer a new residency set for its drawables.
    if attachedSet !== layer.residencySet {
      if let old = attachedSet { gpu.detach(old) }
      gpu.attach(layer.residencySet)
      attachedSet = layer.residencySet
    }
  }
}

/// A waveform, vectorscope and histogram of one tile's feed, at 15 Hz on a layer of their own.
final class ScopeTile {
  let group: ScopeGroup
  let scopes: [ScopeAccumulator]
  let renderers: [ScopeRenderer]
  var interval = 1.0 / 15
  private var lastAccumulation = -Double.infinity

  init(engine: ScopeEngine, stage: SignalStage = .output) throws {
    scopes = try [ScopeKind.waveform, .vectorscope, .histogram].map {
      try engine.makeAccumulator(settings: ScopeSettings(kind: $0, stage: stage))
    }
    group = try engine.makeGroup(scopes)
    renderers = scopes.map { _ in engine.makeRenderer() }
    try group.prepareMetal4()
  }

  /// Its own submission, after the picture's: the picture never waits for the scopes.
  func draw(drawable: any CAMetalDrawable, host: MonitorFeedHost, tile: MonitorTile, gpu: MonitorGPUContext,
            now: Double) throws {
    guard let frame = tile.frozen ?? host.latest else { return }
    let due = now - lastAccumulation >= interval
    if due { lastAccumulation = now }
    let width = drawable.texture.width / 3, height = drawable.texture.height
    try gpu.submit(drawable: drawable, keeping: frame) { submission in
      if due { try group.accumulate(frame, feed: host.feed, monitorLUTEnabled: tile.state.monitorLUT, into: submission) }
      var i = 0
      while i < scopes.count {
        try renderers[i].render(
          scopes[i], target: drawable.texture, viewport: MonitorViewport(x: i * width, y: 0, width: width, height: height),
          clear: i == 0, into: submission)
        i += 1
      }
    }
  }
}
```

How the app's pieces map onto it:

| Ultracam | This example |
| --- | --- |
| The render thread and its display links | Calls `MonitorTile.draw` and `ScopeTile.draw` per tick (one link per layer; the scope link at 10/15/30 Hz) |
| The delivery queue's frame offer | `MonitorFeedHost.accept` (hop to the render thread with the pixel buffer); stopping a camera calls `gpu.frames.flush(owner:)` |
| LUT load | One `MonitorLUT` per file, built once with the shared device, given to the output encoder and to `feed.burnInLUT` |
| Program output | A feed host with `isProgramme: true` |
| Source / Output picture menu | `state.pictureStage` (`.source`, or `.output` for "Output (LUT)") |
| Status strings | `pass.status` (`activeLabels`, `unavailable` reasons, `isCodeValueView`) |
| Diagnostics | `pass.rebuildCount`, `engine.resourcesCreated`, `engine.residency.commitCount`, the feedback handler's GPU times |

## 11. Pitfalls

**Metal 4**

- Submission indices start at 1; every index handed out must be committed, or the watermark stops and nothing retired is ever released.
- Report the highest *contiguous* completed index, never the highest seen.
- One queue for all of an engine's work. A second queue (say, for a detached window) needs its own engines.
- Attach `engine.residency.set` once, not per frame; re-attach a layer's `residencySet` when its pixel format changes.
- Host frames must be resident: use `MonitorTextureCache` (or `addResidency(to:)` when you first make a texture). A frame that is not resident reads garbage, not an error. Run with `MTL_DEBUG_LAYER=1` while integrating.
- Host uniform allocators: 256-byte aligned, resident, valid until completion, sized from the `uniformLength` constants.
- After a library draw or dispatch in your encoder, rebind your own argument table.
- `encodeCompute` needs `framebufferOnly = false` and a non-sRGB, shader-writable target; render passes work with `framebufferOnly` drawables.

**Colour**

- Any LUT on the picture's stage makes it Rec.709 SDR and every display transform unavailable (`.lutOnMonitorStage`). To see a display transform while a LUT is burned in, show `pictureStage = .source`.
- Re-tag the layer when `outputColor.layer(…)` changes, and pass `feed.monitorStageHasLUT(for: state)`, which follows `pictureStage`.
- On a layer shared with an HDR picture, set `scopeRenderer.colorPipeline = pass.colorPipeline`.
- Never relabel a frame with one stage's reading for a pass (say, the Output reading for an Output-stage picture): the other stages' tools on that pass would read the codes with it. Set `signal.outputReading` once and hand every pass the same frame.
- Declare log encodings; they are never inferred. An unlabelled or log signal shown without a LUT or transform is a code-value view (`status.isCodeValueView`): its brightness is not exposure.

**LUTs and fused kernels**

- Never keep an older copy of `MKLUT.msl` in your own source: prepend `MonitorShaders.source([.lut])` and bind `LUTParameters` (80 bytes). An old 48-byte copy fails to compile instead of binding the wrong layout.
- Compile fused kernels with `MonitorShaders.compileOptions` (safe math), or output and preview differ by a few ULPs.
- `MonitorLUT` is per device: build it with the device your output encoder and the monitor share.

**Analysis and state**

- Call `feed.analyze` with the focus settings of the surfaces that show peaking. Passing `enabled = false` from a surface without peaking releases the mask the others need.
- `MonitorLayout`'s maps return frame pixels: with a clean aperture, convert a hit point to a magnification centre with `layout.pictureFraction(displayX:displayY:)`, not by dividing by `pictureWidth`.
- Build a new `MonitorFrame` per picture (fresh `id`): a reused value with a reused `id` keeps the old focus mask.
- Freeze planes are per feed: a second `freeze` on the same feed overwrites the first frozen frame's planes.
- `MonitorState` JSON is fail-closed: decoding throws for anything that is not MonitorKit's schema 2 (`kind` + `schemaVersion`). Catch it and fall back. Inside your own `Codable` settings declare the field `@LenientMonitorState`, or one foreign blob fails the whole outer value.
- `clean` and `geometry.magnification` are per-session in most apps: strip them before persisting if you do not want a monitor to reopen magnified.

**Lifetimes**

- Keep frames alive until the GPU work that reads them completes; MonitorKit retains nothing on Metal 4.
- Classic hosts with unretained command buffers keep LUTs and the library's objects alive too, and call `feed.releaseRetired()` for an idle feed once its work completed.

**Audio**

- `process` and `flush` from one thread only; `snapshot()` from anywhere.
- `flush()` when a stream stops, or its last overs never show.

## 12. Migration notes

**From MonitorKit W1/W2 (before 0.1.0)**

- `MonitorState` now writes `"kind": "MonitorKit.MonitorState"` and `schemaVersion` 2, and decoding throws for JSON without that `kind` or with a lower schema, including MonitorKit's own earlier JSON. Re-save after decoding with your fallback; `@LenientMonitorState` keeps an embedding type decodable.
- New enum cases: `MonitorTool.picture`, `MonitorUnavailableReason.requiresCameraSignal` and `.unsupportedGeometry`. Exhaustive switches over them need new arms.
- `MonitorFeed.monitorStageHasLUT(for:)` follows `pictureStage`: it is false for `.source` even with a burn-in LUT.
- `MonitorLayout.pictureWidth` / `pictureHeight` are the clean aperture's size (unchanged without an aperture). A pixel aspect ratio outside 1/16…16 is now shown square with `.unsupportedGeometry`; it used to be honoured.
- `MonitorStatus.activeLabels` gains a `.picture` entry for log or unlabelled pictures ("S-Log3 code values") and for non-default picture stages.
- `wrap` and `MonitorTextureCache.frame` now read the clean aperture attachment: pictures with an aperture are cropped to it.

**From a hand-written monitor (Ultracam's MonitorTools)**

| Before | MonitorKit |
| --- | --- |
| A master tools switch | None: each tool has its own `enabled`; turn them off individually |
| Zebra threshold and a full band width | `ZebraSet.level` and `range` = width / 2 (`.band`), or `.lowerLimit` |
| One zebra, measuring the picture | Two sets, each with a `stage` (`.source` for a source picture, `.output` otherwise) |
| False colour suppresses zebra | MonitorKit draws both; keep the rule in your glue if wanted |
| Safe area on/off (5 % inset) | `guides.safeAreas = [90]` |
| Picture stage "Output (as published)" | `.output` is the source with the burn-in LUT computed in the shader, at source resolution, not the published processed buffer; to show published pixels, wrap that buffer as its own frame with `isProcessed` |
| Trilinear LUTs | `MonitorLUT` defaults to tetrahedral; `.trilinear` is bit-compatible with the old shader |
| Overlay white at code 1.0 on HDR layers | BT.2408 graphics white (58 % PQ, 75 % HLG) |
| Old scope look (768 × 256, −10…110 IRE) | `ScopeSettings.ultracamLegacy(mode:stage:)` |
| Clean aperture computed as `(H − h)/2 − verticalOffset` | Mirrored: the offset points down. Use `MonitorFrame.cleanAperture(of:)` |
| Old settings JSON | Decode it with your own legacy type; never as `MonitorState` |
