import Metal
import XCTest

@testable import MonitorKit

/// Freeze: a compute copy of the frame's planes into feed-owned textures.
final class FreezeTests: XCTestCase {
  static let layouts: [PixelLayout] = [
    .v210, .uyvy8, .yuyv8, .nv12, .p010, .biplanar(.s422, bitDepth: 10), .biplanar(.s444, bitDepth: 16), .bgra8,
    .rgb10a2, .rgb(bitDepth: 16, float: false), .rgba16Float, .rgba32Float,
  ]

  func source(_ layout: PixelLayout, seed: UInt64) -> SyntheticFrame {
    SyntheticFrame.random(layout, width: 70, height: 38, seed: seed)
  }

  /// The frozen frame draws, decodes and analyses exactly like the live one, in
  /// every layout (odd sizes, so partial packed groups and chroma sites are copied).
  func testFrozenFrameIsIdenticalToTheLiveFrame() throws {
    let gpu = try requireGPU()
    var state = MonitorState()
    everyTool(&state)
    for layout in Self.layouts {
      let live = try source(layout, seed: 21).frame(gpu, signal: SignalDescription(range: layout.isRGB ? .full : .legal))
      let feed = gpu.engine.makeFeed()
      var frozen: MonitorFrame?
      try gpu.run { frozen = try feed.freeze(live, into: $0) }
      let copy = try XCTUnwrap(frozen)
      XCTAssertNotEqual(copy.id, live.id)
      XCTAssertEqual(feed.frozenFrame?.id, copy.id)
      XCTAssertEqual(gpu.decode(copy), gpu.decode(live), "\(layout) decode")
      let a = try gpu.render(live, state: state, width: 50, height: 30, analyze: true)
      let b = try gpu.render(copy, state: state, width: 50, height: 30, analyze: true)
      XCTAssertEqual(a.values, b.values, "\(layout) picture")
      let liveFeed = gpu.engine.makeFeed()
      try gpu.run { try liveFeed.analyze(live, focus: state.focus, into: $0) }
      try gpu.run { try feed.analyze(copy, focus: state.focus, into: $0) }
      XCTAssertEqual(gpu.readMask(liveFeed), gpu.readMask(feed), "\(layout) focus mask")
    }
  }

  /// Once the copy's command buffer completes, the host may refill the source
  /// texture: the frozen picture does not change.
  func testSourceCanBeReusedAfterTheCopyCompletes() throws {
    let gpu = try requireGPU()
    let picture = source(.v210, seed: 1)
    let live = try picture.frame(gpu, signal: .rec709)
    let feed = gpu.engine.makeFeed()
    var frozen: MonitorFrame?
    try gpu.run { frozen = try feed.freeze(live, into: $0) }
    let copy = try XCTUnwrap(frozen)
    let before = try gpu.render(copy, state: MonitorState())
    // Overwrite the source with another picture.
    let other = source(.v210, seed: 2)
    let texture = try XCTUnwrap(live.packed)
    let rows = (0..<other.height).flatMap { other.row(plane: 0, $0) }
    rows.withUnsafeBytes {
      texture.replace(
        region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: rows.count / other.height)
    }
    XCTAssertNotEqual(try gpu.render(live, state: MonitorState()).values, before.values, "the source changed")
    XCTAssertEqual(try gpu.render(copy, state: MonitorState()).values, before.values, "the frozen frame did not")
  }

  /// Planes are allocated once per size and format and reused; memory is reported,
  /// released on request, and replaced on a size or layout change.
  func testPlanesAreReusedAndCounted() throws {
    let gpu = try requireGPU()
    let feed = gpu.engine.makeFeed()
    XCTAssertEqual(feed.persistentMemoryBytes, 0)
    let a = try source(.p010, seed: 1).frame(gpu, signal: .rec709)
    let b = try source(.p010, seed: 2).frame(gpu, signal: .rec709)
    try gpu.run { _ = try feed.freeze(a, into: $0) }
    let created = gpu.engine.resourcesCreated
    let bytes = feed.persistentMemoryBytes
    // Luma r16 70×38 and chroma rg16 35×19, at least.
    XCTAssertGreaterThanOrEqual(bytes, 70 * 38 * 2 + 35 * 19 * 4)
    for _ in 0..<5 { try gpu.run { _ = try feed.freeze(b, into: $0) } }
    XCTAssertEqual(gpu.engine.resourcesCreated, created, "repeated freezes of one size allocate nothing")
    XCTAssertEqual(feed.persistentMemoryBytes, bytes)
    // Freezing the frozen frame returns it.
    let frozen = try XCTUnwrap(feed.frozenFrame)
    try gpu.run { XCTAssertEqual(try feed.freeze(frozen, into: $0).id, frozen.id) }
    XCTAssertEqual(gpu.engine.resourcesCreated, created)
    // A single-plane layout drops the chroma plane.
    let packed = try source(.v210, seed: 3).frame(gpu, signal: .rec709)
    try gpu.run { _ = try feed.freeze(packed, into: $0) }
    XCTAssertEqual(feed.persistentMemoryBytes, try XCTUnwrap(feed.frozenFrame?.packed).allocatedSize)
    feed.unfreeze(keepingMemory: true)
    XCTAssertNil(feed.frozenFrame)
    XCTAssertGreaterThan(feed.persistentMemoryBytes, 0, "kept for the next freeze")
    // By default unfreezing releases the planes.
    try gpu.run { _ = try feed.freeze(packed, into: $0) }
    feed.unfreeze()
    XCTAssertEqual(feed.persistentMemoryBytes, 0)
    try gpu.run { _ = try feed.freeze(packed, into: $0) }
    feed.unfreeze(releasingMemory: true)
    XCTAssertEqual(feed.persistentMemoryBytes, 0)
  }

  /// One compute pass, encoded only: no commit, no wait (the source scan in
  /// `ContractTests` checks there is no blit encoder anywhere).
  func testFreezeEncodesOnly() throws {
    let gpu = try requireGPU()
    let frame = try source(.nv12, seed: 4).frame(gpu, signal: .rec709)
    let feed = gpu.engine.makeFeed()
    let cb = try XCTUnwrap(gpu.queue.makeCommandBuffer())
    _ = try feed.freeze(frame, into: cb)
    XCTAssertEqual(cb.status, .notEnqueued)
    cb.commit()
    cb.waitUntilCompleted()
    XCTAssertNil(cb.error)
  }
}
