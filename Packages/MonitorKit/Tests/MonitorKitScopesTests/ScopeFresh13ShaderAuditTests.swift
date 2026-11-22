// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

final class ScopeFresh13ShaderAuditTests: XCTestCase {
  /// Exercise unrelated leader/nonleader bins and partially active SIMD groups.
  /// Values are well inside bins, so the CPU reference requires exact counts.
  func testMixedBinsOnOddTilesMatchCPUReference() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.make(.bgra8, width: 259, height: 131, rgb: { x, y in
      return ((x / 3 + y / 5) % 3 == 0) ? SIMD3<Float>(0.23, 0.41, 0.67) : SIMD3<Float>(0.77, 0.31, 0.13)
    })
    for kind in [ScopeKind.waveform, .histogram, .vectorscope] {
      var settings = ScopeSettings(kind: kind, stage: .source)
      settings.waveformColumns = 128
      settings.waveformLevels = 256
      settings.histogramBins = 256
      settings.vectorscopeSize = 256
      let accumulator = try engine.makeAccumulator(settings: settings)
      try GPU.run { cb in
        try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      }
      let reference = ScopeAccumulationTests.reference(accumulator, frame, epsilon: 0)
      reference.check(try readBins(accumulator), "Fresh13 mixed bins \(kind)")
      XCTAssertEqual(accumulator.statistics?.pixelCount, frame.width * frame.height)
    }
  }

  /// The offset sum exceeds UInt32.max, while each tile's sum and packed
  /// private counters remain within their bounds. Device merges must carry.
  func testStatisticsSumCarriesAcrossDeviceLowWord() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.make(.bgra8, width: 1025, height: 513, signal: SignalDescription(range: .full), rgb: { _, _ in
      SIMD3(repeating: 1)
    })
    XCTAssertGreaterThan(UInt64(frame.width * frame.height) * 8192, UInt64(UInt32.max))
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .histogram, stage: .source))
    try GPU.run { cb in
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
    }
    let statistics = try XCTUnwrap(accumulator.statistics)
    XCTAssertEqual(statistics.pixelCount, frame.width * frame.height)
    XCTAssertEqual(statistics.lumaAverage, 1, accuracy: 1e-12)
    XCTAssertEqual(statistics.lumaMinimum, 1, accuracy: 1e-12)
    XCTAssertEqual(statistics.lumaMaximum, 1, accuracy: 1e-12)
  }
}
