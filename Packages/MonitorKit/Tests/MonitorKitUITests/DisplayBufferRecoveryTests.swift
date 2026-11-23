// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import QuartzCore
import XCTest

@testable import MonitorKitUI

final class DisplayBufferRecoveryTests: XCTestCase {
  func testFailedBufferRecomputesFocusAndScopesWithoutANewFrame() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    var state = MonitorState()
    state.focus.enabled = true
    let surface = MonitorSurface(source: source, state: state)
    let scope = MonitorScopeOverlay(source: source, settings: ScopeSettings(kind: .histogram))
    let renderer = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(surfaces: [surface], scopes: [scope]),
      scopeEngine: try gpu.scopeEngine())
    let driver = MonitorDisplayDriver(
      renderer: renderer, layer: CAMetalLayer(), mode: .convenience(queue: gpu.queue))
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    let feed = try XCTUnwrap(renderer.feed(for: surface))
    let analyses = feed.analysisCount
    let accumulator = try XCTUnwrap(renderer.accumulator(for: scope))
    let generation = accumulator.generation
    XCTAssertFalse(renderer.scopesDue)
    driver.trackCommandBuffer(try XCTUnwrap(gpu.queue.makeCommandBuffer()))
    driver.checkCommandBuffers { _ in .error }
    XCTAssertFalse(feed.hasFocusMask(for: try XCTUnwrap(source.latestFrame)))
    XCTAssertTrue(renderer.scopesDue, "the failed buffer's accumulation must not stay cached")
    XCTAssertTrue(renderer.needsDisplay(width: 64, height: 36, pixelFormat: .bgra8Unorm))
    XCTAssertFalse(try renderer.update(), "recovery must work without a source or settings edit")
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertEqual(feed.analysisCount, analyses + 1, "both renderer and feed analysis keys must be invalidated")
    XCTAssertNotEqual(accumulator.generation, generation)
    XCTAssertFalse(renderer.scopesDue)
  }

  func testEveryPictureAndScopeBufferCanInvalidateAnUnchangedScene() throws {
    let gpu = try requireGPU()
    let renderer = MonitorRenderer(engine: gpu.engine)
    let driver = MonitorDisplayDriver(
      renderer: renderer, layer: CAMetalLayer(), mode: .convenience(queue: gpu.queue))
    let target = gpu.texture(.bgra8Unorm, 16, 8)
    func draw() throws {
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
      XCTAssertFalse(renderer.needsDisplay(width: 16, height: 8, pixelFormat: .bgra8Unorm))
    }
    try draw()
    let picture = try XCTUnwrap(gpu.queue.makeCommandBuffer())
    let scope = try XCTUnwrap(gpu.queue.makeCommandBuffer())
    let laterPicture = try XCTUnwrap(gpu.queue.makeCommandBuffer())
    driver.trackCommandBuffer(picture)
    driver.trackCommandBuffer(scope)
    driver.trackCommandBuffer(laterPicture)
    var seen: [ObjectIdentifier] = []
    driver.checkCommandBuffers { buffer in
      seen.append(ObjectIdentifier(buffer))
      if buffer === picture { return .error }
      return buffer === scope ? .completed : .scheduled
    }
    XCTAssertEqual(seen, [picture, scope, laterPicture].map(ObjectIdentifier.init))
    XCTAssertTrue(renderer.needsDisplay(width: 16, height: 8, pixelFormat: .bgra8Unorm),
      "a successful scope buffer must not hide the picture buffer's failure")

    try draw()
    seen.removeAll()
    driver.checkCommandBuffers { buffer in
      seen.append(ObjectIdentifier(buffer))
      return .error
    }
    XCTAssertEqual(seen, [ObjectIdentifier(laterPicture)])
    XCTAssertTrue(renderer.needsDisplay(width: 16, height: 8, pixelFormat: .bgra8Unorm),
      "a buffer submitted while another probe was pending must be checked too")

    try draw()
    driver.checkCommandBuffers { _ in XCTFail("terminal buffers must be removed"); return .error }
    XCTAssertFalse(renderer.needsDisplay(width: 16, height: 8, pixelFormat: .bgra8Unorm))
  }
}
