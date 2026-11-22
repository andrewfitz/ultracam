// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

final class ScopeShaderSIMDWidthRegressionTests: XCTestCase {
  /// A flat tile puts every active SIMD lane in the leader's bin. On devices
  /// with 64-wide SIMD groups, narrowing its ballot to 32 bits loses half the
  /// samples. Odd dimensions also exercise the final, partially active group.
  func testPackedAccumulationCountsEverySIMDLane() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.make(
      .bgra8, width: 257, height: 129, rgb: { _, _ in SIMD3(repeating: 0.5) })
    for kind in [ScopeKind.waveform, .histogram] {
      var settings = ScopeSettings(kind: kind, stage: .source)
      settings.waveformColumns = 128
      settings.waveformLevels = 256
      settings.histogramBins = 256
      settings.histogramMode = .luma
      let accumulator = try engine.makeAccumulator(settings: settings)
      try GPU.run { cb in
        try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      }
      let bins = try readBins(accumulator)
      XCTAssertEqual(bins.reduce(UInt64(0)) { $0 + UInt64($1) }, UInt64(frame.width * frame.height), "\(kind)")
      XCTAssertEqual(accumulator.statistics?.pixelCount, frame.width * frame.height, "\(kind)")
    }
  }
}
