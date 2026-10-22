import AppKit
import Metal
import MonitorKit
import MonitorKitCore
import Synchronization
import XCTest

@testable import MonitorKitUI

/// A paused or hidden view releases its frames whenever its last GPU work
/// completes, in both modes; the link attaches to a parked render thread; the
/// headroom timer stops while paused; the draw counters are atomics.
@MainActor
final class ViewIdleTests: XCTestCase {
  func spin(_ seconds: Double, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
  }

  /// The GPU is still busy well past any fixed delay: the frames go once the
  /// idle marker's buffer completes, not never.
  func testPausedConvenienceViewReleasesWhenABusyGPUFinishes() throws {
    let gpu = try requireGPU()
    let queue = try XCTUnwrap(gpu.device.makeCommandQueue())
    let event = try XCTUnwrap(gpu.device.makeSharedEvent())
    let blocker = try XCTUnwrap(queue.makeCommandBuffer())
    blocker.encodeWaitForEvent(event, value: 1)
    blocker.commit()
    defer { event.signaledValue = 1 }

    let source = MonitorSource()
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]),
      mode: .convenience(queue: queue))
    let target = gpu.texture(.bgra8Unorm, 32, 18)
    weak var held: MTLTexture?
    try autoreleasepool {
      let f = try gpu.sdrFrame(width: 32, height: 18)
      held = f.luma
      source.submit(f)
      view.drawOffscreen(into: target)  // queued behind the blocker
      source.submit(try gpu.sdrFrame(width: 32, height: 18, seed: 1))
    }
    view.isPaused = true
    spin(0.6)
    XCTAssertNotNil(view.renderer.frame(for: source), "the GPU has not run the draw yet")
    XCTAssertNotNil(held)
    event.signaledValue = 1
    spin(3) { view.renderer.frame(for: source) == nil && held == nil }
    XCTAssertNil(view.renderer.frame(for: source))
    XCTAssertNil(held, "released once the marker completed")
    view.isPaused = false
    view.drawOffscreen(into: target)
    XCTAssertNotNil(view.renderer.frame(for: source))
    try gpu.run { _ in }
  }

  /// A host-driven view, paused before its host could report the last draw
  /// complete, releases the frame when the report arrives (from any thread).
  func testPausedHostDrivenViewReleasesOnTheHostsReport() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    let drawn = Mutex<(cb: MTLCommandBuffer?, index: UInt64)>((nil, 0))
    let queue = gpu.queue
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]),
      mode: .hostDriven { context in
        guard let cb = queue.makeCommandBuffer() else { return false }
        try? context.renderer.encode(target: context.texture, into: cb)
        let index = context.renderer.encodeCount
        cb.commit()
        drawn.withLock { $0 = (cb, index) }
        return true
      })
    let target = gpu.texture(.bgra8Unorm, 32, 18)
    weak var held: MTLTexture?
    try autoreleasepool {
      let f = try gpu.sdrFrame(width: 32, height: 18)
      held = f.luma
      source.submit(f)
      view.drawOffscreen(into: target)
      source.submit(try gpu.sdrFrame(width: 32, height: 18, seed: 1))
    }
    let index = drawn.withLock { d -> UInt64 in
      d.cb?.waitUntilCompleted()
      d.cb = nil
      return d.index
    }
    view.isPaused = true
    spin(0.3)
    XCTAssertNotNil(view.renderer.frame(for: source), "nothing reported the draw complete")
    let reporter = view.completionReporter
    Thread.detachNewThread { reporter.noteCompleted(through: index) }
    spin(2) { view.renderer.frame(for: source) == nil && held == nil }
    XCTAssertNil(view.renderer.frame(for: source))
    XCTAssertNil(held)
    XCTAssertEqual(reporter.completedIndex, index)
    reporter.noteCompleted(through: 0)
    XCTAssertEqual(reporter.completedIndex, index, "only larger values count")
  }

  /// A block queued for a render thread parked in `run()` with no timeout runs
  /// at once: the link is attached through a woken run loop.
  func testBlocksReachARenderThreadParkedWithoutATimeout() throws {
    final class Parked: Thread, @unchecked Sendable {
      nonisolated(unsafe) var runLoop: CFRunLoop?
      let ready = DispatchSemaphore(value: 0)
      override func main() {
        runLoop = CFRunLoopGetCurrent()
        RunLoop.current.add(Port(), forMode: .default)
        ready.signal()
        while !isCancelled { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
      }
    }
    let thread = Parked()
    thread.start()
    thread.ready.wait()
    let ran = Atomic<Bool>(false)
    let start = Date()
    MonitorDisplayDriver.perform(on: thread.runLoop!) { ran.store(true, ordering: .relaxed) }
    while !ran.load(ordering: .relaxed) && Date().timeIntervalSince(start) < 2 { usleep(1000) }
    XCTAssertTrue(ran.load(ordering: .relaxed))
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    thread.cancel()
    MonitorDisplayDriver.perform(on: thread.runLoop!) {}
  }

  /// The headroom timer runs only while the link does, with a tolerance.
  func testHeadroomTimerStopsWhilePaused() throws {
    let gpu = try requireGPU()
    let view = MonitorMetalView(engine: gpu.engine, mode: .convenience(queue: gpu.queue))
    view.updateHeadroomTimer(running: true)
    let timer = try XCTUnwrap(view.headroomTimer)
    XCTAssertTrue(timer.isValid)
    XCTAssertGreaterThan(timer.tolerance, 0)
    view.isPaused = true
    XCTAssertNil(view.headroomTimer)
    XCTAssertFalse(timer.isValid)
  }

  /// The public counters are read on the main thread while the link's thread
  /// writes them: atomics, so a draw on another thread is seen.
  func testCountersAreReadableFromAnotherThread() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]),
      mode: .convenience(queue: gpu.queue))
    let driver = view.driver
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    nonisolated(unsafe) let t = target
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      driver.tick(drawable: nil, texture: t, timestamp: 0, commandBuffer: nil)
      driver.tick(drawable: nil, texture: t, timestamp: 0, commandBuffer: nil)
      done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut { _ = view.drawCount + view.skippedCount }
    XCTAssertEqual(view.drawCount, 2, "an offscreen tick always draws")
    XCTAssertEqual(view.skippedCount, 0)
    try gpu.run { _ in }
  }
}
