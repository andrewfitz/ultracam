import AppKit
import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import SwiftUI
import XCTest

@testable import MonitorKitUI

/// The SwiftUI tier: several scopes in one renderer, a render thread for the
/// ticks, video-rate metadata outside the representable, clip % readouts.
@MainActor
final class SwiftUIAuditTests: XCTestCase {
  func metalView(in view: NSView) -> MonitorMetalView? {
    if let v = view as? MonitorMetalView { return v }
    for sub in view.subviews { if let v = metalView(in: sub) { return v } }
    return nil
  }

  /// Three scopes of one source in one view: one scene, tiled regions, one fused
  /// accumulation, and each scope's labels.
  func testScopeStackSharesOneRendererAndFusesItsScopes() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame(width: 96, height: 54))
    let kinds: [ScopeKind] = [.waveform, .vectorscope, .histogram]
    let settings = kinds.map { ScopeSettings(kind: $0) }
    let hosting = NSHostingView(
      rootView: ScopeStackView(
        engine: gpu.engine, scopeEngine: try gpu.scopeEngine(), source: source, settings: settings, queue: gpu.queue
      ).frame(width: 300, height: 100))
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
    hosting.layoutSubtreeIfNeeded()
    let view = try XCTUnwrap(metalView(in: hosting))
    let overlays = view.scene.scopes
    XCTAssertEqual(overlays.count, 3)
    XCTAssertEqual(overlays.map(\.region), ScopeStackView.regions(count: 3, axis: .horizontal))
    XCTAssertEqual(overlays.map(\.settings.kind), kinds)
    try gpu.run { view.drawOffscreen(into: gpu.texture(.bgra8Unorm, 300, 100), commandBuffer: $0) }
    XCTAssertEqual(view.renderer.scopeGroup(for: overlays[0])?.fusedMemberCount, 3, "accumulated together")
    XCTAssertTrue(view.renderer.scopeGroup(for: overlays[0]) === view.renderer.scopeGroup(for: overlays[2]))
    for o in overlays { XCTAssertFalse(o.graticule?.labels.isEmpty ?? true) }
    let vertical = ScopeStackView.regions(count: 2, axis: .vertical)
    XCTAssertEqual(vertical, [MonitorRegion(x: 0, y: 0, width: 1, height: 0.5), MonitorRegion(x: 0, y: 0.5, width: 1, height: 0.5)])
    XCTAssertTrue(ScopeStackView.regions(count: 0, axis: .horizontal).isEmpty)
  }

  /// MonitorView and ScopeView hand their display link to the host's run loop.
  func testViewsTakeARenderThreadRunLoop() throws {
    let gpu = try requireGPU()
    // Another thread's run loop stands in for a render thread's (no window: it never ticks).
    nonisolated(unsafe) var renderLoop: RunLoop?
    let ready = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      renderLoop = RunLoop.current
      ready.signal()
    }
    ready.wait()
    let rl = try XCTUnwrap(renderLoop)
    XCTAssertFalse(rl === RunLoop.main)
    let box = Box(MonitorState())
    let monitor = NSHostingView(
      rootView: MonitorView(engine: gpu.engine, source: MonitorSource(), state: box.binding, displayLinkRunLoop: rl))
    monitor.frame = NSRect(x: 0, y: 0, width: 64, height: 36)
    monitor.layoutSubtreeIfNeeded()
    XCTAssertTrue(try XCTUnwrap(metalView(in: monitor)).runLoop === rl)
    let scope = NSHostingView(
      rootView: ScopeView(
        engine: gpu.engine, scopeEngine: try gpu.scopeEngine(), source: MonitorSource(),
        settings: ScopeSettings(kind: .histogram), accumulationInterval: 0.5, displayLinkRunLoop: rl))
    scope.frame = NSRect(x: 0, y: 0, width: 64, height: 36)
    scope.layoutSubtreeIfNeeded()
    let scopeView = try XCTUnwrap(metalView(in: scope))
    XCTAssertTrue(scopeView.runLoop === rl)
    XCTAssertEqual(scopeView.scene.scopes.first?.accumulationInterval, 0.5)
  }

  /// The overlay reads a model's metadata itself.
  func testStatusOverlayReadsItsModel() {
    let model = MonitorOverlayModel(MonitorOverlayMetadata(timecode: "01:00:00:00"))
    let overlay = MonitorStatusOverlay(model: model)
    XCTAssertEqual(overlay.metadata.timecode, "01:00:00:00")
    model.metadata.timecode = "01:00:00:01"
    XCTAssertEqual(overlay.metadata.timecode, "01:00:00:01")
    XCTAssertEqual(MonitorStatusOverlay(metadata: MonitorOverlayMetadata(format: "HD")).metadata.format, "HD")
  }

  /// Clip % from a hidden scope's statistics: the picture's top code value in R
  /// (one column of 64) reads as 1.6% over.
  func testClipReadoutFromAHiddenScope() throws {
    let gpu = try requireGPU()
    XCTAssertEqual(ClipReadout.lines(nil).high, "Over –")
    XCTAssertEqual(ClipReadout.percent(0), "0.0%")
    XCTAssertEqual(ClipReadout.percent(0.0001), "<0.1%")
    XCTAssertEqual(ClipReadout.percent(0.5), "50.0%")
    XCTAssertEqual(ClipReadout.percent(2), "100.0%")
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    var settings = ScopeSettings(kind: .histogram)
    settings.stage = .source
    let overlay = MonitorScopeOverlay(source: source, settings: settings, isHidden: true)
    let renderer = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(scopes: [overlay]), scopeEngine: try gpu.scopeEngine())
    try renderer.update()
    try gpu.run { try renderer.encode(target: gpu.texture(.bgra8Unorm, 64, 36), into: $0) }
    let stats = try XCTUnwrap(overlay.statisticsReader?.statistics)
    XCTAssertEqual(stats.clippedHigh.x, 1.0 / 64, accuracy: 1e-6)
    let lines = ClipReadout.lines(stats)
    XCTAssertTrue(lines.high.hasPrefix("Over R 1.6% G "), lines.high)
    XCTAssertTrue(lines.low.hasPrefix("Under R 1.6% "), lines.low)
    _ = ClipReadout(overlay: overlay).body
  }
}
