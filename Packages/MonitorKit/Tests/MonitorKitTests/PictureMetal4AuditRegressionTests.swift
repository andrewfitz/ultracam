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

  func testOversizedMetal4UniformRingThrowsWithoutAllocating() throws {
    let m = try requireMTL4()
    let engine = m.gpu.engine
    try m.run { submission in
      for (length, slots) in [(256, Int.max), (Int.max, 1)] {
        var ring = MonitorUniformRing(slotLength: length, label: "Oversized uniform ring test")
        XCTAssertThrowsError(try ring.slot(for: submission, generation: 0, device: engine.device,
          residency: engine.residency, initialSlots: slots))
        XCTAssertNil(ring.buffer)
      }
    }
  }

  func testMetal4ComputeRejectsIntegerTargetBeforeEncoding() throws {
    let m = try requireMTL4()
    let frame = try m.frame(PictureTests.picture(width: 48, height: 24), signal: .rec709)
    let pass = m.gpu.engine.makePass(), feed = m.gpu.engine.makeFeed()
    let formats: [MTLPixelFormat] = [.rgba32Uint, .rgba32Sint]
    for format in formats {
      let target = m.gpu.texture(format, 48, 24, usage: .shaderWrite)
      try m.run { submission in
        XCTAssertThrowsError(try pass.encodeCompute(frame: frame, feed: feed, state: MonitorState(),
          target: target, into: submission))
        XCTAssertNil(pass.pending)
      }
    }
  }

  func testMetal4PassRejectsFeedFromAnotherEngine() throws {
    let m = try requireMTL4()
    let frame = try m.frame(PictureTests.picture(width: 48, height: 24), signal: .rec709)
    let pass = m.gpu.engine.makePass()
    let otherEngine = try MonitorEngine(device: m.gpu.device, specialization: .off)
    let feed = otherEngine.makeFeed()
    try m.run { submission in
      XCTAssertThrowsError(try pass.prepare(frame: frame, feed: feed, state: MonitorState(),
        viewport: MonitorViewport(width: 48, height: 24),
        target: MonitorRenderTargetFormat(colorPixelFormat: .rgba32Float), submission: submission))
      XCTAssertNil(pass.pending)
      XCTAssertNil(pass.metal4Table)
    }
  }

  func testClassicDrawRejectsMetal4Prepare() throws {
    let m = try requireMTL4()
    let frame = try m.frame(PictureTests.picture(width: 48, height: 24), signal: .rec709)
    let pass = m.gpu.engine.makePass(), feed = m.gpu.engine.makeFeed()
    let target = m.target(48, 24)
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = target
    let commandBuffer = try XCTUnwrap(m.gpu.queue.makeCommandBuffer())
    try m.run { submission in
      try pass.prepare(frame: frame, feed: feed, state: MonitorState(),
        viewport: MonitorViewport(width: 48, height: 24),
        target: MonitorRenderTargetFormat(colorPixelFormat: target.pixelFormat), submission: submission)
      let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: descriptor))
      defer { encoder.endEncoding() }
      XCTAssertThrowsError(try pass.draw(with: encoder))
      XCTAssertNotNil(pass.pending)
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
