// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

final class Perf11ScopeCacheTests: XCTestCase {
  func testSemanticEditsReuseGeometryAndMatchFreshAccumulators() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.natural(.bgra8, width: 64, height: 32, mirror: false)
    for kind in ScopeKind.allCases {
      let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: kind, stage: .source))
      let renderer = engine.makeRenderer()
      let viewport = MonitorViewport(width: 256, height: 192)
      let target = MonitorRenderTargetFormat(colorPixelFormat: .rgba8Unorm)
      try GPU.run { cb in
        try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        try renderer.prepare(accumulator, viewport: viewport, target: target, into: cb)
      }
      let tileBuilds = accumulator.tileBuildCount
      let graticuleBuilds = renderer.graticuleBuildCount
      let oldBins = accumulator.bins
      accumulator.settings.stage = .output
      accumulator.settings.clipHighPercent = 70
      accumulator.settings.clipLowPercent = 10
      // Matrix changes affect vectorscope targets, so retain it there.
      if kind != .vectorscope { accumulator.settings.colorimetry = .bt601 }
      let fresh = try engine.makeAccumulator(settings: accumulator.settings)
      try GPU.run { cb in
        try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        try fresh.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        try renderer.prepare(accumulator, viewport: viewport, target: target, into: cb)
      }
      XCTAssertEqual(accumulator.tileBuildCount, tileBuilds, "\(kind)")
      XCTAssertEqual(renderer.graticuleBuildCount, graticuleBuilds, "\(kind)")
      XCTAssertTrue(accumulator.bins === oldBins)
      XCTAssertEqual(try ScopeGroupTests.result([accumulator]), try ScopeGroupTests.result([fresh]))
      XCTAssertEqual(renderer.graticule, accumulator.graticule(width: 256, height: 192))
      XCTAssertEqual(accumulator.accumulatedSettings, accumulator.settings)
      switch kind {
      case .waveform: accumulator.settings.waveformLevels = 1024
      case .histogram: accumulator.settings.histogramBins = 1024
      case .vectorscope: accumulator.settings.vectorscopeZoom = 2
      }
      try GPU.run { cb in
        try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        try renderer.prepare(accumulator, viewport: viewport, target: target, into: cb)
      }
      XCTAssertEqual(renderer.graticuleBuildCount, graticuleBuilds + 1, "\(kind): real geometry change")
      XCTAssertEqual(renderer.graticule, accumulator.graticule(width: 256, height: 192))
    }
  }

  func testSameLayoutKindTransitionStillRebuildsDispatch() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.natural(.bgra8, width: 64, height: 32, mirror: false)
    var settings = ScopeSettings(kind: .waveform, stage: .source)
    settings.waveformColumns = 256
    settings.waveformLevels = 256
    settings.vectorscopeSize = 256
    let accumulator = try engine.makeAccumulator(settings: settings)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    let builds = accumulator.tileBuildCount
    accumulator.settings.kind = .vectorscope
    let fresh = try engine.makeAccumulator(settings: accumulator.settings)
    try GPU.run { cb in
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try fresh.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
    }
    XCTAssertEqual(accumulator.tileBuildCount, builds + 1)
    XCTAssertEqual(try ScopeGroupTests.result([accumulator]), try ScopeGroupTests.result([fresh]))
  }
}
