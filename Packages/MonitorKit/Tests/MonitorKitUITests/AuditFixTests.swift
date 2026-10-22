import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import XCTest

@testable import MonitorKitUI

/// Regressions from the second UI audit: focus masks freed when peaking goes off,
/// a resubmitted id on new textures, clean scenes and hidden scopes.
final class AuditFixTests: XCTestCase {
  func peaking(_ sensitivity: Double = 0.5) -> MonitorState {
    var s = MonitorState()
    s.focus.enabled = true
    s.focus.sensitivity = sensitivity
    s.focus.opacity = 1
    return s
  }

  /// A vertical-stripe pattern: strong edges every 4 pixels.
  func edgeFrame(_ gpu: UIGPU, width: Int = 64, height: Int = 36) throws -> MonitorFrame {
    let t = gpu.texture(.bgra8Unorm, width, height, usage: [.shaderRead])
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let v: UInt8 = (x / 4) % 2 == 0 ? 20 : 235
        let i = (y * width + x) * 4
        bytes[i] = v
        bytes[i + 1] = v
        bytes[i + 2] = v
        bytes[i + 3] = 255
      }
    }
    t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return try MonitorFrame(
      layout: .bgra8, width: width, height: height, luma: t,
      signal: SignalDescription(range: .full, encoding: .display(.bt709)))
  }

  func flatFrame(_ gpu: UIGPU, width: Int = 64, height: Int = 36) throws -> MonitorFrame {
    let t = gpu.texture(.bgra8Unorm, width, height, usage: [.shaderRead])
    let bytes = [UInt8](repeating: 128, count: width * height * 4)
    t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return try MonitorFrame(
      layout: .bgra8, width: width, height: height, luma: t,
      signal: SignalDescription(range: .full, encoding: .display(.bt709)))
  }

  /// Draws `n` new frames of `source`, waiting for each.
  func drawFrames(_ n: Int, _ gpu: UIGPU, _ renderer: MonitorRenderer, _ source: MonitorSource, _ target: MTLTexture)
    throws
  {
    for i in 0..<n {
      source.submit(try gpu.sdrFrame(width: target.width, height: target.height, seed: UInt8(i)))
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
    }
  }

  /// Peaking turned off (or the surface made clean) frees the main feed's focus
  /// mask once the GPU work that read it is done: no 8 MB per 4K source held for
  /// the renderer's lifetime.
  func testFocusMaskIsFreedWhenPeakingGoesOff() throws {
    let gpu = try requireGPU()
    for clean in [false, true] {
      let source = MonitorSource()
      let surface = MonitorSurface(source: source, state: peaking())
      let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [surface]))
      let target = gpu.texture(.bgra8Unorm, 64, 36)
      let baseline = renderer.persistentMemoryBytes
      weak var mask: MTLTexture?
      try autoreleasepool {
        try drawFrames(2, gpu, renderer, source, target)
        mask = renderer.feed(for: source)?.focusMask
      }
      XCTAssertNotNil(mask)
      XCTAssertGreaterThan(renderer.persistentMemoryBytes, baseline)
      let withMask = renderer.persistentMemoryBytes
      surface.updateState { if clean { $0.clean = true } else { $0.focus.enabled = false } }
      try autoreleasepool { try drawFrames(6, gpu, renderer, source, target) }
      XCTAssertNil(renderer.feed(for: source)?.focusMask, "clean \(clean)")
      XCTAssertLessThan(renderer.persistentMemoryBytes, withMask, "clean \(clean)")
      XCTAssertNil(mask, "the released mask is deallocated, clean \(clean)")
      // Turning peaking back on makes a new one.
      surface.updateState { $0.clean = false; $0.focus.enabled = true }
      try drawFrames(1, gpu, renderer, source, target)
      XCTAssertNotNil(renderer.feed(for: source)?.focusMask)
      XCTAssertTrue(surface.status.isActive(.focusPeaking))
    }
  }

  /// An extra feed that no surface claims while a later one is still claimed
  /// (not at the end of the list, so it is not dropped) frees its mask too.
  func testAnUnclaimedMiddleFeedFreesItsMask() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    let regions = (0..<3).map { MonitorRegion(x: Double($0) / 3, y: 0, width: 1.0 / 3, height: 1) }
    let surfaces = (0..<3).map {
      MonitorSurface(source: source, state: peaking([0.2, 0.5, 0.9][$0]), region: regions[$0])
    }
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: surfaces))
    let target = gpu.texture(.bgra8Unorm, 96, 36)
    try drawFrames(2, gpu, renderer, source, target)
    XCTAssertEqual(renderer.feedCount(for: source), 3)
    weak var middle: MTLTexture?
    autoreleasepool { middle = renderer.feed(for: surfaces[1])?.focusMask }
    XCTAssertNotNil(middle)
    let before = renderer.persistentMemoryBytes
    surfaces[1].updateState { $0.focus.enabled = false }
    try autoreleasepool { try drawFrames(6, gpu, renderer, source, target) }
    XCTAssertLessThan(renderer.persistentMemoryBytes, before)
    XCTAssertNil(middle)
    XCTAssertTrue(surfaces[0].status.isActive(.focusPeaking))
    XCTAssertTrue(surfaces[2].status.isActive(.focusPeaking))
  }

  /// A frame resubmitted with the same `id` on new textures is analysed again:
  /// peaking shows the new picture's edges, as it does under a fresh id.
  func testReusedIDOnNewTexturesReanalysesTheMask() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    let surface = MonitorSurface(source: source, state: peaking(0.9))
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [surface]))
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    let flat = try flatFrame(gpu)
    source.submit(flat)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertEqual(renderer.feed(for: source)?.analysisCount, 1)

    var edges = try edgeFrame(gpu)
    edges.id = flat.id
    source.submit(edges)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertTrue(renderer.frame(for: source)?.luma === edges.luma)
    XCTAssertEqual(renderer.feed(for: source)?.analysisCount, 2, "the mask is recomputed for the new picture")

    let reference = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source, state: peaking(0.9))]))
    let fresh = gpu.texture(.bgra8Unorm, 64, 36)
    source.submit(try edgeFrame(gpu))
    try reference.update()
    try gpu.run { try reference.encode(target: fresh, into: $0) }
    XCTAssertEqual(Texels(target), Texels(fresh), "the same peaking as the same picture under a fresh id")
    let plain = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]))
    let unpeaked = gpu.texture(.bgra8Unorm, 64, 36)
    try plain.update()
    try gpu.run { try plain.encode(target: unpeaked, into: $0) }
    XCTAssertNotEqual(Texels(fresh), Texels(unpeaked), "the edges are peaked")
  }
}
