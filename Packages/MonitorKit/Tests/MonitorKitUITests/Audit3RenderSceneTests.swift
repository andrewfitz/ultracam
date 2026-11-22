// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import XCTest

@testable import MonitorKitUI

/// Scene reconciliation: what a surface or scope handle publishes after it
/// leaves the scene and comes back, and a seeded run of membership edits.
final class Audit3RenderSceneTests: XCTestCase {
  /// A surface drawn, removed, its source cleared, then added back: the new
  /// state used to start as "nothing published", so the viewport, layout and
  /// status of the old draw stayed on the handle while the tile showed black.
  func testReaddedSurfaceClearsWhatItsHandleStillHolds() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    var state = MonitorState()
    state.zebras[0].enabled = true
    let surface = MonitorSurface(source: source, state: state)
    let scene = MonitorScene(surfaces: [surface])
    let renderer = MonitorRenderer(engine: gpu.engine, scene: scene)
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    func draw() throws {
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
    }
    try draw()
    XCTAssertNotNil(surface.viewport)
    XCTAssertNotNil(surface.layout)
    XCTAssertNotEqual(surface.status, MonitorStatus())
    _ = renderer.takeStatusChanges()
    scene.surfaces = []
    try draw()
    source.clear()
    scene.surfaces = [surface]
    try draw()
    XCTAssertNil(surface.viewport, "no frame: nothing drawn")
    XCTAssertNil(surface.layout)
    XCTAssertEqual(surface.status, MonitorStatus())
    XCTAssertTrue(renderer.takeStatusChanges())
    // And a frame again publishes again.
    source.submit(try gpu.sdrFrame(seed: 2))
    try draw()
    XCTAssertEqual(surface.viewport, MonitorRegion.full.viewport(width: 64, height: 36))
    XCTAssertNotNil(surface.layout)
  }

  /// The same for a scope overlay: a re-added overlay that does not draw
  /// clears the viewport its handle kept.
  func testReaddedScopeClearsTheViewportItsHandleStillHolds() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let overlay = MonitorScopeOverlay(source: source, settings: ScopeSettings(kind: .waveform))
    let scene = MonitorScene(scopes: [overlay])
    let renderer = MonitorRenderer(engine: gpu.engine, scene: scene, scopeEngine: try gpu.scopeEngine())
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    func draw() throws {
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
    }
    try draw()
    XCTAssertNotNil(overlay.viewport)
    scene.scopes = []
    try draw()
    source.clear()
    scene.scopes = [overlay]
    try draw()
    XCTAssertNil(overlay.viewport)
  }

  /// One scene in two views: a second renderer whose target is too small to
  /// draw the tile (a view ticking at zero bounds gets a 1x1 drawable) must not
  /// clear what the first one published, nor leave the first unable to publish.
  func testSecondRendererThatDrawsNothingLeavesTheFirstsPublication() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    var state = MonitorState()
    state.zebras[0].enabled = true
    let region = MonitorRegion(x: 0.7, y: 0, width: 0.3, height: 1)
    let surface = MonitorSurface(source: source, state: state, region: region)
    let overlay = MonitorScopeOverlay(source: source, settings: ScopeSettings(kind: .waveform), region: region)
    let scene = MonitorScene(surfaces: [surface], scopes: [overlay])
    let a = MonitorRenderer(engine: gpu.engine, scene: scene, scopeEngine: try gpu.scopeEngine())
    let big = gpu.texture(.bgra8Unorm, 64, 36), tiny = gpu.texture(.bgra8Unorm, 1, 1)
    func draw(_ r: MonitorRenderer, _ t: MTLTexture) throws {
      try r.update()
      try gpu.run { try r.encode(target: t, into: $0) }
    }
    try draw(a, big)
    let viewport = try XCTUnwrap(surface.viewport)
    let status = surface.status
    XCTAssertNotNil(surface.layout)
    XCTAssertNotNil(overlay.viewport)
    let b = MonitorRenderer(engine: gpu.engine, scene: scene, scopeEngine: try gpu.scopeEngine())
    XCTAssertNil(region.viewport(width: 1, height: 1), "nothing of the tile in B's target")
    try draw(b, tiny)
    XCTAssertEqual(surface.viewport, viewport, "B drew nothing and left A's publication")
    XCTAssertNotNil(surface.layout)
    XCTAssertEqual(surface.status, status)
    XCTAssertEqual(overlay.viewport, region.viewport(width: 64, height: 36))
    // A keeps publishing its own draws.
    source.submit(try gpu.sdrFrame(seed: 3))
    try draw(a, big)
    try draw(b, tiny)
    XCTAssertEqual(surface.viewport, viewport)
    XCTAssertNotNil(surface.layout)
    XCTAssertEqual(overlay.viewport, region.viewport(width: 64, height: 36))
  }

  /// What a renderer that no longer exists published is cleared by the next
  /// one that draws nothing of the tile.
  func testPublicationOfADestroyedRendererIsCleared() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let surface = MonitorSurface(source: source)
    let overlay = MonitorScopeOverlay(source: source, settings: ScopeSettings(kind: .histogram))
    let scene = MonitorScene(surfaces: [surface], scopes: [overlay])
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    try autoreleasepool {
      let a = MonitorRenderer(engine: gpu.engine, scene: scene, scopeEngine: try gpu.scopeEngine())
      try a.update()
      try gpu.run { try a.encode(target: target, into: $0) }
    }
    XCTAssertNotNil(surface.viewport)
    XCTAssertNotNil(overlay.viewport)
    source.clear()
    let c = MonitorRenderer(engine: gpu.engine, scene: scene, scopeEngine: try gpu.scopeEngine())
    try c.update()
    try gpu.run { try c.encode(target: target, into: $0) }
    XCTAssertNil(surface.viewport)
    XCTAssertNil(surface.layout)
    XCTAssertNil(overlay.viewport)
  }

  /// Seeded membership, frame, region, clean and cadence edits, each drawn
  /// (whole or split) and reported complete: every member handle publishes
  /// exactly what this renderer drew, nothing is held after completion and no
  /// feeds pile up.
  func testSeededMembershipEditsKeepHandlesConsistent() throws {
    let gpu = try requireGPU()
    var rng = SplitMix64(seed: 0x4D4B_5549)
    let sources = (0..<3).map { _ in MonitorSource() }
    var surfaces: [MonitorSurface] = []
    var scopes: [MonitorScopeOverlay] = []
    for (i, s) in sources.enumerated() {
      s.submit(try gpu.sdrFrame(seed: UInt8(i)))
      var st = MonitorState()
      st.focus.enabled = i != 1
      let third = 1.0 / 3
      surfaces.append(
        MonitorSurface(
          source: s, state: st, region: MonitorRegion(x: Double(i) * third, y: 0, width: third, height: 1)))
      surfaces.append(MonitorSurface(source: s, region: MonitorRegion(x: 0, y: 0.5, width: 0.5, height: 0.5)))
      scopes.append(MonitorScopeOverlay(source: s, settings: ScopeSettings(kind: .waveform)))
      scopes.append(MonitorScopeOverlay(source: s, settings: ScopeSettings(kind: .histogram), isHidden: true))
    }
    let scene = MonitorScene()
    let renderer = MonitorRenderer(engine: gpu.engine, scene: scene, scopeEngine: try gpu.scopeEngine())
    let target = gpu.texture(.bgra8Unorm, 96, 54)
    for step in 0..<400 {
      switch Int.random(in: 0..<8, using: &rng) {
      case 0: scene.surfaces = surfaces.filter { _ in Bool.random(using: &rng) }
      case 1: scene.scopes = scopes.filter { _ in Bool.random(using: &rng) }
      case 2: sources.randomElement(using: &rng)!.clear()
      case 3: try sources.randomElement(using: &rng)!.submit(gpu.sdrFrame(seed: UInt8(step % 200)))
      case 4: scene.clean.toggle()
      case 5:
        let x = Double.random(in: -0.2...1, using: &rng), w = Double.random(in: 0...0.6, using: &rng)
        surfaces.randomElement(using: &rng)!.region = MonitorRegion(x: x, y: 0, width: w, height: 1)
      case 6: surfaces.randomElement(using: &rng)!.updateState { $0.focus.enabled.toggle() }
      default: scopes.randomElement(using: &rng)!.accumulationInterval = Bool.random(using: &rng) ? 0 : 0.001
      }
      try renderer.update()
      if Bool.random(using: &rng) {
        try gpu.run { try renderer.encode(target: target, into: $0) }
      } else {
        try gpu.run { try renderer.encodePictures(target: target, into: $0) }
        try gpu.run { renderer.encodeScopes(into: $0) }
      }
      renderer.noteCompleted(through: renderer.encodeCount)
      XCTAssertEqual(renderer.retiredCount, 0, "step \(step)")
      for s in scene.surfaces {
        let want = s.source.latestFrame == nil ? nil : s.region.viewport(width: 96, height: 54)
        XCTAssertEqual(s.viewport, want, "step \(step)")
        if want == nil { XCTAssertNil(s.layout, "step \(step)") }
      }
      for o in scene.scopes where o.source.latestFrame == nil || (scene.clean && !o.isHidden) {
        XCTAssertNil(o.viewport, "overlay, step \(step)")
      }
      for s in sources { XCTAssertLessThanOrEqual(renderer.feedCount(for: s), 2, "step \(step)") }
    }
    XCTAssertEqual(renderer.errorCount, 0, String(describing: renderer.lastError))
  }
}

/// A deterministic generator, so a failing step reproduces.
private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
