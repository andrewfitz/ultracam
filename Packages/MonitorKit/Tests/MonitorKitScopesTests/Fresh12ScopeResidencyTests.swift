// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import XCTest

@testable import MonitorKitScopes

final class Fresh12ScopeResidencyTests: XCTestCase {
  func testForeignAccumulatorRetiresBinsAfterRendererSubmission() throws {
    let m = try requireScopeMTL4()
    let source = try ScopeEngine(device: m.device, specialization: .synchronous)
    let destination = try ScopeEngine(device: m.device, specialization: .synchronous)
    m.attach(source)
    m.attach(destination)
    var accumulator: ScopeAccumulator? = try source.makeAccumulator(settings: ScopeSettings(kind: .histogram))
    let frame = try TestFrame.natural(.bgra8, width: 32, height: 32, seed: 12)
    try GPU.run { commandBuffer in
      try XCTUnwrap(accumulator).accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: commandBuffer)
    }
    let bins = try XCTUnwrap(accumulator).bins
    let statistics = try XCTUnwrap(accumulator).statisticsBuffer
    let renderer = destination.makeRenderer()
    let target = try m.target(128, 128, format: .rgba8Unorm)
    try m.run { submission in
      try renderer.render(try XCTUnwrap(accumulator), target: target, into: submission)
      XCTAssertEqual(source.residency.latestSubmission, submission.index)
      accumulator = nil
      XCTAssertTrue(source.residency.contains(bins), "the pending resolve's input must remain resident")
      XCTAssertTrue(source.residency.contains(statistics))
    }
    source.residency.release(through: source.residency.latestSubmission)
    XCTAssertFalse(source.residency.contains(bins))
    XCTAssertFalse(source.residency.contains(statistics))
  }
}
