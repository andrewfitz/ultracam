// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest

@testable import MonitorKit

final class PictureMetal4AuditRegressionTests: XCTestCase {
  func testMetal4ViewportRejectsOverflowingOrigin() throws {
    let gpu = try requireGPU()
    let target = gpu.texture(.rgba32Float, 16, 16, usage: [.renderTarget])
    XCTAssertThrowsError(try MonitorPass.checkedViewport(
      MonitorViewport(x: .max, width: 16, height: 16), target))
  }

  func testFailedMetal4EncodeDiscardsPreparedDraw() throws {
    let m = try requireMTL4()
    let frame = try m.frame(PictureTests.picture(width: 48, height: 24), signal: .rec709)
    let pass = m.gpu.engine.makePass(), feed = m.gpu.engine.makeFeed()
    let target = m.target(48, 24)
    try m.run { submission in
      try pass.prepare(frame: frame, feed: feed, state: MonitorState(),
        viewport: MonitorViewport(width: 48, height: 24),
        target: MonitorRenderTargetFormat(colorPixelFormat: target.pixelFormat), submission: submission)
      XCTAssertNotNil(pass.pending)
      XCTAssertThrowsError(try pass.encode(frame: frame, feed: feed, state: MonitorState(),
        target: target, viewport: MonitorViewport(x: .max, width: 48, height: 24), into: submission))
      XCTAssertNil(pass.pending)
    }
  }

  func testMetal4ComputeRejectsArrayTargetBeforeEncoding() throws {
    let m = try requireMTL4()
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba32Float, width: 48, height: 24, mipmapped: false)
    descriptor.textureType = .type2DArray
    descriptor.arrayLength = 2
    descriptor.usage = [.shaderWrite, .shaderRead]
    let target = try XCTUnwrap(m.gpu.device.makeTexture(descriptor: descriptor))
    let frame = try m.frame(PictureTests.picture(width: 48, height: 24), signal: .rec709)
    let pass = m.gpu.engine.makePass(), feed = m.gpu.engine.makeFeed()
    try m.run { submission in
      XCTAssertThrowsError(try pass.encodeCompute(frame: frame, feed: feed, state: MonitorState(),
        target: target, into: submission))
      XCTAssertNil(pass.pending)
    }
  }
}
