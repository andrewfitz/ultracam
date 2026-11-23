// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import XCTest

@testable import MonitorKitScopes

final class Fresh12ScopeResidencyTests: XCTestCase {
  func testClassicReshapeRetiresBinsStillUsedByMetal4() throws {
    let m = try requireScopeMTL4()
    let engine = try ScopeEngine(device: m.device, specialization: .synchronous)
    m.attach(engine)
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .waveform))
    let frame = try TestFrame.natural(.bgra8, width: 64, height: 36, mirror: false)
    m.resident(frame.frame)
    let submission = m.begin()
    try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: submission.submission)
    let bins = accumulator.bins
    XCTAssertTrue(engine.residency.contains(bins))

    // The replacement has a different size and may be written on the classic
    // queue without touching the old bins. Keep the old Metal 4 use pending.
    accumulator.settings.waveformLevels = 256
    try GPU.run { try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: $0) }
    XCTAssertFalse(bins === accumulator.bins)
    XCTAssertTrue(engine.residency.contains(bins))
    XCTAssertEqual(engine.residency.pendingReleaseCount, 1)

    let completed = XCTestExpectation(description: "Metal 4 accumulation completed")
    m.commit(submission) { ms in
      XCTAssertNotNil(ms)
      completed.fulfill()
    }
    wait(for: [completed], timeout: 10)
    XCTAssertGreaterThanOrEqual(m.completedIndex, submission.submission.index)
    engine.residency.release(through: m.completedIndex)
    XCTAssertFalse(engine.residency.contains(bins))
  }

  func testClassicResizeReleasesReplacedMetal4TraceAndGraticule() throws {
    let m = try requireScopeMTL4()
    let engine = try ScopeEngine(device: m.device, specialization: .synchronous)
    m.attach(engine)
    let renderer = engine.makeRenderer()
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .waveform))
    let frame = try TestFrame.natural(.bgra8, width: 64, height: 36)
    m.resident(frame.frame)
    let small = try m.target(128, 128, format: .rgba8Unorm)
    try m.run { submission in
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: submission)
      try renderer.render(accumulator, target: small, into: submission)
    }
    let trace = try XCTUnwrap(renderer.traceTexture)
    let graticule = try XCTUnwrap(renderer.graticuleTexture)
    XCTAssertTrue(engine.residency.contains(trace))
    XCTAssertTrue(engine.residency.contains(graticule))

    let large = try m.target(256, 256, format: .rgba8Unorm)
    accumulator.settings.waveformMode = .rgbOverlay
    try GPU.run { cb in
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try renderer.render(accumulator, target: large, into: cb)
    }
    XCTAssertFalse(trace === renderer.traceTexture)
    XCTAssertFalse(graticule === renderer.graticuleTexture)
    XCTAssertTrue(engine.residency.contains(trace))
    XCTAssertTrue(engine.residency.contains(graticule))
    engine.residency.release(through: m.completedIndex)
    XCTAssertFalse(engine.residency.contains(trace))
    XCTAssertFalse(engine.residency.contains(graticule))
  }

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
