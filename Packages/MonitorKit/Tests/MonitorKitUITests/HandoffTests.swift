import Dispatch
import Foundation
import Metal
import MonitorKit
import MonitorKitCore
import Synchronization
import XCTest

@testable import MonitorKitUI

/// Frame handoff from capture threads while the display thread draws: a submit
/// never waits for the renderer or the GPU, the renderer always takes the
/// latest frame, and nothing piles up.
final class HandoffTests: XCTestCase {
  static func nanoseconds(_ start: UInt64) -> UInt64 { DispatchTime.now().uptimeNanoseconds &- start }

  func testHandoffUnderStressNeverBlocksEitherSide() throws {
    let gpu = try requireGPU()
    let sources = [MonitorSource(), MonitorSource()]
    // A pool of frames per source; consecutive submits always differ.
    let pools = try sources.indices.map { s in try (0..<8).map { try gpu.sdrFrame(width: 32, height: 18, seed: UInt8(s * 8 + $0)) } }
    var state = MonitorState()
    state.focus.enabled = true
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 60)
    let surfaces = sources.enumerated().map { i, source in
      MonitorSurface(source: source, state: state, region: MonitorRegion(x: Double(i) / 2, y: 0, width: 0.5, height: 1))
    }
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: surfaces))
    let target = gpu.texture(.bgra8Unorm, 64, 18)

    // Warm up: the first tick builds the pipelines.
    for (i, source) in sources.enumerated() { source.submit(pools[i][0]) }
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }

    let producers = 4
    let stop = Atomic<Bool>(false)
    let running = Atomic<Int>(producers)
    let worstSubmit = Atomic<UInt64>(0)
    let totalSubmits = Atomic<Int>(0)
    let group = DispatchGroup()
    for p in 0..<producers {
      let source = sources[p % 2], pool = pools[p % 2]
      group.enter()
      Thread.detachNewThread {
        var worst: UInt64 = 0
        var i = 0
        while !stop.load(ordering: .relaxed) {
          let frame = pool[(i + p) % pool.count]
          let start = DispatchTime.now().uptimeNanoseconds
          source.submit(frame)
          worst = max(worst, Self.nanoseconds(start))
          i += 1
        }
        var current = worstSubmit.load(ordering: .relaxed)
        while worst > current {
          let (done, original) = worstSubmit.compareExchange(expected: current, desired: worst, ordering: .relaxed)
          if done { break }
          current = original
        }
        totalSubmits.add(i, ordering: .relaxed)
        running.subtract(1, ordering: .releasing)
        group.leave()
      }
    }

    // The display thread: ticks with at most three command buffers in flight.
    let inFlight = DispatchSemaphore(value: 3)
    var ticks = 0, worstTick: UInt64 = 0
    let end = DispatchTime.now() + .milliseconds(600)
    while DispatchTime.now() < end {
      inFlight.wait()
      let start = DispatchTime.now().uptimeNanoseconds
      let cb = gpu.queue.makeCommandBuffer()!
      try renderer.update()
      try renderer.encode(target: target, into: cb)
      worstTick = max(worstTick, Self.nanoseconds(start))
      cb.addCompletedHandler { _ in inFlight.signal() }
      cb.commit()
      ticks += 1
      XCTAssertLessThanOrEqual(renderer.retiredCount, 2 * max(3, gpu.engine.framesInFlight) + 2)
    }
    stop.store(true, ordering: .relaxed)
    XCTAssertEqual(group.wait(timeout: .now() + .seconds(10)), .success, "a producer is stuck: a deadlock")
    XCTAssertEqual(running.load(ordering: .acquiring), 0)
    for _ in 0..<3 { inFlight.wait() }
    for _ in 0..<3 { inFlight.signal() }

    // After the last submit, one tick takes each source's latest frame.
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    for source in sources {
      let latest = try XCTUnwrap(source.latestFrame)
      XCTAssertEqual(renderer.frame(for: source)?.id, latest.id, "the renderer holds the latest frame")
      XCTAssertEqual(renderer.feed(for: source)?.hasFocusMask(for: latest), true, "and analysed it")
    }
    let submits = totalSubmits.load(ordering: .relaxed)
    XCTAssertGreaterThan(submits, 10_000)
    XCTAssertGreaterThan(ticks, 10)
    let worst = Double(worstSubmit.load(ordering: .relaxed)) / 1e6
    print(
      "BENCH handoff: \(submits) submits from \(producers) threads during \(ticks) ticks; worst submit \(String(format: "%.3f", worst)) ms, worst tick \(String(format: "%.3f", Double(worstTick) / 1e6)) ms"
    )
    // A submit is a pointer swap under a lock held for one: scheduling noise aside, microseconds.
    XCTAssertLessThan(worst, 20, "a submit waited")
  }

  /// The source slot keeps only the latest frame: replaced frames are released at
  /// once unless a renderer drew them.
  func testLatestFrameWinsAndReleasesTheRest() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    weak var dropped: MTLTexture?
    try autoreleasepool {
      let a = try gpu.sdrFrame(width: 8, height: 8)
      dropped = a.luma
      source.submit(a)
      source.submit(try gpu.sdrFrame(width: 8, height: 8, seed: 1))
    }
    XCTAssertNil(dropped, "a frame replaced before any draw is not kept")
    XCTAssertEqual(source.sequence, 2)
    source.clear()
    XCTAssertNil(source.latestFrame)
    XCTAssertEqual(source.sequence, 3)
  }

  /// Settings edits from another thread while the display thread ticks.
  func testConcurrentEditsAreConsistent() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let surface = MonitorSurface(source: source)
    let scene = MonitorScene(surfaces: [surface])
    let renderer = MonitorRenderer(engine: gpu.engine, scene: scene)
    let target = gpu.texture(.bgra8Unorm, 32, 18)
    let done = Atomic<Bool>(false)
    let editor = Thread {
      var i = 0
      while !done.load(ordering: .relaxed) {
        surface.updateState { $0.display.brightness = Double(i % 100) / 100 }
        scene.headroom = Double(1 + i % 4)
        i += 1
      }
    }
    editor.start()
    for _ in 0..<200 {
      try renderer.update()
      let cb = gpu.queue.makeCommandBuffer()!
      try renderer.encode(target: target, into: cb)
      cb.commit()
      cb.waitUntilScheduled()
    }
    done.store(true, ordering: .relaxed)
    while editor.isExecuting { usleep(100) }
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    let reference = gpu.engine.makePass()
    try reference.prepare(
      frame: source.latestFrame!, feed: gpu.engine.makeFeed(), state: surface.state,
      viewport: MonitorViewport(width: 32, height: 18), targetPixelFormat: .bgra8Unorm,
      into: gpu.queue.makeCommandBuffer()!)
    XCTAssertEqual(
      renderer.pass(for: surface)?.currentParameters.display, reference.currentParameters.display,
      "the renderer ends on the last edit")
    XCTAssertEqual(renderer.headroom, scene.headroom)
  }
}

extension HandoffTests {
  /// Two threads editing different settings at once: no edit is lost.
  func testConcurrentUpdateStateLosesNoEdit() {
    let surface = MonitorSurface(source: MonitorSource())
    let group = DispatchGroup()
    for t in 0..<2 {
      group.enter()
      Thread.detachNewThread {
        for _ in 0..<500 {
          surface.updateState { s in
            if t == 0 { s.guides.squareGridRows = min(16, s.guides.squareGridRows + 1) } else { s.zebras[0].level -= 0.1 }
          }
        }
        group.leave()
      }
    }
    group.wait()
    XCTAssertEqual(surface.state.guides.squareGridRows, 16)
    XCTAssertEqual(surface.state.zebras[0].level, 95 - 50, accuracy: 1e-6)
  }
}
