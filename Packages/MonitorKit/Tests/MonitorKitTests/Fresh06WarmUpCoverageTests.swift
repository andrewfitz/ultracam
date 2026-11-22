// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest

@testable import MonitorKit

final class Fresh06WarmUpCoverageTests: XCTestCase {
  func testUnknownSizesPrepareBothFiltersWithLargeZoom() throws {
    let gpu = try requireGPU()
    let placeholder = try gpu.engine.warmUpLUT()
    var state = MonitorState()
    state.geometry.magnification.zoom = 64
    state.geometry.magnification.showsNavigator = false
    for compute in [false, true] {
      for knownFrame in [false, true] {
        let surface = MonitorSurfaceConfiguration(
          target: .init(colorPixelFormat: .rgba16Float), layout: .v210, state: state,
          frameSize: knownFrame ? (width: 3840, height: 2160) : nil, compute: compute)
        let keys = try MonitorEngine.pipelineKeys(for: surface, placeholder: placeholder)
        XCTAssertEqual(Set(keys.map { $0.variant.interpolates }), Set([false, true]))
        var actual = surface
        actual.frameSize = (width: 3840, height: 2160)
        actual.viewportSize = (width: 1, height: 1)
        let actualKeys = try MonitorEngine.pipelineKeys(for: actual, placeholder: placeholder)
        XCTAssertFalse(try XCTUnwrap(actualKeys.first).variant.interpolates)
        XCTAssertTrue(actualKeys.allSatisfy { keys.contains($0) }, "a small actual viewport is already prepared")
      }
    }
  }
}
