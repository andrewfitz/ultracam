import AppKit
import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitUI

/// The real display link in a real (tiny) window. Opt-in, since it puts a window
/// on screen: MONITORKITUI_WINDOW_TESTS=1.
@MainActor
final class DisplayLinkTests: XCTestCase {
  func window(_ view: NSView) -> NSWindow {
    _ = NSApplication.shared
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let w = NSWindow(
      contentRect: NSRect(x: screen.minX + 8, y: screen.minY + 8, width: 96, height: 54), styleMask: [.borderless],
      backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.contentView = view
    w.orderFrontRegardless()
    return w
  }

  func spin(_ seconds: Double, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
  }

  func testDisplayLinkDrawsAndPresents() throws {
    guard ProcessInfo.processInfo.environment["MONITORKITUI_WINDOW_TESTS"] == "1" else {
      throw XCTSkip("opt-in: MONITORKITUI_WINDOW_TESTS=1 puts a small window on screen")
    }
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]),
      mode: .convenience(queue: gpu.queue))
    let w = window(view)
    defer { w.close() }
    spin(2) { view.drawCount >= 1 }
    XCTAssertGreaterThanOrEqual(view.drawCount, 1, "the link vended a drawable and the view drew")
    XCTAssertEqual(view.metalLayer.drawableSize.width, 96 * w.backingScaleFactor)
    // Nothing changes: ticks keep the picture on screen without drawing.
    let drawn = view.drawCount
    spin(0.3)
    XCTAssertEqual(view.drawCount, drawn)
    XCTAssertGreaterThan(view.skippedCount, 0)
    // A new frame from another thread is drawn on a following tick.
    let next = try gpu.sdrFrame(seed: 40)
    Thread.detachNewThread { source.submit(next) }
    spin(2) { view.drawCount > drawn }
    XCTAssertGreaterThan(view.drawCount, drawn)
    // HDR: the next tick re-tags the layer, then draws.
    source.submit(try gpu.pqFrame())
    spin(2) { view.metalLayer.pixelFormat == .rgba16Float && view.drawCount > drawn + 1 }
    XCTAssertEqual(view.metalLayer.pixelFormat, .rgba16Float)
    XCTAssertTrue(view.metalLayer.wantsExtendedDynamicRangeContent)
    XCTAssertGreaterThanOrEqual(view.headroom, 1)
    // Out of the window: the link stops.
    view.removeFromSuperview()
    let stopped = view.drawCount + view.skippedCount
    spin(0.2)
    XCTAssertEqual(view.drawCount + view.skippedCount, stopped)
  }

  /// Host mode on a link running on the host's own render thread.
  func testHostDrivenLinkOnARenderThread() throws {
    guard ProcessInfo.processInfo.environment["MONITORKITUI_WINDOW_TESTS"] == "1" else {
      throw XCTSkip("opt-in: MONITORKITUI_WINDOW_TESTS=1 puts a small window on screen")
    }
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    final class RenderThread: Thread, @unchecked Sendable {
      nonisolated(unsafe) var runLoop: RunLoop?
      let ready = DispatchSemaphore(value: 0)
      override func main() {
        runLoop = .current
        // A port keeps the run loop running until the thread is cancelled.
        RunLoop.current.add(Port(), forMode: .default)
        ready.signal()
        while !isCancelled { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
      }
    }
    let thread = RenderThread()
    thread.start()
    thread.ready.wait()
    defer { thread.cancel() }
    let calls = CallLog()
    let queue = gpu.queue
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]),
      mode: .hostDriven { context in
        calls.record(main: Thread.isMainThread, drawable: context.drawable != nil)
        guard context.needsDisplay, let drawable = context.drawable, let cb = queue.makeCommandBuffer() else {
          return false
        }
        try? context.renderer.encode(target: context.texture, into: cb)
        cb.present(drawable)
        cb.commit()
        return true
      }, displayLinkRunLoop: thread.runLoop!)
    let w = window(view)
    defer { w.close() }
    spin(2) { view.drawCount >= 1 }
    XCTAssertGreaterThanOrEqual(view.drawCount, 1)
    let log = calls.snapshot()
    XCTAssertGreaterThan(log.count, 0)
    XCTAssertFalse(log.main, "the host ran on its render thread")
    XCTAssertTrue(log.drawable)
    // The layer is re-tagged from the render thread (in its own transaction), then drawn.
    let drawn = view.drawCount
    source.submit(try gpu.pqFrame())
    spin(2) { view.metalLayer.pixelFormat == .rgba16Float && view.drawCount > drawn }
    XCTAssertEqual(view.metalLayer.pixelFormat, .rgba16Float)
    XCTAssertEqual(view.metalLayer.colorspace?.name as String?, CGColorSpace.itur_2100_PQ as String)
    XCTAssertGreaterThan(view.drawCount, drawn)
    // A host-chosen tag wins over the scene's.
    view.layerColorOverride = MonitorLayerColor(primaries: .displayP3, kind: .extendedLinear)
    spin(2) { view.metalLayer.colorspace?.name as String? == CGColorSpace.extendedLinearDisplayP3 as String }
    XCTAssertEqual(view.metalLayer.colorspace?.name as String?, CGColorSpace.extendedLinearDisplayP3 as String)
  }
}

final class CallLog: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0, main = false, drawable = false
  func record(main m: Bool, drawable d: Bool) {
    lock.withLock {
      count += 1
      main = main || m
      drawable = drawable || d
    }
  }
  func snapshot() -> (count: Int, main: Bool, drawable: Bool) { lock.withLock { (count, main, drawable) } }
}

/// CPU cost of a tick against the same library calls by hand.
final class TickBenchmarks: XCTestCase {
  func testTickCPUCost() throws {
    let gpu = try requireGPU()
    let sources = [MonitorSource(), MonitorSource()]
    let pools = try (0..<2).map { s in try (0..<4).map { try gpu.sdrFrame(width: 64, height: 36, seed: UInt8(s * 4 + $0)) } }
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 80)
    state.guides.enabled = true
    state.focus.enabled = true
    let surfaces = (0..<2).map {
      MonitorSurface(source: sources[$0], state: state, region: MonitorRegion(x: Double($0) / 2, y: 0, width: 0.5, height: 1))
    }
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: surfaces))
    let target = gpu.texture(.bgra8Unorm, 128, 36)
    let feeds = [gpu.engine.makeFeed(), gpu.engine.makeFeed()], passes = [gpu.engine.makePass(), gpu.engine.makePass()]
    let viewports = surfaces.map { $0.region.viewport(width: 128, height: 36)! }
    var tick: [Double] = [], idle: [Double] = [], byHand: [Double] = []
    for i in 0..<240 {
      let f = [pools[0][i % 4], pools[1][(i + 1) % 4]]
      sources[0].submit(f[0])
      sources[1].submit(f[1])
      var cb = gpu.queue.makeCommandBuffer()!
      var t0 = DispatchTime.now().uptimeNanoseconds
      try renderer.update()
      try renderer.encode(target: target, into: cb)
      tick.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
      cb.commit()
      t0 = DispatchTime.now().uptimeNanoseconds
      try renderer.update()
      _ = renderer.needsDisplay(width: 128, height: 36, pixelFormat: .bgra8Unorm)
      idle.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
      cb = gpu.queue.makeCommandBuffer()!
      t0 = DispatchTime.now().uptimeNanoseconds
      for k in 0..<2 {
        try feeds[k].analyze(f[k], focus: state.focus, into: cb)
        try passes[k].encode(frame: f[k], feed: feeds[k], state: state, target: target, viewport: viewports[k], clear: k == 0, into: cb)
      }
      byHand.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
      cb.commit()
      if i % 3 == 2 { cb.waitUntilCompleted() }
    }
    func median(_ v: [Double]) -> Double { v.dropFirst(20).sorted()[(v.count - 20) / 2] }
    let t = median(tick), h = median(byHand), z = median(idle)
    print(
      "BENCH MonitorRenderer CPU per tick, 2 surfaces with peaking: \(String(format: "%.1f", t)) µs median; the same calls by hand \(String(format: "%.1f", h)) µs; an idle tick \(String(format: "%.2f", z)) µs"
    )
    // Generous bounds: CPU timings on a shared machine are noisy.
    XCTAssertLessThan(t, h * 1.5 + 20, "the renderer's bookkeeping is a small fraction of the encode")
    XCTAssertLessThan(z, 10)
  }
}
