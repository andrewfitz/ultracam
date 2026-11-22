// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Metal
import MonitorKit
import MonitorKitCore
import Synchronization
import XCTest

@testable import MonitorKitScopes

final class Audit3ScopesTests: XCTestCase {
  /// Audit coverage (no defect found): a group whose members' settings and
  /// frame size change between accumulations matches fresh accumulators every
  /// time, classic and Metal 4.
  func testGroupFollowsMidSequenceEditsAndFrameSizes() throws {
    _ = try GPU.require()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    var settings: [ScopeSettings] = [
      ScopeSettings(kind: .waveform, stage: .source), ScopeSettings(kind: .histogram, stage: .source),
      ScopeSettings(kind: .vectorscope, stage: .source),
    ]
    let members = try settings.map { try engine.makeAccumulator(settings: $0) }
    let group = try engine.makeGroup(members)
    let sizes: [(Int, Int)] = [(64, 32), (3841, 17), (1, 1), (7, 300), (640, 360)]
    var step = 0
    for (width, height) in sizes {
      let frame = try TestFrame.natural(
        .biplanar(.s422, 10), width: width, height: height, seed: UInt64(step + 5), mirror: false)
      switch step {
      case 1: settings[0].waveformMode = .rgbParade; settings[0].waveformLevels = 2048
      case 2: settings[0].kind = .histogram; settings[0].histogramBins = 4096
      case 3: settings[0].kind = .waveform; settings[1].histogramMode = .rgbParade; settings[2].vectorscopeZoom = 4
      case 4: settings[1].kind = .vectorscope; settings[2].kind = .histogram
      default: break
      }
      for (i, s) in settings.enumerated() { members[i].settings = s }
      let fresh = try settings.map { try engine.makeAccumulator(settings: $0) }
      try GPU.run { cb in
        try group.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        for a in fresh { try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      }
      XCTAssertEqual(try ScopeGroupTests.result(members), try ScopeGroupTests.result(fresh), "classic step \(step)")
      if let m = try? requireScopeMTL4() {
        let fresh4 = try settings.map { try engine.makeAccumulator(settings: $0) }
        m.resident(frame.frame)
        try m.run { submission in
          try group.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: submission)
          for a in fresh4 { try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: submission) }
        }
        XCTAssertEqual(try ScopeGroupTests.result(members), try ScopeGroupTests.result(fresh4), "metal4 step \(step)")
      }
      step += 1
    }
  }

  /// Audit coverage (no defect found): tiny and odd viewports and offsets render without validation errors.
  func testOddViewportsAndOffsetsRender() throws {
    let (device, _, engine) = try GPU.require()
    let frame = try TestFrame.natural(.bgra8, width: 33, height: 7, seed: 9, mirror: false)
    for kind in ScopeKind.allCases {
      for mode in [WaveformMode.luma, .rgbParade, .ycbcrParade] {
        var s = ScopeSettings(kind: kind, stage: .source)
        s.waveformMode = mode
        s.histogramMode = mode == .luma ? .luma : .rgbParade
        let accumulator = try engine.makeAccumulator(settings: s)
        let renderer = engine.makeRenderer()
        let target = try makeTexture(device, .rgba8Unorm, 37, 23, usage: [.renderTarget, .shaderRead])
        let viewports: [MonitorViewport] = [
          MonitorViewport(width: 1, height: 1), MonitorViewport(x: 36, y: 22, width: 1, height: 1),
          MonitorViewport(x: 3, y: 1, width: 1, height: 22), MonitorViewport(x: 0, y: 5, width: 37, height: 1),
          MonitorViewport(x: 1, y: 2, width: 35, height: 3), MonitorViewport(x: 5, y: 0, width: 2, height: 23),
        ]
        for v in viewports {
          try GPU.run { cb in
            try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
            try renderer.render(accumulator, target: target, viewport: v, into: cb)
          }
        }
      }
    }
  }
  /// Audit coverage (no defect found): a flat frame filling 16-bit packed bins
  /// to exactly 65535 matches 32-bit bins.
  func testPackedBinsAtTheirLimitMatchWideBins() throws {
    _ = try GPU.require()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let frame = try TestFrame.make(
      .bgra8, width: 320, height: 13107, rgb: { _, _ in SIMD3(0.5, 0.5, 0.5) }, mirror: false)
    var w = ScopeSettings(kind: .waveform, stage: .source)
    w.waveformColumns = 64
    w.waveformLevels = 64
    let h = ScopeSettings(kind: .histogram, stage: .source)
    let packed = try engine.makeAccumulator(settings: w)
    let wide = try engine.makeAccumulator(settings: w)
    wide.packedBinLimit = 0
    let members = [try engine.makeAccumulator(settings: w), try engine.makeAccumulator(settings: h)]
    let group = try engine.makeGroup(members)
    try GPU.run { cb in
      try packed.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try wide.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try group.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
    }
    XCTAssertEqual(packed.layout.bytesPerBin, 2)
    XCTAssertEqual(group.fusedMemberCount, 2)
    let a = try readBins(packed), b = try readBins(wide), c = try readBins(members[0])
    XCTAssertEqual(a, b)
    XCTAssertEqual(c, b)
    XCTAssertEqual(b.max(), 65535)
  }
  /// Regression: a cold caller joining another owner's build of the same key
  /// waited forever if that owner never finished (e.g. an archive build's task
  /// on a starved cooperative pool). It now compiles itself after
  /// `buildWaitLimit`, leaving the owner's pending claim alone.
  func testColdComputeCallerStopsWaitingForAStalledOwner() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .synchronous)
    engine.buildWaitLimit.withLock { $0 = 0.2 }
    let key = ScopeEngine.ComputeKey(kernel: .histogram, layout: 3)
    // An owner that claimed the key and will never publish a result.
    _ = engine.pendingCompute.withLock { $0.insert(key) }
    let built = expectation(description: "the waiter compiles after the deadline")
    DispatchQueue.global().async {
      if (try? engine.computePipeline(key)) != nil { built.fulfill() }
    }
    // Without the fix the waiter never returns: fail here instead of hanging on later calls.
    guard XCTWaiter.wait(for: [built], timeout: 20) == .completed else {
      return XCTFail("the cold caller is still waiting for an owner that never finishes")
    }
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.compute }, 1)
    XCTAssertTrue(engine.pendingCompute.withLock { $0.contains(key) }, "the owner's claim is its own to release")
    // Cached now: later callers return at once, without waiting or compiling.
    XCTAssertNoThrow(try engine.computePipeline(key))
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.compute }, 1)
  }

  /// `testColdComputeCallerStopsWaitingForAStalledOwner` for render pipelines (warm-up).
  func testWarmUpStopsWaitingForAStalledRenderOwner() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .synchronous)
    engine.buildWaitLimit.withLock { $0 = 0.2 }
    let target = MonitorRenderTargetFormat(colorPixelFormat: .rgba16Float)
    let key = ScopeEngine.RenderKey(target: target, scope: nil)
    _ = engine.pendingRender.withLock { $0.insert(key) }
    let built = expectation(description: "warm-up compiles after the deadline")
    DispatchQueue.global().async {
      if (try? engine.prepare(target: target)) != nil { built.fulfill() }
    }
    // Without the fix the waiter never returns: fail here instead of hanging on later calls.
    guard XCTWaiter.wait(for: [built], timeout: 20) == .completed else {
      return XCTFail("the cold caller is still waiting for an owner that never finishes")
    }
    XCTAssertTrue(engine.isPrepared(target: target))
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.render }, 1)
    XCTAssertTrue(engine.pendingRender.withLock { $0.contains(key) })
  }
  /// Regression: a timed-out caller's successful compile woke nobody, so a
  /// second waiter on the same key slept to its own (longer) deadline.
  func testTimedOutCompileWakesTheKeysOtherWaiters() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .synchronous)
    let key = ScopeEngine.ComputeKey(kernel: .vectorscope, layout: 1)
    _ = engine.pendingCompute.withLock { $0.insert(key) }  // a stalled owner
    engine.buildWaitLimit.withLock { $0 = 0.4 }
    let first = expectation(description: "the first waiter compiles after its deadline")
    DispatchQueue.global().async {
      if (try? engine.computePipeline(key)) != nil { first.fulfill() }
    }
    usleep(50_000)
    // The second waiter's own deadline is far away: only a wake-up returns it soon.
    engine.buildWaitLimit.withLock { $0 = 30 }
    let second = expectation(description: "the second waiter returns the first one's pipeline")
    DispatchQueue.global().async {
      if (try? engine.computePipeline(key)) != nil { second.fulfill() }
    }
    guard XCTWaiter.wait(for: [first, second], timeout: 10) == .completed else {
      return XCTFail("a waiter slept past the compile that finished its key")
    }
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.compute }, 1, "the second waiter compiled nothing")
  }

  /// Regression: a timed-out caller's failed compile made the key terminal while
  /// the owner was still building it, and an owner failing after a timed-out
  /// caller cached the key logged a failure for a pipeline that exists. The
  /// owner's result now decides.
  func testTimedOutFailureLeavesTheDecisionToTheOwner() throws {
    let (device, _, _) = try GPU.require()
    let reference = try XCTUnwrap(GPU.synchronousEngine)
    let engine = try ScopeEngine(device: device, specialization: .synchronous)
    engine.buildWaitLimit.withLock { $0 = 0.2 }
    func waitFor(_ key: ScopeEngine.RenderKey) throws -> Bool {
      let done = expectation(description: "the waiter returns after its deadline")
      let result = Mutex<Bool?>(nil)
      DispatchQueue.global().async {
        let built = (try? engine.renderPipeline(key)) != nil
        result.withLock { $0 = built }
        done.fulfill()
      }
      guard XCTWaiter.wait(for: [done], timeout: 20) == .completed else {
        XCTFail("the waiter never returned")
        throw XCTSkip("hung waiter")
      }
      return try XCTUnwrap(result.withLock { $0 })
    }

    // 1. The timed-out compile fails while the owner still holds its claim: only
    // this caller throws; then the owner succeeds and the key is usable and final.
    let succeeds = ScopeEngine.RenderKey(target: MonitorRenderTargetFormat(colorPixelFormat: .rgba16Float), scope: nil)
    _ = engine.pendingRender.withLock { $0.insert(succeeds) }
    engine.compileFailsForTests.withLock { $0 = true }
    XCTAssertFalse(try waitFor(succeeds))
    XCTAssertFalse(engine.failedRender.withLock { $0.contains(succeeds) }, "not terminal while the owner builds")
    XCTAssertTrue(engine.pendingRender.withLock { $0.contains(succeeds) }, "the owner's claim is untouched")
    XCTAssertTrue(engine.pipelineBuildFailures.isEmpty)
    engine.built(try reference.renderPipeline(succeeds), for: succeeds)
    let (pipeline, final) = try engine.renderPipeline(for: succeeds)
    XCTAssertNotNil(pipeline)
    XCTAssertTrue(final)
    XCTAssertFalse(engine.failedRender.withLock { $0.contains(succeeds) })
    XCTAssertTrue(engine.pipelineBuildFailures.isEmpty)

    // 2. Both fail: the owner's failure is the terminal one, logged once.
    let fails = ScopeEngine.RenderKey(target: MonitorRenderTargetFormat(colorPixelFormat: .bgra8Unorm), scope: nil)
    _ = engine.pendingRender.withLock { $0.insert(fails) }
    XCTAssertFalse(try waitFor(fails))
    XCTAssertFalse(engine.failedRender.withLock { $0.contains(fails) })
    engine.failed(fails, nil)
    XCTAssertTrue(engine.failedRender.withLock { $0.contains(fails) })
    XCTAssertFalse(engine.pendingRender.withLock { $0.contains(fails) })
    XCTAssertEqual(engine.pipelineBuildFailures.count, 1)
    XCTAssertThrowsError(try engine.renderPipeline(fails))

    // 3. The timed-out caller succeeds and the owner fails later: nothing failed.
    engine.compileFailsForTests.withLock { $0 = false }
    let cached = ScopeEngine.RenderKey(target: MonitorRenderTargetFormat(colorPixelFormat: .rgba8Unorm), scope: nil)
    _ = engine.pendingRender.withLock { $0.insert(cached) }
    XCTAssertTrue(try waitFor(cached))
    engine.failed(cached, nil)
    XCTAssertFalse(engine.failedRender.withLock { $0.contains(cached) })
    XCTAssertFalse(engine.pendingRender.withLock { $0.contains(cached) }, "the owner still releases its claim")
    XCTAssertEqual(engine.pipelineBuildFailures.count, 1)
    XCTAssertTrue(engine.isPrepared(target: cached.target))
  }
}
