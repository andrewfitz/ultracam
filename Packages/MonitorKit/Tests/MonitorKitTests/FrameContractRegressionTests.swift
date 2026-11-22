// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest
@testable import MonitorKit

final class FrameContractRegressionTests: XCTestCase {
  func testUnusedPlanesCannotChangeFrameIdentityOrFreezeSource() throws {
    let gpu = try requireGPU()
    let rgb = gpu.texture(.rgba8Unorm, 8, 8)
    let packed = gpu.texture(.rgba32Uint, 8, 8)
    XCTAssertThrowsError(try MonitorFrame(
      layout: .bgra8, width: 8, height: 8, packed: packed, luma: rgb, signal: .rec709))
    XCTAssertThrowsError(try MonitorFrame(
      layout: .v210, width: 8, height: 8, packed: packed, luma: rgb, signal: .rec709))
  }

  func testOversizedPackedDimensionsThrowInsteadOfOverflowing() throws {
    XCTAssertThrowsError(try MonitorFrame(
      layout: .v210, width: Int.max, height: 1, signal: .rec709))
    XCTAssertThrowsError(try MonitorFrame(
      layout: .nv12, width: 1, height: Int.max, signal: .rec709))
  }

  func testArrayTextureCannotBeBoundAsFrameTexture2D() throws {
    let gpu = try requireGPU()
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
    descriptor.textureType = .type2DArray
    descriptor.arrayLength = 2
    descriptor.usage = .shaderRead
    let texture = try XCTUnwrap(gpu.engine.device.makeTexture(descriptor: descriptor))
    XCTAssertThrowsError(try MonitorFrame(
      layout: .bgra8, width: 8, height: 8, luma: texture, signal: .rec709))
  }
}
