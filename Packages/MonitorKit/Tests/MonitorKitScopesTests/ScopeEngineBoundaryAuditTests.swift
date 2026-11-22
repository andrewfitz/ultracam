// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest
@testable import MonitorKitScopes

final class ScopeEngineBoundaryAuditTests: XCTestCase {
  func testNonfiniteVectorscopeViewportUsesFiniteFallback() {
    let settings = ScopeSettings(kind: .vectorscope)
    for width in [Double.nan, .infinity, -.infinity, 0, -1] {
      for height in [Double.nan, .infinity, -.infinity, 0, -1, 1080] {
        let graticule = ScopeGraticule(
          settings: settings, context: ScopeContext(), viewportWidth: width, viewportHeight: height)
        for i in 0..<4 { XCTAssertTrue(graticule.plot[i].isFinite) }
        XCTAssertGreaterThan(graticule.plot.z, 0)
        XCTAssertGreaterThan(graticule.plot.w, 0)
        for label in graticule.labels {
          XCTAssertTrue(label.position.x.isFinite)
          XCTAssertTrue(label.position.y.isFinite)
        }
      }
    }
  }

  func testFailedFusedBuildRemainsTerminalDuringFallback() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .asynchronous)
    let key = ScopeEngine.ComputeKey(kernel: .fused, layout: nil, scopes: [.waveform, .histogram])
    _ = engine.pendingCompute.withLock { $0.insert(key) }
    engine.failed(key, nil)
    for _ in 0..<10 {
      let (pipeline, final) = engine.fusedPipeline(for: key)
      XCTAssertNil(pipeline)
      XCTAssertTrue(final)
      XCTAssertFalse(engine.pendingCompute.withLock { $0.contains(key) })
    }
    XCTAssertThrowsError(try engine.preparedComputePipeline(key))
  }
}
