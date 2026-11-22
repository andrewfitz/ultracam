// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import XCTest

@testable import MonitorKitScopes

final class ScopeFresh11ViewportTests: XCTestCase {
  func testHostPassRejectsUnrepresentableViewportBeforeCacheArithmetic() throws {
    let (_, _, engine) = try GPU.require()
    let renderer = engine.makeRenderer()
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings())
    for area in [
      MonitorViewport(width: Int.max, height: 1),
      MonitorViewport(width: 1, height: Int.max),
      MonitorViewport(x: Int.max, width: 32, height: 32),
      MonitorViewport(y: Int.max, width: 32, height: 32),
      MonitorViewport(width: Int(UInt32.max) - 63, height: Int(UInt32.max) - 63),
    ] {
      XCTAssertThrowsError(try renderer.update(
        accumulator, display: nil, viewport: area,
        target: MonitorRenderTargetFormat(colorPixelFormat: .rgba8Unorm)))
    }
    XCTAssertNil(renderer.graticuleTexture)
    XCTAssertNil(renderer.traceTexture)
  }
}
