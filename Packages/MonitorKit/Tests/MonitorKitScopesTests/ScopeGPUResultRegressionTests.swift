// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

final class ScopeGPUResultRegressionTests: XCTestCase {
  func testClassicRetryAfterAbandonedScopeWrites() throws {
    let (_, queue, _) = try GPU.require()
    try checkAbandonedWrites { renderer, accumulator, viewport, target, abandon in
      try autoreleasepool {
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        try renderer.render(accumulator, target: target, viewport: viewport, clear: true, into: cb)
        if abandon { return }
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
      }
    }
  }

  func testClassicSameBufferAndCompletedWritesStayReusable() throws {
    let (_, _, engine) = try GPU.require()
    let renderer = engine.makeRenderer()
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .waveform))
    let frame = try TestFrame.make(.rgba16Float, width: 16, height: 16, rgb: { _, _ in SIMD3(repeating: 0.5) })
    let area = MonitorViewport(width: 128, height: 128)
    let format = MonitorRenderTargetFormat(colorPixelFormat: .rgba8Unorm)
    func assertCached(_ cb: MTLCommandBuffer) throws {
      let work = try renderer.update(accumulator, display: nil, viewport: area, target: format, commandBuffer: cb)
      XCTAssertNil(work.rasterize)
      XCTAssertNil(work.resolve)
    }
    try autoreleasepool {
      let queue = try XCTUnwrap(GPU.queue)
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      let gate = try XCTUnwrap(queue.device.makeSharedEvent())
      cb.encodeWaitForEvent(gate, value: 1)
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try renderer.prepare(accumulator, viewport: area, target: format, into: cb)
      try assertCached(cb)
      cb.commit()
      defer { gate.signaledValue = 1 }
      let next = try XCTUnwrap(queue.makeCommandBuffer())
      try assertCached(next)
      gate.signaledValue = 1
      cb.waitUntilCompleted()
      if let error = cb.error { throw error }
    }
    try autoreleasepool {
      try GPU.run { cb in try renderer.prepare(accumulator, viewport: area, target: format, into: cb) }
    }
    try GPU.run(assertCached)
    XCTAssertEqual(renderer.graticuleBuildCount, 1)
  }

  func testClassicWritesReleasePausedFramesAndTargets() throws {
    let (_, _, engine) = try GPU.require()
    let renderer = engine.makeRenderer()
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .waveform))
    for submit in [false, true] {
      weak var source: MTLTexture?, destination: MTLTexture?, producer: MTLCommandBuffer?
      try autoreleasepool {
        let frame = try TestFrame.make(.rgba16Float, width: 16, height: 16, rgb: { _, _ in SIMD3(repeating: 0.5) })
        let target = try ScopeRenderTests().makeTarget(width: 128, height: 128)
        source = frame.frame.luma
        destination = target
        let cb = try XCTUnwrap(GPU.queue?.makeCommandBuffer())
        producer = cb
        try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        try renderer.render(accumulator, target: target, clear: true, into: cb)
        if submit {
          cb.commit()
          cb.waitUntilCompleted()
          if let error = cb.error { throw error }
        }
      }
      withExtendedLifetime(renderer) {
        XCTAssertNil(producer, "a paused renderer must leave the host's queue slot free")
        XCTAssertNil(source, "a paused renderer must release the input frame")
        XCTAssertNil(destination, "a paused renderer must release the target")
      }
    }
  }

  func testMetal4RetryAfterAbandonedScopeWrites() throws {
    let host = try requireScopeMTL4()
    try checkAbandonedWrites { renderer, accumulator, viewport, target, abandon in
      host.resident(target)
      if abandon {
        let pending = host.begin()
        try renderer.render(accumulator, target: target, viewport: viewport, clear: true, into: pending.submission)
        pending.commandBuffer.endCommandBuffer()
        renderer.invalidateGPUResults()
        XCTAssertFalse(renderer.isReady)
      } else {
        try host.run { try renderer.render(accumulator, target: target, viewport: viewport, clear: true, into: $0) }
      }
    }
  }

  private func checkAbandonedWrites(
    _ draw: (ScopeRenderer, ScopeAccumulator, MonitorViewport, MTLTexture, Bool) throws -> Void
  ) throws {
    let (_, _, engine) = try GPU.require()
    let renderer = engine.makeRenderer()
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .histogram, stage: .source))
    let render = ScopeRenderTests()
    let target = try render.makeTarget(width: 128, height: 128)
    let reference = try render.makeTarget(width: 128, height: 128)
    let first = MonitorViewport(width: 100, height: 100), next = MonitorViewport(width: 128, height: 128)

    func accumulate(_ level: Float) throws {
      let frame = try TestFrame.make(.rgba16Float, width: 64, height: 32, rgb: { _, _ in SIMD3(repeating: level) })
      try GPU.run { try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: $0) }
    }
    try accumulate(0.25)
    try draw(renderer, accumulator, first, target, false)
    let grid = try XCTUnwrap(renderer.graticuleTexture), trace = try XCTUnwrap(renderer.traceTexture)

    // Both writes target textures with known, obsolete content.
    try accumulate(0.75)
    try draw(renderer, accumulator, next, target, true)
    try draw(renderer, accumulator, next, target, false)
    try draw(engine.makeRenderer(), accumulator, next, reference, false)
    XCTAssertTrue(renderer.graticuleTexture === grid)
    XCTAssertTrue(renderer.traceTexture === trace)
    let expected = render.pixels(reference)
    XCTAssertGreaterThan(expected.filter { $0.x > 0 }.count, 0)
    let firstMismatch = zip(render.pixels(target), expected).enumerated().first { $0.element.0 != $0.element.1 }
    XCTAssertNil(firstMismatch)
  }

  func testHalfOpacityGraticulePreservesMatchingDestinationColor() throws {
    let (_, _, engine) = try GPU.require()
    var settings = ScopeSettings(kind: .waveform)
    settings.display.backgroundOpacity = 0
    settings.display.showsGraticule = true
    settings.display.graticuleOpacity = 0.5
    let accumulator = try engine.makeAccumulator(settings: settings)
    let renderer = engine.makeRenderer(), render = ScopeRenderTests()
    let color = SIMD4<UInt8>(219, 209, 179, 255)
    for format: MTLPixelFormat in [.rgba8Unorm_srgb, .rgba8Unorm] {
      let target = try render.makeTarget(format, width: 128, height: 128)
      try GPU.run { try renderer.render(accumulator, target: target, clear: true, into: $0) }
      XCTAssertTrue(render.pixels(target).contains { $0.w > 0 && $0.w < 255 })
      let fill = Array(repeating: color, count: target.width * target.height)
      fill.withUnsafeBytes {
        target.replace(region: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0,
                       withBytes: $0.baseAddress!, bytesPerRow: target.width * 4)
      }
      try GPU.run { try renderer.render(accumulator, target: target, into: $0) }
      XCTAssertTrue(render.pixels(target).allSatisfy { pixel in
        (0..<4).allSatisfy { abs(Int(pixel[$0]) - Int(color[$0])) <= 1 }
      }, "\(format)")
    }
  }

  func testNonfiniteFloatMeasurementsMatchPictureAndSanitizedReference() throws {
    let (device, _, engine) = try GPU.require()
    let monitor = try MonitorEngine(device: device, specialization: .synchronous)
    let feed = monitor.makeFeed(), pass = monitor.makePass()
    feed.burnInLUT = try MonitorLUT(device: device, cube: ScopeAccumulationTests.makeCube(size: 3) {
      SIMD3($0.z, $0.x, $0.y)
    })
    let samples: [SIMD3<Float>] = [SIMD3(.nan, 0.5, 0.5), SIMD3(0.5, .infinity, 0.5), SIMD3(0.5, 0.5, -.infinity)]
    let sanitized: [SIMD3<Float>] = [SIMD3(0, 0.5, 0.5), SIMD3(0.5, 65504, 0.5), SIMD3(0.5, 0.5, -65504)]
    let agreement = ScopePictureAgreementTests()
    for stage in [SignalStage.source, .output] {
      var settings = ScopeSettings(kind: .histogram, stage: stage)
      settings.clipLowPercent = 0
      settings.clipHighPercent = 100
      let scope = try engine.makeAccumulator(settings: settings)
      func measure(_ values: [SIMD3<Float>]) throws -> (MonitorFrame, ScopeStatistics, [UInt32]) {
        let frame = try TestFrame.make(.rgba16Float, width: 30, height: 10, rgb: { x, _ in values[x / 10] }).frame
        try GPU.run { try scope.accumulate(frame, feed: feed, into: $0) }
        return (frame, try XCTUnwrap(scope.statistics), try readBins(scope))
      }
      let (_, expected, bins) = try measure(sanitized)
      let (frame, actual, actualBins) = try measure(samples)
      XCTAssertEqual(actualBins, bins)
      XCTAssertEqual(actual.lumaMinimum, expected.lumaMinimum)
      XCTAssertEqual(actual.lumaMaximum, expected.lumaMaximum)
      XCTAssertEqual(actual.lumaAverage, expected.lumaAverage)
      XCTAssertEqual(actual.clippedHigh, expected.clippedHigh)
      XCTAssertEqual(actual.clippedLow, expected.clippedLow)
      for channel in 0..<4 {
        for high in [true, false] {
          let marked = try agreement.clipIndicatorCount(
            frame, stage: stage, channel: channel, high: high, levels: (100, 0), feed: feed, pass: pass)
          let fraction = (high ? actual.clippedHigh : actual.clippedLow)[channel]
          XCTAssertEqual(marked, Int((fraction * Double(actual.pixelCount)).rounded()))
        }
      }
    }
  }

  func testFloatFullRangeCodeLabelsAtEveryStage() throws {
    let (_, _, engine) = try GPU.require()
    let signal = SignalDescription(range: .legal, outputReading: SignalReading(range: .legal, matrix: .bt601))
    let frame = try TestFrame.make(.rgba16Float, width: 4, height: 4, signal: signal, rgb: { _, _ in SIMD3(repeating: 1) })
    for stage in SignalStage.allCases {
      var settings = ScopeSettings(kind: .waveform, stage: stage)
      settings.display.waveformScale = .codeValues
      let scope = try engine.makeAccumulator(settings: settings)
      try GPU.run { try scope.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: $0) }
      XCTAssertEqual(scope.context.range, .full)
      let labels = scope.graticule(width: 256, height: 256).labels
      XCTAssertTrue(labels.contains { $0.text == "1023" })
      XCTAssertFalse(labels.contains { $0.text == "940" })
    }
  }
}
