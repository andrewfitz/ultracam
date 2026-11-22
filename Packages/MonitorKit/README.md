# MonitorKit

**Professional video monitoring for Apple platforms: zebras, false colour, focus peaking, LUTs, HDR viewing, scopes and broadcast audio meters, rendered on the GPU with zero overhead.**

[![CI](https://github.com/andrewfitz/MonitorKit/actions/workflows/ci.yml/badge.svg)](https://github.com/andrewfitz/MonitorKit/actions/workflows/ci.yml)
[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2026%20%7C%20iOS%2026-0A84FF)](#requirements)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-34C759)](#installation)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

MonitorKit is a Swift and Metal package that brings the monitoring assists of a professional camera monitor to any macOS or iOS app that shows video. It covers the tools found on cameras such as the Sony FX3 and on field monitors such as the Blackmagic Video Assist 12G HDR, and every constant traces to a published standard or manufacturer document.

- **Zero overhead.** Encodes into your command buffers and borrows your textures. On the frame path it copies no frame, allocates nothing, creates no queue or thread, never commits or waits, and reads nothing back from the GPU.
- **Classic Metal and Metal 4.** The same pass encodes into an `MTLCommandBuffer` or an `MTL4CommandBuffer`, with bit-identical pixels.
- **Accurate.** Every GPU path is tested against a CPU reference implementation, exact at classification boundaries.
- **HDR-native.** Signal-native SDR, PQ, HLG and extended-linear output with EDR layer tagging; display transforms for viewing log and HDR sources on SDR screens.
- **Use as much as you need.** Drop in a SwiftUI view, or encode into your own Metal pipeline, or fuse the LUT into your own kernel.
- **No dependencies.** Shaders ship as source and compile at runtime, so no Metal toolchain is needed to build.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Getting started](#getting-started)
- [Performance](#performance)
- [Correctness and standards](#correctness-and-standards)
- [Documentation](#documentation)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## Features

**Exposure**
- Zebras: two sets at once, each a band (level ± range) or a lower limit, from −20 to 120 IRE
- False colour: Sony S-Log3 (Monitor & Control Pattern 2), ARRI LogC3 and LogC4, ARRI-style on S-Log3, six-band, and custom bands in IRE or stops
- Clip indicators per channel (R, G, B, luma), over and under, with exact clip percentages

**Focus and framing**
- Focus peaking in five colours, as coloured edges or a traditional peak, analysed at source resolution
- Magnification: pixel-exact 1:1, 1–64× zoom with pan and a navigator inset
- Frame guides: 16 aspect ratios plus custom, as lines or matte; safe areas, thirds, grid, diagonals, centre marks
- Anamorphic de-squeeze (1.3× to 4×), flips, clean aperture and pixel aspect ratio

**Colour and HDR**
- `.cube` LUTs from 2³ to 65³, with 1D shapers and tetrahedral, trilinear or hardware interpolation, routed monitor-only or burned in, and stackable
- Display transforms: log to Rec.709 (S-Log3, LogC3, LogC4), PQ to SDR (BT.2408 EETF), HLG to SDR (BT.2446-1 Method C)
- Output in signal-native SDR (BT.1886, sRGB, gamma 2.2), extended linear, PQ or HLG, on Rec.709, P3 or Rec.2020; overlays at BT.2408 graphics white
- Picture adjustments: brightness, contrast, saturation, white-point trim, mono and blue only

**Scopes**
- Waveform (luma, RGB overlay, RGB parade, Y'CbCr parade), vectorscope with 75 % and 100 % targets, and histogram
- IRE, code-value and HDR nit graticules; several scopes at once, every pixel counted

**Audio**
- 1–16 channels of sample peak, BS.1770 true peak, RMS, VU and PPM (Type I, IIa, IIb)
- EBU R 128 loudness: momentary, short-term, integrated, loudness range, max true peak and PLR
- Stereo phase correlation

**Presentation**
- SwiftUI monitor view, scope views, broadcast level meters (compact, strip and full), false-colour legends and a tile toolbar
- Freeze, multiview, clean feed, tally border, timecode and status overlays

The [feature reference](Docs/FEATURES.md) lists every parameter, default and range, and compares each tool with the Sony FX3 and the Video Assist 12G HDR.

## Requirements

| | |
| --- | --- |
| Platforms | macOS 26 or iOS 26 and later, on Apple silicon |
| Toolchain | Xcode 26 or later (Swift 6.2 tools, Swift 6 language mode); running the tests needs Xcode 26.6 or later |
| Metal 4 path | A device that supports `MTLGPUFamily.metal4`. The classic path and the view tier have no such requirement |
| Dependencies | None |

## Installation

Add MonitorKit with Swift Package Manager. In Xcode, choose **File › Add Package Dependencies** and enter:

```
https://github.com/andrewfitz/MonitorKit.git
```

Or add it to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/andrewfitz/MonitorKit.git", from: "0.1.0"),
],
targets: [
  .target(
    name: "MyApp",
    dependencies: [
      .product(name: "MonitorKit", package: "MonitorKit"),
      .product(name: "MonitorKitUI", package: "MonitorKit"),
    ]),
]
```

Depend only on the products you use; each one brings in what it needs.

| Product | Contents | Depends on |
| --- | --- | --- |
| `MonitorKitCore` | Settings (`MonitorState`), signal descriptions, geometry, `.cube` parsing, output colour, and the CPU reference math. Pure Swift | — |
| `MonitorKit` | The picture pass, focus analysis, LUTs, Freeze, multiview and the Metal 4 types. Re-exports `MonitorKitCore` | Core |
| `MonitorKitScopes` | Waveform, vectorscope and histogram, with their statistics, on the GPU | MonitorKit |
| `MonitorKitAudio` | Level meters and loudness. Pure Swift and Accelerate | — |
| `MonitorKitUI` | `MonitorView`, `MonitorMetalView`, scope and meter views, controls and legends | All of the above |

## Getting started

MonitorKit offers four integration tiers. Choose the one that matches how much of the GPU pipeline your app already owns.

| Tier | Your app provides | MonitorKit provides |
| --- | --- | --- |
| **View** (`MonitorKitUI`) | A SwiftUI view and a stream of frames | Everything: the layer, display link, colour tagging, gestures and scopes |
| **Encode, classic Metal** | An `MTLCommandQueue` and the drawable | Encoding into your `MTLCommandBuffer` |
| **Encode, Metal 4** | An `MTL4CommandQueue`, residency sets and a completion watermark | Encoding into your `MTL4CommandBuffer`, with its own argument tables, uniforms and barriers |
| **Fused** | Your own compute kernel, such as an output encoder | `MKLUT.msl` and `MKDecode.msl` to prepend, so a burned-in LUT costs no extra pass |

### A monitor view

The view tier needs a few lines of SwiftUI and a call per captured frame:

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

`MonitorView` draws on a `CAMetalDisplayLink`, tags its layer for SDR or EDR from the signal, follows the screen's EDR headroom, and turns pinch, scroll, drag and double-click into magnification. `ScopeView` and `ScopeStackView` add scopes of the same source, `LevelMeterView` draws an `AudioMeter` as a compact, strip or full true-peak meter, and `AudioMeterView` adds the R 128 loudness panel and phase correlation.

### Encoding into your own command buffer

If your app already renders with Metal, MonitorKit encodes into the command buffer you commit:

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

### Going further

- **Metal 4:** the [integration guide](Docs/INTEGRATION.md#4-metal-4-step-by-step) walks through submission indices, the completion watermark and residency, with a complete host.
- **Fused LUT:** to burn a LUT into your own output kernel with pixels identical to the monitor's Output stage, see [the fused tier](Docs/INTEGRATION.md#13-fused-tier-a-burned-in-lut-in-your-own-kernel).
- **A complete multi-camera host:** see the [worked example](Docs/INTEGRATION.md#10-worked-example-a-multi-camera-monitor).

## Performance

Measured on an Apple M4 Max. The package's benchmark tests also enforce each budget (`swift test --filter Benchmark`).

| Work | Measured | Budget |
| --- | --- | --- |
| Picture pass, 4K v210 source, every tool on, into 1080p | 0.26 ms | ≤ 0.35 ms |
| … into 2560 × 1440 | 0.50 ms | ≤ 0.55 ms |
| … into 4K, 1:1 | 0.70 ms | ≤ 0.8 ms |
| Four 4K feeds into one 4K multiview | 1.38 ms | ≤ 2.0 ms |
| Focus analysis, 4K | 0.089 ms | ≤ 0.24 ms |
| Waveform, vectorscope and histogram together, every 4K pixel | 0.56 ms | ≤ 1 ms |
| Freeze of a 4K frame | 0.047 ms | ≤ 0.5 ms |
| CPU encode per surface, release build (classic / Metal 4) | 6.5 / 5.3 µs | — |
| Heap allocations per steady-state frame | 0 | 0 |
| Audio, every meter on 16 channels at 48 kHz | 0.30 % of one core | < 1 % |

GPU times are the minimum of 60 command-buffer timestamps after ten warm-ups; CPU times are medians of steady-state encodes. Your hardware will differ. The full table, including every output encoding and display transform, is in [ARCHITECTURE.md](Docs/ARCHITECTURE.md#quality-bars).

Memory is allocated only where a feature needs it: a focus mask at source size while peaking is on (8.3 MB at 4K), Freeze planes while frozen, and scope bins sized to the scope rather than the frame. On the classic path a surface owns no GPU memory.

## Correctness and standards

Every GPU path is tested against a CPU reference in `MonitorKitCore`:
- exact at classification boundaries (code 940 is exactly 100 IRE everywhere);
- within 1/1023 for decode;
- within 1e−4 for LUT interpolation;
- within 1e−5 for output colour.

Classic and Metal 4 encodes produce bit-identical bytes, and the suite runs clean under Metal API and shader validation.

The math follows published sources, including:

- **Video:** ITU-R BT.601, BT.709, BT.1886, BT.2020, BT.2100, BT.2087; Reports BT.2407, BT.2408 and BT.2446; SMPTE ST 2084, RP 177, ST 240; ITU-T H.273
- **Colour:** IEC 61966-2-1 (sRGB), CIE 15, ANSI C78.377, ISO/IEC 14496-12
- **Camera:** Sony S-Log3 and S-Gamut3 technical summaries and Monitor & Control false colour; ARRI LogC3, LogC4 and LogC false-colour specifications
- **Audio:** ITU-R BS.1770, EBU R 128, Tech 3341 and 3342, IEC 60268-10, -17 and -18, EBU R 68, SMPTE RP 155

[MATH.md](Docs/MATH.md) gives every constant with its value, its source, where it is used and the test that checks it.

## Documentation

| Document | What it covers |
| --- | --- |
| [Features](Docs/FEATURES.md) | Every tool, its parameters and defaults, and the device behaviour it follows |
| [API](Docs/API.md) | Every public type by module, with threading and lifetime rules |
| [Integration guide](Docs/INTEGRATION.md) | Classic Metal and Metal 4 step by step, HDR, multiview, scopes, audio, and a worked example |
| [Architecture](Docs/ARCHITECTURE.md) | The zero-overhead contract, data flow, barriers, lifetimes and performance |
| [Math](Docs/MATH.md) | Every formula and constant, with its source and test |
| [Changelog](CHANGELOG.md) | Release history |

## Roadmap

MonitorKit is at 0.1. The API covers every feature above; until 1.0, minor versions may change it, and every change is listed in the [changelog](CHANGELOG.md).

Planned:
- More camera log encodings: Canon Log 2 and 3, Panasonic V-Log, Blackmagic Film, RED Log3G10, Apple Log, Fujifilm F-Log2, Nikon N-Log and DJI D-Log
- Sony Pattern 1 (SDR) false colour
- A hue-preserving gamut step for HDR to SDR (BT.2407 Annex 5)
- HDR and wide-gamut LUT outputs
- Scopes that follow the clean aperture
- On-device verification on iOS (today it is compile-checked)
- An example app and DocC articles

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first; in short:
- keep the frame path free of allocations, copies and GPU readback;
- cite a source in [MATH.md](Docs/MATH.md) for every constant;
- add a CPU reference and a GPU test for every pixel path.

To report a security issue, see [SECURITY.md](SECURITY.md).

## License

MonitorKit is released under the [Apache License 2.0](LICENSE). Copyright © 2026 Andrew Fitzgerald.

Sony, FX3, S-Log3 and S-Gamut3 are trademarks of Sony Group Corporation. ARRI, ALEXA and LogC are trademarks of Arnold & Richter Cine Technik GmbH & Co. Betriebs KG. Blackmagic Design, Video Assist and DaVinci Resolve are trademarks of Blackmagic Design Pty. Ltd. Panasonic is a trademark of Panasonic Holdings Corporation. Apple, Metal, macOS and iOS are trademarks of Apple Inc. Other names are trademarks of their respective owners.

MonitorKit is an independent project, not affiliated with or endorsed by any of these companies. Their names identify the standard or device behaviour a feature follows. MonitorKit contains none of their code or LUTs; where a mode reproduces published values, [MATH.md](Docs/MATH.md) names the public source.
