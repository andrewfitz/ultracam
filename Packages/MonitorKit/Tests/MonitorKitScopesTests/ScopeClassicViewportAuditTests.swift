// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import XCTest

@testable import MonitorKitScopes

final class ScopeClassicViewportAuditTests: XCTestCase {
  func testTargetViewportRejectsOverflowAndEmptyDimensions() throws {
    let (device, _, _) = try GPU.require()
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: 32, height: 32, mipmapped: false)
    let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    for area in [
      MonitorViewport(x: Int.max, width: 2, height: 1),
      MonitorViewport(y: Int.max, width: 1, height: 2),
      MonitorViewport(width: 0, height: 1),
      MonitorViewport(width: 1, height: -1),
    ] {
      XCTAssertThrowsError(try ScopeRenderer.checkedViewport(area, target))
    }
    XCTAssertNoThrow(try ScopeRenderer.checkedViewport(MonitorViewport(x: 16, y: 16, width: 16, height: 16), target))
  }

  func testHostPassViewportRejectsNegativeOriginsBeforeEncoding() throws {
    let (_, _, engine) = try GPU.require()
    let renderer = engine.makeRenderer()
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings())
    for area in [MonitorViewport(x: -1, width: 32, height: 32), MonitorViewport(y: -1, width: 32, height: 32)] {
      XCTAssertThrowsError(try renderer.update(
        accumulator, display: nil, viewport: area,
        target: MonitorRenderTargetFormat(colorPixelFormat: .rgba8Unorm)))
    }
  }
}
