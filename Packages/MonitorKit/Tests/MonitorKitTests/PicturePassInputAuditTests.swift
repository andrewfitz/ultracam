// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest
@testable import MonitorKit

final class PicturePassInputAuditTests: XCTestCase {
  func testViewportContainmentDoesNotOverflow() {
    XCTAssertTrue(MonitorViewport(x: 10, y: 5, width: 90, height: 45).isContained(inWidth: 100, height: 50))
    for viewport in [
      MonitorViewport(x: .max, width: 1, height: 1),
      MonitorViewport(x: 1, width: .max, height: 1),
      MonitorViewport(y: .max, width: 1, height: .max),
      MonitorViewport(x: -1, width: 1, height: 1),
      MonitorViewport(width: 0, height: 1),
      MonitorViewport(width: -1, height: 1),
    ] {
      XCTAssertFalse(viewport.isContained(inWidth: 100, height: 50))
    }
  }

  func testGuideCellsHandleExtremeHostParameters() {
    var guides = GuideParameters()
    guides.counts = SIMD4(1, 0, 0, 0)
    guides.reach.x = 1
    for position in [Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude] {
      guides.lines[0] = SIMD4(position, 0, 100, 1)
      guides.updateCells()
      for i in 0..<64 { XCTAssertEqual(guides.cells[i], 0) }
    }
    guides.lines[0].x = 10
    for radius in [Float.infinity, -Float.infinity, Float.nan] {
      guides.reach.x = radius
      guides.updateCells()
      for i in 0..<64 { XCTAssertEqual(guides.cells[i], .max) }
    }
    guides.reach.x = .greatestFiniteMagnitude
    guides.updateCells()
    for i in 0..<32 { XCTAssertEqual(guides.cells[i], .max) }
  }

  func testFailedPrepareDiscardsPreviousFrame() throws {
    let gpu = try requireGPU()
    let frame = try SyntheticFrame.neutral(.v210, width: 96, height: 48) { _, _ in 64 }.frame(gpu, signal: .rec709)
    let pass = gpu.engine.makePass(), feed = gpu.engine.makeFeed()
    let buffer = try XCTUnwrap(gpu.engine.device.makeCommandQueue()?.makeCommandBuffer())
    try pass.prepare(frame: frame, feed: feed, state: MonitorState(),
                     viewport: MonitorViewport(width: 96, height: 48), targetPixelFormat: .rgba32Float, into: buffer)
    XCTAssertNotNil(pass.pending)
    XCTAssertThrowsError(try pass.prepare(frame: frame, feed: feed, state: MonitorState(),
                                         viewport: MonitorViewport(x: -1, width: 96, height: 48),
                                         targetPixelFormat: .rgba32Float, into: buffer))
    XCTAssertNil(pass.pending)
  }
}
