// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import IOSurface
import Metal
import XCTest

@testable import MonitorKit

final class EngineCacheAuditRegressionTests: XCTestCase {
  func testInvalidSurfaceTextureRequestsThrowBeforeMetal() throws {
    let gpu = try requireGPU()
    let cache = MonitorTextureCache(device: gpu.device, residency: gpu.engine.residency)
    let pixelBuffer = try XCTUnwrap(PictureTests.picture(.rgb(bitDepth: 8, float: false), width: 16, height: 8, seed: 9)
      .pixelBuffer(range: .full))
    let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue())
    for (plane, width, height, format) in [
      (-1, 16, 8, MTLPixelFormat.bgra8Unorm),
      (1, 16, 8, .bgra8Unorm),
      (0, 0, 8, .bgra8Unorm),
      (0, 16, -1, .bgra8Unorm),
      (0, 16, 8, .invalid),
    ] {
      XCTAssertThrowsError(try cache.makeTexture(
        iosurface: surface, plane: plane, format: format, width: width, height: height))
    }
    XCTAssertEqual(cache.texturesMade, 0)
  }

  func testNonfiniteCacheClockDoesNotMakeEntriesImmortal() throws {
    let gpu = try requireGPU()
    let cache = MonitorTextureCache(device: gpu.device, residency: gpu.engine.residency)
    let pixelBuffer = try XCTUnwrap(PictureTests.picture(.rgb(bitDepth: 8, float: false), width: 16, height: 8, seed: 9)
      .pixelBuffer(range: .full))
    _ = try cache.frame(pixelBuffer, now: .infinity)
    XCTAssertEqual(cache.count, 1)
    cache.sweep(now: .nan)
    XCTAssertEqual(cache.count, 1)
    cache.sweep(now: MonitorTextureCache.uptime() + 3)
    XCTAssertEqual(cache.count, 0)
  }

  func testWarmUpRejectsDimensionsThatCannotBecomeShaderParameters() throws {
    let gpu = try requireGPU()
    let placeholder = try gpu.engine.warmUpLUT()
    for size in [(width: Int.max, height: 10), (width: 10, height: Int.max)] {
      let surface = MonitorSurfaceConfiguration(
        target: .init(colorPixelFormat: .rgba16Float), layout: .v210, frameSize: size)
      XCTAssertThrowsError(try MonitorEngine.pipelineKeys(for: surface, placeholder: placeholder))
    }
  }
}
