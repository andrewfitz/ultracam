// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import XCTest

@testable import MonitorKitScopes

final class ScopeMetal4FailureTests: XCTestCase {
  func testRejectedRenderInvalidatesPreparedDrawAndRebuildsCachedWork() throws {
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .histogram))
    let renderer = engine.makeRenderer()
    let target = try m.target(128, 128, format: .rgba8Unorm)
    try m.run { submission in
      try renderer.render(accumulator, target: target, into: submission)
      XCTAssertNotNil(renderer.metal4Draw)
      let firstGraticuleGeneration = renderer.graticuleGeneration
      XCTAssertThrowsError(
        try renderer.render(
          accumulator, target: target, viewport: MonitorViewport(x: 128, width: 128, height: 128),
          into: submission))
      XCTAssertNil(renderer.metal4Draw, "a rejected render must not leave the preceding draw usable")
      try renderer.render(accumulator, target: target, into: submission)
      XCTAssertNotNil(renderer.metal4Draw)
      XCTAssertGreaterThan(renderer.graticuleGeneration, firstGraticuleGeneration, "retry rebuilds cached encoded work")
    }
  }
}
