// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Metal
import Synchronization
import XCTest

@testable import MonitorKit

final class Audit3EngineTests: XCTestCase {
  /// A specialization that cannot build (an integer target: the picture writes
  /// float4) used to leave the pending set on failure with nothing remembered, so
  /// every prepare (once a frame while the pass keeps the stand-in) started the
  /// same failing compile again.
  func testFailedAsynchronousSpecializationIsNotRestartedEveryPrepare() throws {
    let gpu = try requireGPU()
    // Apple's driver reports the mismatch as an error; another GPU's validation
    // layer may assert instead, which would end the test process.
    guard gpu.device.supportsFamily(.apple7) else { throw XCTSkip("needs an Apple GPU's pipeline error") }
    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous)
    let key = MonitorEngine.PipelineKey(
      target: .init(colorPixelFormat: .rgba32Uint), layout: 0, variant: .uber, color: MonitorEngine.ColorKey())
    XCTAssertNil(try engine.specializedPipeline(key))
    XCTAssertEqual(engine.asynchronousBuildsStarted, 1)
    let deadline = Date().addingTimeInterval(60)
    while engine.failedPipelineCount == 0 && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
      // Frames keep asking while the build runs and after it failed.
      XCTAssertNil(try engine.specializedPipeline(key))
    }
    XCTAssertEqual(engine.failedPipelineCount, 1, "the build should have failed")
    for _ in 0..<20 { XCTAssertNil(try engine.specializedPipeline(key)) }
    XCTAssertEqual(engine.asynchronousBuildsStarted, 1)
    // The synchronous build still reports the failure to its caller.
    XCTAssertThrowsError(try engine.renderPipeline(key))
  }

  /// A working specialization is unaffected: started once, then found.
  func testSuccessfulAsynchronousSpecializationIsStartedOnce() throws {
    let gpu = try requireGPU()
    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous)
    var variant = MonitorEngine.Variant.uber
    variant.zebras = false
    let key = MonitorEngine.PipelineKey(
      target: .init(colorPixelFormat: .bgra8Unorm), layout: 4, variant: variant, color: MonitorEngine.ColorKey())
    var state = try engine.specializedPipeline(key)
    let deadline = Date().addingTimeInterval(120)
    while state == nil && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
      state = try engine.specializedPipeline(key)
    }
    XCTAssertNotNil(state)
    XCTAssertEqual(engine.asynchronousBuildsStarted, 1)
    XCTAssertEqual(engine.failedPipelineCount, 0)
  }

  /// Ultracam numbers its frames from 1 with a process-wide counter, while
  /// MonitorKit numbered the frames it makes (every `init`, every Freeze copy)
  /// from 1 too. A live frame numbered like the frozen frame analysed before it,
  /// at the same size and layout, then passed for that frozen frame's analysis:
  /// peaking from the frozen picture drawn over the live one.
  func testLibraryFrameIDsCannotCollideWithAHostCounter() throws {
    let gpu = try requireGPU()
    let feed = gpu.engine.makeFeed()
    let live = try SyntheticFrame.random(.v210, width: 12, height: 4, seed: 3001).frame(gpu, signal: .rec709)
    XCTAssertGreaterThanOrEqual(live.id, 1 << 63)
    var frozen: MonitorFrame?
    try gpu.run { frozen = try feed.freeze(live, into: $0) }
    let still = try XCTUnwrap(frozen)
    XCTAssertGreaterThanOrEqual(still.id, 1 << 63)
    var focus = FocusSettings()
    focus.enabled = true
    focus.stage = .source
    try gpu.run { try feed.analyze(still, focus: focus, into: $0) }
    XCTAssertTrue(feed.hasFocusMask(for: still, stage: .source, monitorLUTEnabled: true))
    // A host counter's values, however far it has run in a session, are not the
    // frozen frame's: the next live frame is analysed, not taken as held.
    var next = live
    for counter: UInt64 in [0, 1, 2, 1_000, 1 << 40, (1 << 63) - 1] {
      next.id = counter
      XCTAssertFalse(feed.hasFocusMask(for: next, stage: .source, monitorLUTEnabled: true), "id \(counter)")
    }
  }

  /// The monitor stage with the monitor LUT off shows the output: a mask analysed
  /// at `.output` (what `analyze` now documents) is that surface's.
  func testOutputStageMaskServesAMonitorStageSurfaceWithItsLUTOff() throws {
    let gpu = try requireGPU()
    let feed = gpu.engine.makeFeed()
    feed.monitorLUT = try gpu.engine.warmUpLUT()
    let frame = try SyntheticFrame.random(.v210, width: 12, height: 4, seed: 3002).frame(gpu, signal: .rec709)
    var focus = FocusSettings()
    focus.enabled = true
    focus.stage = .monitor
    try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
    XCTAssertFalse(feed.hasFocusMask(for: frame, stage: .monitor, monitorLUTEnabled: false))
    focus.stage = .output
    try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
    XCTAssertTrue(feed.hasFocusMask(for: frame, stage: .monitor, monitorLUTEnabled: false))
  }

  /// A synchronous caller used to wait without limit for a background build of
  /// its key. A task owner needs a free cooperative-pool thread to finish; with
  /// every pool thread blocked in such waits (a wide group of `warmUp`/`prepare`
  /// calls just after init, while the copy-kernel tasks are queued) nothing could
  /// finish. The hook holds the key as that starved task would: without the
  /// deadline the call below never returns and the test fails on its timeout.
  func testSynchronousCallerStopsWaitingForAStalledBackgroundBuild() throws {
    let gpu = try requireGPU()
    let engine = try MonitorEngine(device: gpu.device, specialization: .off)
    engine.asynchronousJoinTimeout.withLock { $0 = 0.2 }
    XCTAssertTrue(engine.holdCopyBuildForTesting(integer: true))
    defer { engine.finishHeldCopyBuild(integer: true) }
    let done = expectation(description: "copyPipeline returns")
    let built = Mutex<Bool>(false)
    Thread.detachNewThread {
      built.withLock { $0 = (try? engine.copyPipeline(integer: true)) != nil }
      done.fulfill()
    }
    XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 60), .completed, "hung on the stalled build")
    XCTAssertTrue(built.withLock { $0 })
    XCTAssertEqual(engine.asynchronousJoinsAbandoned, 1)
    XCTAssertNotNil(engine.cachedCopyPipeline(integer: true))
  }

  /// The deadline is for background owners only: synchronous callers of one cold
  /// key still compile it once, however long the owner's compile takes.
  func testSynchronousOwnersAreWaitedForPastTheDeadline() throws {
    let gpu = try requireGPU()
    let engine = try MonitorEngine(device: gpu.device, specialization: .synchronous)
    engine.asynchronousJoinTimeout.withLock { $0 = 0.001 }
    let key = MonitorEngine.PipelineKey(
      target: .init(colorPixelFormat: .rgba16Float), layout: 3, variant: .uber, color: .fromUniforms)
    DispatchQueue.concurrentPerform(iterations: 8) { _ in _ = try? engine.renderPipeline(key) }
    XCTAssertEqual(engine.pipelinesBuiltOnCaller, 1)
    XCTAssertEqual(engine.asynchronousJoinsAbandoned, 0)
  }
}
