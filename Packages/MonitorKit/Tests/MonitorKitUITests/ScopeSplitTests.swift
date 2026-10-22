import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import XCTest

@testable import MonitorKitUI

/// Scopes off the pictures' critical path, the host's scope rate, hidden
/// (statistics-only) scopes and the scene's clean switch.
final class ScopeSplitTests: XCTestCase {
  struct Rig {
    let source: MonitorSource
    let surface: MonitorSurface
    let overlay: MonitorScopeOverlay
    let renderer: MonitorRenderer
  }

  func rig(_ gpu: UIGPU, state: MonitorState = MonitorState(), interval: Double = 0, hidden: Bool = false) throws -> Rig {
    let source = MonitorSource()
    let surface = MonitorSurface(source: source, state: state)
    let overlay = MonitorScopeOverlay(
      source: source, settings: ScopeSettings(kind: .waveform),
      region: MonitorRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5), isHidden: hidden, accumulationInterval: interval)
    let renderer = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(surfaces: [surface], scopes: [overlay]), scopeEngine: try gpu.scopeEngine())
    return Rig(source: source, surface: surface, overlay: overlay, renderer: renderer)
  }

  func generation(_ r: Rig) -> UInt32 { r.renderer.accumulator(for: r.overlay)?.generation ?? 0 }

  /// `encodePictures` accumulates nothing (its command buffer never waits for the
  /// scopes); `encodeScopes` does, and the next draw shows the new bins: the
  /// same pixels as the all-in-one encode.
  func testSplitEncodeDrawsTheSameAfterOneTick() throws {
    let gpu = try requireGPU()
    let split = try rig(gpu), whole = try rig(gpu)
    let frame = try gpu.sdrFrame(width: 96, height: 54)
    split.source.submit(frame)
    whole.source.submit(frame)
    let a = gpu.texture(.bgra8Unorm, 128, 72), b = gpu.texture(.bgra8Unorm, 128, 72)
    try whole.renderer.update()
    try gpu.run { try whole.renderer.encode(target: b, into: $0) }

    try split.renderer.update()
    try gpu.run { try split.renderer.encodePictures(target: a, into: $0) }
    XCTAssertEqual(generation(split), 0, "the pictures' buffer accumulates nothing")
    XCTAssertTrue(split.renderer.scopesDue)
    XCTAssertFalse(split.renderer.needsDisplay(width: 128, height: 72, pixelFormat: .bgra8Unorm))
    var encoded = false
    try gpu.run { encoded = split.renderer.encodeScopes(into: $0) }
    XCTAssertTrue(encoded)
    XCTAssertEqual(generation(split), 1)
    XCTAssertFalse(split.renderer.scopesDue)
    XCTAssertTrue(
      split.renderer.needsDisplay(width: 128, height: 72, pixelFormat: .bgra8Unorm), "new bins are drawn next tick")
    try gpu.run { XCTAssertFalse(split.renderer.encodeScopes(into: $0)) }

    try split.renderer.update()
    try gpu.run { try split.renderer.encodePictures(target: a, into: $0) }
    XCTAssertEqual(Texels(a), Texels(b))
  }

  /// The split on Metal 4: two submissions, the same pixels.
  func testSplitEncodeOnMetal4() throws {
    let gpu = try requireGPU()
    let mtl4 = try MTL4Host(gpu)
    let split = try rig(gpu), whole = try rig(gpu)
    let frame = try gpu.sdrFrame(width: 96, height: 54)
    frame.addResidency(to: mtl4.host)
    split.source.submit(frame)
    whole.source.submit(frame)
    let a = gpu.texture(.bgra8Unorm, 128, 72), b = gpu.texture(.bgra8Unorm, 128, 72)
    mtl4.resident(a)
    try whole.renderer.update()
    try gpu.run { try whole.renderer.encode(target: b, into: $0) }
    try split.renderer.update()
    try mtl4.run { try split.renderer.encodePictures(target: a, into: $0) }
    XCTAssertEqual(generation(split), 0)
    try mtl4.run { XCTAssertTrue(split.renderer.encodeScopes(into: $0)) }
    try split.renderer.update()
    try mtl4.run { try split.renderer.encodePictures(target: a, into: $0) }
    XCTAssertEqual(Texels(a), Texels(b))
  }

  /// A convenience view presenting a drawable commits the scopes after the
  /// pictures, and watches the scope buffer (the last one, which reads the frame
  /// too) for completion. Offscreen it accumulates first: a snapshot shows its
  /// own frame's scopes.
  @MainActor
  func testViewCommitsScopesSecondAndWatchesThem() throws {
    let gpu = try requireGPU()
    let r = try rig(gpu)
    r.source.submit(try gpu.sdrFrame())
    let view = MonitorMetalView(
      engine: gpu.engine, scene: r.renderer.scene, mode: .convenience(queue: gpu.queue),
      scopeEngine: try gpu.scopeEngine())
    view.metalLayer.pixelFormat = .bgra8Unorm
    view.metalLayer.drawableSize = CGSize(width: 64, height: 36)
    let drawable = try XCTUnwrap(view.metalLayer.nextDrawable())
    view.driver.noteApplied(MonitorLayerColor(primaries: .rec709, kind: .sdr(.bt1886)))
    view.driver.tick(drawable: drawable, texture: drawable.texture, timestamp: 0, commandBuffer: nil)
    let scopes = try XCTUnwrap(view.driver.lastScopeBuffer, "a scope buffer after the pictures'")
    XCTAssertEqual(view.driver.probe.map { ObjectIdentifier($0) }, scopes, "the scope buffer is watched")
    XCTAssertEqual(view.renderer.accumulator(for: r.overlay)?.generation, 1)
    XCTAssertEqual(view.drawCount, 1)
    try gpu.run { _ in }

    let snapshot = gpu.texture(.bgra8Unorm, 64, 36), reference = gpu.texture(.bgra8Unorm, 64, 36)
    let other = try rig(gpu)
    let still = MonitorMetalView(
      engine: gpu.engine, scene: other.renderer.scene, mode: .convenience(queue: gpu.queue),
      scopeEngine: try gpu.scopeEngine())
    let frame = try gpu.sdrFrame()
    other.source.submit(frame)
    still.drawOffscreen(into: snapshot)
    XCTAssertNil(still.driver.lastScopeBuffer)
    try gpu.run { _ in }
    let whole = try rig(gpu)
    whole.source.submit(frame)
    try whole.renderer.update()
    try gpu.run { try whole.renderer.encode(target: reference, into: $0) }
    XCTAssertEqual(Texels(snapshot), Texels(reference), "the snapshot's scopes are its own frame's")
  }

  /// Once a held-back frame is gone (the source cleared), nothing is due: the
  /// renderer does not redraw every tick.
  func testAClearedSourceLeavesNoScopeDue() throws {
    let gpu = try requireGPU()
    let r = try rig(gpu, interval: 0.05)
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    for seed in 0..<2 {
      r.source.submit(try gpu.sdrFrame(seed: UInt8(seed)))
      try r.renderer.update()
      try gpu.run { try r.renderer.encode(target: target, into: $0) }
    }
    XCTAssertEqual(generation(r), 1, "the second frame is held back")
    r.source.clear()
    try r.renderer.update()
    try gpu.run { try r.renderer.encode(target: target, into: $0) }
    Thread.sleep(forTimeInterval: 0.08)
    XCTAssertFalse(try r.renderer.update())
    XCTAssertFalse(try r.renderer.update())
    XCTAssertFalse(r.renderer.scopesDue)
  }

  /// An interval holds back new frames (settings edits still accumulate at once),
  /// and the latest held-back frame is accumulated once it passed.
  func testAccumulationIntervalSpacesAccumulations() throws {
    let gpu = try requireGPU()
    let r = try rig(gpu, interval: 3600)
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    func tick(_ seed: UInt8?) throws -> Bool {
      if let seed { r.source.submit(try gpu.sdrFrame(seed: seed)) }
      let changed = try r.renderer.update()
      try gpu.run { try r.renderer.encode(target: target, into: $0) }
      return changed
    }
    _ = try tick(0)
    XCTAssertEqual(generation(r), 1)
    _ = try tick(1)
    _ = try tick(2)
    XCTAssertEqual(generation(r), 1, "frames inside the interval are not accumulated")
    r.overlay.settings.waveformMode = .rgbParade
    _ = try tick(nil)
    XCTAssertEqual(generation(r), 2, "a settings edit accumulates at once")

    r.overlay.accumulationInterval = 0.05
    _ = try tick(nil)
    _ = try tick(3)
    XCTAssertEqual(generation(r), 2)
    Thread.sleep(forTimeInterval: 0.08)
    XCTAssertTrue(try tick(nil), "the held-back frame is due: the tick redraws")
    XCTAssertEqual(generation(r), 3, "and accumulates it with no newer frame")
    XCTAssertFalse(try tick(nil))
    XCTAssertEqual(generation(r), 3)
    r.overlay.accumulationInterval = .nan
    XCTAssertEqual(r.overlay.accumulationInterval, 0)
  }

  /// A hidden scope is measured, never drawn, and its statistics reach the UI.
  func testHiddenScopeMeasuresWithoutDrawing() throws {
    let gpu = try requireGPU()
    let r = try rig(gpu, hidden: true)
    let plain = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [r.surface]))
    let a = gpu.texture(.bgra8Unorm, 64, 36), b = gpu.texture(.bgra8Unorm, 64, 36)
    for seed in 0..<2 {
      r.source.submit(try gpu.sdrFrame(seed: UInt8(seed)))
      try r.renderer.update()
      try gpu.run { try r.renderer.encode(target: a, into: $0) }
    }
    try plain.update()
    try gpu.run { try plain.encode(target: b, into: $0) }
    XCTAssertEqual(generation(r), 2, "measured every frame")
    XCTAssertEqual(Texels(a), Texels(b), "drawn nowhere")
    let reader = try XCTUnwrap(r.overlay.statisticsReader)
    XCTAssertTrue(reader === r.renderer.accumulator(for: r.overlay)?.statisticsReader)
    let stats = try XCTUnwrap(reader.statistics)
    XCTAssertEqual(stats.pixelCount, 64 * 36)
    r.overlay.isHidden = false
    try r.renderer.update()
    try gpu.run { try r.renderer.encode(target: a, into: $0) }
    XCTAssertNotEqual(Texels(a), Texels(b), "shown again")
  }

  /// The scene's clean switch: every surface clean, no scope drawn and the
  /// visible scopes' accumulations stopped; the surfaces' states untouched.
  func testCleanSceneHidesEveryOverlay() throws {
    let gpu = try requireGPU()
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 50)
    state.guides.enabled = true
    state.focus.enabled = true
    let r = try rig(gpu, state: state)
    var cleanState = state
    cleanState.clean = true
    let reference = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: r.source, state: cleanState)]))
    let a = gpu.texture(.bgra8Unorm, 64, 36), b = gpu.texture(.bgra8Unorm, 64, 36)
    r.source.submit(try gpu.sdrFrame())
    try r.renderer.update()
    try gpu.run { try r.renderer.encode(target: a, into: $0) }
    XCTAssertEqual(generation(r), 1)
    let dressed = Texels(a)

    r.renderer.scene.clean = true
    XCTAssertTrue(try r.renderer.update())
    r.source.submit(try gpu.sdrFrame(seed: 9))
    try r.renderer.update()
    try gpu.run { try r.renderer.encode(target: a, into: $0) }
    try reference.update()
    try gpu.run { try reference.encode(target: b, into: $0) }
    XCTAssertEqual(Texels(a), Texels(b), "the clean picture alone")
    XCTAssertEqual(generation(r), 1, "a visible scope stops accumulating")
    XCTAssertFalse(r.surface.status.isActive(.focusPeaking))
    XCTAssertFalse(r.surface.state.clean, "the surface's own state is untouched")
    XCTAssertNil(r.renderer.feed(for: r.source)?.focusMask, "no analysis while clean")

    r.renderer.scene.clean = false
    r.source.submit(try gpu.sdrFrame())
    try r.renderer.update()
    try gpu.run { try r.renderer.encode(target: a, into: $0) }
    XCTAssertEqual(generation(r), 2)
    XCTAssertEqual(Texels(a), dressed, "restored")
  }
}
