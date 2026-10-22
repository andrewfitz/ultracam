# MonitorKit

Professional video monitoring for Apple platforms, on the GPU, at zero overhead.

MonitorKit is a Swift and Metal package that brings the monitoring assists of a camera monitor (zebras, false colour, focus peaking, frame guides, magnify, display LUTs, HDR viewing, waveform, vectorscope, histogram and broadcast audio meters) to any macOS or iOS app that shows video. Its feature set is the union of a Sony FX3's and a Blackmagic Video Assist 12G HDR's, and every constant traces to a published standard or manufacturer document.

It is built to cost nothing compared with code written directly into the host: it borrows the host's textures and command buffers, never copies a frame, never creates a queue or a thread, never commits or waits, allocates nothing per frame, and reads nothing back from the GPU. It encodes into classic `MTLCommandBuffer`s and into Metal 4 `MTL4CommandBuffer`s with bit-identical pixels.

- [Features](Docs/FEATURES.md): every tool, its parameters and defaults, and the device feature it follows
- [API](Docs/API.md): every public type, by module, with threading and lifetime rules
- [Integration guide](Docs/INTEGRATION.md): step by step, classic and Metal 4, with a worked example
- [Architecture](Docs/ARCHITECTURE.md): the zero-overhead contract, barriers, lifetimes, data flow
- [Math](Docs/MATH.md): every constant and formula with its source and the test that checks it
- [Changelog](CHANGELOG.md)

## Features

| Area | MonitorKit | Sony FX3 | Video Assist 12G HDR |
| --- | --- | --- | --- |
| Zebras | Two sets at once, each band (level ± range) or lower limit (level and above), any level −20…120 IRE, per-set signal stage | Two (Custom1 band, Custom2 lower limit) | One, above a threshold |
| False colour | Sony S-Log3 (Monitor & Control Pattern 2), ARRI LogC3/LogC4 tables, ARRI-style on S-Log3, EL Zone (provisional), six-band display IRE, custom bands in IRE or stops | none | Fixed six-band |
| Clip indicators | Per channel R, G, B and luma, over and under, with exact clip % readouts | none | none |
| Focus | Peaking in five colours, coloured edges or traditional peak, continuous sensitivity, noise rejection, at source resolution | Peaking, three levels, four colours | Focus assist, edges or peak |
| Magnify | 1:1 pixel-exact, 1–64× zoom, pan, navigator inset, sharp sampling, tools stay correct | Focus Magnifier | 2× and pinch zoom with inset |
| Framing | 16 aspect guides plus custom (lines or matte), safe areas, thirds, square grid, diagonals, centre cross and dot, freely combined, drawn analytically | Aspect markers, safety zone, grids, centre marker | Frame guides, thirds, crosshair, centre dot |
| Geometry | Anamorphic de-squeeze 1…4 (1.3, 1.33, 1.5, 1.65, 1.66, 1.8, 2), flip H/V/180°, clean aperture, pixel aspect ratio | De-squeeze, flip | De-squeeze, 180° |
| LUTs | `.cube` 2³–65³ with 1D shaper, tetrahedral, trilinear or hardware; monitor-only and burn-in routing, stackable | Display LUT, baked PPLUT | Display 3D LUT |
| Display transforms | Log to Rec.709 (S-Log3, LogC3, LogC4), PQ and HLG to SDR (BT.2408 EETF), HDR passthrough with roll-off to the EDR headroom | Gamma Display Assist | HDR monitoring |
| Picture | Brightness, contrast, saturation, white-point trim (temperature, tint), luma mono, blue only; picture stage (source, output, monitor) | Monitor brightness | Brightness, contrast, saturation, LCD calibration, Blue Only |
| Output colour | Signal-native, SDR (BT.1886, sRGB, 2.2), extended linear, PQ, HLG on Rec.709, P3 or Rec.2020; EDR layer tagging; overlays at BT.2408 graphics white | | HDR override |
| Scopes | Waveform (luma, RGB overlay, RGB parade, Y'CbCr parade), vectorscope (1/2/4×, 75/100 % targets for BT.601/709/2020, skin-tone line), histogram (luma, RGB overlay, parade, linear or log), IRE, code-value and HDR nit graticules, several at once, every pixel | Luma histogram | Waveform, parade, vectorscope, RGB histogram, one at a time |
| Audio | 1–16 channels: sample peak, BS.1770 true peak, RMS, VU, PPM Type I / IIa / IIb, EBU R 128 loudness (M, S, I, LRA, Max TP) | Level meter | VU and PPM at −18 / −20 dBFS |
| Status | Clean feed, timecode, tally border, format, LUT name and labels as SwiftUI overlays; Freeze; multiview | | Clean feed |

The full parameter reference is [FEATURES.md](Docs/FEATURES.md).

## Requirements

- macOS 26 or iOS 26 and later, on Apple silicon. The Metal 4 encode path needs a device that supports `MTLGPUFamily.metal4`; the classic path and the view tier do not.
- Swift 6 (tools 6.2). The package builds with warnings as errors.
- No Metal toolchain: the shaders ship as `.msl` text and compile at runtime with the OS compiler.
- No third-party dependencies.

## Installation

Swift Package Manager:

```text
dependencies: [
  .package(url: "https://github.com/OWNER/MonitorKit.git", from: "0.1.0"),
],
targets: [
  .target(name: "MyApp", dependencies: [
    .product(name: "MonitorKit", package: "MonitorKit"),
    .product(name: "MonitorKitScopes", package: "MonitorKit"),
    .product(name: "MonitorKitAudio", package: "MonitorKit"),
    .product(name: "MonitorKitUI", package: "MonitorKit"),
  ]),
]
```

Until the first tagged release, depend on a local checkout with `.package(path: "../MonitorKit")`.

| Product | Contents | Depends on |
| --- | --- | --- |
| `MonitorKitCore` | Settings (`MonitorState`), signal descriptions, geometry, `.cube` parsing, output colour, and the CPU reference math the GPU is tested against. Pure Swift | — |
| `MonitorKit` | The picture pass, focus analysis, LUTs, Freeze, multiview, the Metal 4 types (re-exports `MonitorKitCore`) | Core |
| `MonitorKitScopes` | Waveform, vectorscope, histogram and their statistics on the GPU | MonitorKit |
| `MonitorKitAudio` | Level meters and loudness. Pure Swift and Accelerate | — |
| `MonitorKitUI` | `MonitorMetalView`, `MonitorRenderer`, SwiftUI views, controls, legends, meters | all |

## Quick start

MonitorKit has four integration tiers. Pick the one that matches how much of the pipeline your app owns.

| Tier | You do | MonitorKit does |
| --- | --- | --- |
| **View** (MonitorKitUI) | Put a `MonitorView` in your SwiftUI hierarchy and hand it frames | Everything: layer, display link, colour tagging, gestures, scopes |
| **Encode, classic** | Own an `MTLCommandQueue` and the drawable | Encodes into your `MTLCommandBuffer` |
| **Encode, Metal 4** | Own an `MTL4CommandQueue`, the residency sets and the completion watermark | Encodes into your `MTL4CommandBuffer` with its own argument tables, uniforms and barriers |
| **Fused** | Own a compute kernel (e.g. your output encoder) | Ships `MKLUT.msl` and `MKDecode.msl` to prepend, so a burned-in LUT costs no extra pass |

### 1. A monitor view (MonitorKitUI)

```swift
import CoreVideo
import Metal
import MonitorKit
import MonitorKitUI
import SwiftUI

struct CameraMonitorView: View {
  let engine: MonitorEngine  // one per GPU: try MonitorEngine(device: MTLCreateSystemDefaultDevice()!)
  let source: MonitorSource  // one per camera
  @State private var state = MonitorState()

  var body: some View {
    MonitorView(engine: engine, source: source, state: $state)
      .overlay(alignment: .top) {
        MonitorTileToolbar(state: $state, name: "Camera 1", placement: .overPicture)
      }
  }
}

/// On the capture thread, for every frame: no copy, no wait.
func deliver(_ pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache, to source: MonitorSource) throws {
  var signal = MonitorFrame.signal(of: pixelBuffer, range: .legal)
  signal.encoding = .log(.sLog3SGamut3Cine)  // a log profile is declared, never guessed
  source.submit(try MonitorFrame.wrap(pixelBuffer, cache: cache, signal: signal))
}
```

`MonitorView` draws on a `CAMetalDisplayLink`, tags its layer for SDR or EDR from the signal, follows the screen's EDR headroom, and turns pinch, scroll, drag and double click into magnification. `ScopeView` and `ScopeStackView` add scopes of the same source; `AudioMeterView` draws an `AudioMeter`.

### 2. Encode tier, classic Metal

```swift
import Metal
import MonitorKit
import QuartzCore

final class ClassicMonitor {
  let engine: MonitorEngine
  let feed: MonitorFeed  // one per video feed: its LUTs and its focus analysis
  let pass: MonitorPass  // one per surface: its tools and output colour
  var state = MonitorState()

  init(device: MTLDevice) throws {
    engine = try MonitorEngine(device: device)
    try engine.warmUp()  // off the frame path: no first frame waits for a compile
    feed = engine.makeFeed()
    pass = engine.makePass()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 95)
    state.focus.enabled = true
    state.guides.enabled = true
  }

  /// Once per display tick, on the render thread.
  func draw(_ frame: MonitorFrame, into drawable: any CAMetalDrawable, queue: MTLCommandQueue) throws {
    guard let commandBuffer = queue.makeCommandBuffer() else { return }
    try feed.analyze(frame, focus: state.focus, into: commandBuffer)  // once per frame, for every surface
    try pass.encode(frame: frame, feed: feed, state: state, target: drawable.texture, into: commandBuffer)
    commandBuffer.addCompletedHandler { _ in _ = frame }  // the host keeps its frame until the GPU is done
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
```

### 3. Encode tier, Metal 4

MonitorKit never begins, ends or commits a Metal 4 command buffer. The host numbers its submissions from 1 and reports the highest *contiguous* completed index; the library uses it to reuse uniform slots and to release replaced resources only once the GPU is done with them.

```swift
import CoreVideo
import Foundation
import Metal
import MonitorKit
import QuartzCore
import Synchronization

/// Command allocators, reused once their command buffer has completed.
final class AllocatorPool: @unchecked Sendable {
  private let lock = NSLock()
  private var free: [any MTL4CommandAllocator] = []

  func take(_ device: MTLDevice) -> any MTL4CommandAllocator {
    lock.withLock { free.popLast() } ?? device.makeCommandAllocator()!
  }

  func recycle(_ allocator: any MTL4CommandAllocator) {
    allocator.reset()
    lock.withLock { free.append(allocator) }
  }
}

final class Metal4Host: @unchecked Sendable {
  let device: MTLDevice
  let queue: any MTL4CommandQueue  // one queue for all of an engine's work
  let engine: MonitorEngine
  let frames: MonitorTextureCache  // IOSurface-keyed textures, made and made resident once
  private let clock = Mutex<(next: UInt64, completed: UInt64, done: Set<UInt64>)>((1, 0, []))
  private let allocators = AllocatorPool()

  init(device: MTLDevice, layer: CAMetalLayer) throws {
    guard let queue = device.makeMTL4CommandQueue() else { throw MonitorKitError.gpu("No Metal 4 queue.") }
    self.device = device
    self.queue = queue
    engine = try MonitorEngine(device: device)
    frames = MonitorTextureCache(device: device, residency: engine.residency)
    queue.addResidencySet(engine.residency.set)  // once: MonitorKit's resources and the cached frames
    queue.addResidencySet(layer.residencySet)  // the drawables
    try engine.warmUp()
  }

  /// One command buffer: `body` encodes into it, then it is committed with `drawable`.
  /// Every index handed out is committed, so the completion watermark never stalls.
  func submit(drawable: any CAMetalDrawable, keeping frame: MonitorFrame, _ body: (MonitorSubmission) throws -> Void)
    throws
  {
    let allocator = allocators.take(device)
    let commandBuffer = device.makeCommandBuffer()!
    commandBuffer.beginCommandBuffer(allocator: allocator)
    let (index, completed) = clock.withLock { s in
      defer { s.next += 1 }
      return (s.next, s.completed)
    }
    var failure: (any Error)?
    do {
      try body(MonitorSubmission(commandBuffer: commandBuffer, index: index, completedIndex: completed))
    } catch {
      failure = error
    }
    commandBuffer.endCommandBuffer()
    let options = MTL4CommitOptions()
    nonisolated(unsafe) let finished = allocator
    options.addFeedbackHandler { [self] _ in
      // Feedback can arrive out of order: advance only through contiguous indices.
      let watermark = clock.withLock { s in
        s.done.insert(index)
        while s.done.remove(s.completed + 1) != nil { s.completed += 1 }
        return s.completed
      }
      engine.residency.release(through: watermark)
      _ = frame  // the frame (and its pixel buffer) lives until its work completed
      allocators.recycle(finished)
    }
    queue.waitForDrawable(drawable)
    queue.commit([commandBuffer], options: options)
    queue.signalDrawable(drawable)
    drawable.present()
    if let failure { throw failure }
  }
}

final class Metal4Monitor {
  let host: Metal4Host
  let feed: MonitorFeed
  let pass: MonitorPass
  var state = MonitorState()

  init(host: Metal4Host) {
    self.host = host
    feed = host.engine.makeFeed()
    pass = host.engine.makePass()
  }

  /// Once per display tick, on the render thread.
  func draw(_ pixelBuffer: CVPixelBuffer, into drawable: any CAMetalDrawable) throws {
    let frame = try host.frames.frame(pixelBuffer)
    try host.submit(drawable: drawable, keeping: frame) { submission in
      try feed.analyze(frame, focus: state.focus, into: submission)
      try pass.encode(frame: frame, feed: feed, state: state, target: drawable.texture, into: submission)
    }
  }
}
```

### 4. Fused tier: a burned-in LUT in your own kernel

Prepend MonitorKit's LUT and decode sources to your kernel and call `mk_decodeRGB` and `mk_applyLUT`. Compiled with `MonitorShaders.compileOptions`, the output carries exactly the values the monitor's output stage shows.

```metal
kernel void host_burnIn(texture2d<uint, access::read> packed [[texture(0)]],
                        texture2d<float, access::read> luma [[texture(1)]],
                        texture2d<float, access::read> chroma [[texture(2)]],
                        texture3d<float, access::sample> lut [[texture(3)]],
                        texture2d<float, access::write> output [[texture(4)]],
                        constant mk_FrameParams& frame [[buffer(0)]],
                        constant mk_LUTParams& lutParams [[buffer(1)]],
                        uint2 xy [[thread_position_in_grid]]) {
  if (xy.x >= frame.shape.y || xy.y >= frame.shape.z) return;
  float3 rgb = mk_decodeRGB(packed, luma, chroma, xy, frame);
  output.write(float4(saturate(mk_applyLUT(rgb, lut, lutParams)), 1), xy);
}
```

```swift
import Metal
import MonitorKit

/// `kernelSource` is the kernel above. `MonitorShaders.libraryDescriptor(parts:extra:)`
/// gives the same unit to an `MTL4Compiler`.
func makeBurnInPipeline(device: MTLDevice, kernelSource: String) throws -> MTLComputePipelineState {
  let library = try MonitorShaders.makeLibrary(device: device, parts: [.lut, .decode], extra: kernelSource)
  guard let function = library.makeFunction(name: "host_burnIn") else { throw MonitorKitError.gpu("host_burnIn") }
  return try device.makeComputePipelineState(function: function)
}

/// `unusedPacked` (rgba32Uint) and `unusedPlane` (any float format) stand in for planes the layout lacks.
func encodeBurnIn(
  _ frame: MonitorFrame, lut: MonitorLUT, output: MTLTexture, pipeline: MTLComputePipelineState,
  unusedPacked: MTLTexture, unusedPlane: MTLTexture, into commandBuffer: MTLCommandBuffer
) {
  guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
  encoder.setComputePipelineState(pipeline)
  encoder.setTexture(frame.packed ?? unusedPacked, index: 0)
  encoder.setTexture(frame.luma ?? unusedPlane, index: 1)
  encoder.setTexture(frame.chroma ?? unusedPlane, index: 2)
  encoder.setTexture(lut.texture, index: 3)
  encoder.setTexture(output, index: 4)
  var frameParameters = frame.parameters
  encoder.setBytes(&frameParameters, length: MemoryLayout<FrameParameters>.stride, index: 0)
  var lutParameters = lut.parameters
  encoder.setBytes(&lutParameters, length: MemoryLayout<LUTParameters>.size, index: 1)
  encoder.dispatchThreads(
    MTLSize(width: frame.width, height: frame.height, depth: 1),
    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
  encoder.endEncoding()
}
```

Give the same `MonitorLUT` to the monitor as `feed.burnInLUT`, so every preview shows the output's look. Never keep a copy of an older `MKLUT.msl` in your sources: the 80-byte layout is versioned (`MonitorShaders.lutLayoutVersion`), and a stale copy fails to compile rather than binding the wrong struct.

## Performance

GPU timestamps on an Apple M4 Max, the minimum of N interleaved runs on a GPU shared with other work, from the package's benchmark tests, which enforce the budgets (W2, 2026-10-22).

| Work | Measured | Budget |
| --- | --- | --- |
| Picture pass, 4K v210 source, every tool on, into 1080p | 0.29 ms | ≤ 0.35 ms |
| … into 1600 × 900 | 0.33 ms | ≤ 0.40 ms |
| … into 720p / 540p | 0.22 / 0.14 ms | ≤ 0.5 ms |
| … into 2560 × 1440 / 4K 1:1 | 0.56 / 0.70 ms | not budgeted |
| Every output encoding (PQ and HLG included) vs signal-native SDR | PQ +9.0 %, HLG +9.6 %, SDR and linear +4–5 % (tools off) | ≤ 1.10× + 10 µs |
| Display transforms vs signal-native SDR | +8 to +16 % (tools off) | not budgeted |
| Focus mask, 4K, source stage | 0.113 ms | ≤ 0.24 ms |
| Focus mask, 4K, after a 33³ LUT | 0.48 ms tetrahedral, 0.55 ms trilinear | ≤ 0.52 / 0.6 ms |
| Four 4K feeds (4 analyses, 4 × 1080p and 4 × 540p surfaces) into one 4K target | 1.56 ms in one `MonitorMultiview` pass (1.96 ms as eight passes) | ≤ 2.0 ms |
| Scope accumulation of every 4K pixel, one scope | 0.32–0.42 ms | ≤ 1 ms |
| Waveform, vectorscope and histogram fused in one `ScopeGroup`, 4K | 0.62 ms source stage, 0.78 ms output stage | ≤ 1 ms |
| Freeze of a 4K v210 frame | 0.043 ms (22.3 MB of planes while frozen) | ≤ 0.5 ms |
| CPU per surface, classic encode | 7.6–8.8 µs debug, 6.5 µs release | < 30 µs debug |
| CPU per surface, Metal 4 render encode | 9.4 µs debug, 5.3 µs release | ≤ 15 / 10 µs |
| CPU, Metal 4 compute encode / host prepare + draw / analysis | 7.2 / 4.8 / 4.7 µs debug | ≤ 10 µs |
| Heap allocations per steady-state frame (debug builds included) | 0 | 0 |
| Audio, every meter on 16 channels at 48 kHz | 0.30 % of one core (release) | < 1 % |

Memory is owned only where a feature needs it: an r8 focus mask at source size while peaking is on (8.3 MB at 4K), Freeze planes while frozen, scope bins sized to the scope (not the frame), and on Metal 4 one small uniform ring per object. A surface owns no GPU memory on the classic path.

## Correctness and standards

Every GPU path is tested against a CPU reference in `MonitorKitCore`: exact at classification boundaries (code 940 is exactly 100 IRE everywhere), within 1/1023 for decode, 1e−4 for LUT interpolation and 1e−5 for the output-colour paths. Classic and Metal 4 encodes produce bit-identical bytes. The suite runs clean under `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1`.

Constants and formulas come from, among others:

- ITU-R BT.601, BT.709, BT.1886, BT.2020, BT.2100, BT.2087, Reports BT.2407 and BT.2408 (Y'CbCr, transfers, HLG, PQ, reference levels, the HDR-to-SDR EETF, gamut conversion)
- SMPTE ST 2084 (PQ), RP 177 (primary matrices), ST 240, RP 219 / BT.2111 (colour bars), ITU-T H.273 (chroma siting)
- IEC 61966-2-1 (sRGB), CIE 15 and ANSI C78.377 (daylight locus, Duv), ISO/IEC 14496-12 (clean aperture, pixel aspect)
- Sony S-Log3 / S-Gamut3 technical summary and Monitor & Control false colour; ARRI LogC3, LogC4 and LogC false-colour specifications; the public EL Zone chart
- ITU-R BS.1770, EBU R 128, Tech 3341 and 3342 (loudness, true peak); IEC 60268-10, -17 and -18 (PPM, VU, digital peak); EBU R 68 and SMPTE RP 155 (alignment)

[MATH.md](Docs/MATH.md) lists each one with its value, where it is used, the test that checks it, and every place MonitorKit deliberately chose a convention.

## Status and roadmap

Version 0.1.0, unreleased. The API is complete for the features above; Ultracam, its first host, is integrating it now. Until 1.0, minor versions may change the API (each change is listed in the [changelog](CHANGELOG.md)).

Planned:

- More camera log encodings for false colour and the display transforms: Canon Log 2/3, Panasonic V-Log, Blackmagic Film, RED Log3G10, Apple Log, Fujifilm F-Log2, Nikon N-Log, DJI D-Log, with their gamuts. Today: S-Log3 (S-Gamut3, S-Gamut3.Cine), ARRI LogC3 (AWG3) and LogC4 (AWG4).
- Sony Pattern 1 (SDR) false colour; a BT.2446 soft-knee HLG-to-SDR mode; HDR and wide-gamut LUT outputs (today every LUT outputs Rec.709).
- Scopes that follow the clean aperture; fail-closed JSON for `ScopeSettings`; `MTL4Compiler` pipelines for the scopes.
- Performance: the LUT-stage focus mask (over its original 0.4 ms target), large-window pictures (2560 × 1440, 4K 1:1), the compute picture's threadgroup shape.
- iOS: verified at compile time only so far (gestures, `UIScreen` headroom and background pausing have not run on a device).
- An example host app, DocC documentation and CI.

## Contributing

Issues and pull requests are welcome. Please keep to the [architecture contract](Docs/ARCHITECTURE.md): no allocation, copy, queue, thread, commit or readback on the frame path; constants with a cited source in [MATH.md](Docs/MATH.md); a CPU reference and a GPU test for every pixel path. Run `swift test` (GPU tests skip without a Metal device) and, for GPU changes, the suite under `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1`.

## License

MonitorKit is available under the Apache License, Version 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Copyright 2026 Andrew Daniel and MonitorKit contributors.
