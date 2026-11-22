// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitUI

final class Fresh17RendererVisibilityTests: XCTestCase {
  func testSignalNativeSkipsInvisibleLeadingSurfaces() throws {
    let gpu = try requireGPU()
    let hdr = MonitorSource(), sdr = MonitorSource()
    hdr.submit(try gpu.pqFrame())
    sdr.submit(try gpu.sdrFrame())
    let leading = MonitorSurface(source: hdr)
    let visible = MonitorSurface(source: sdr)
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [leading, visible]))
    let invisible = [
      MonitorRegion(x: 0, y: 0, width: 0, height: 1),
      MonitorRegion(x: 1, y: 0, width: 1, height: 1),
      MonitorRegion(x: -2, y: 0, width: 1, height: 1),
      MonitorRegion(x: .nan, y: 0, width: 1, height: 1),
    ]
    for region in invisible {
      leading.region = region
      try renderer.update()
      XCTAssertEqual(renderer.layerColor, MonitorLayerColor(primaries: .rec709, kind: .sdr(.bt1886)))
      XCTAssertEqual(renderer.pass(for: visible)?.outputColor.encoding, .signalNative)
    }
    leading.region = MonitorRegion(x: -0.5, y: 0, width: 1, height: 1)
    try renderer.update()
    XCTAssertEqual(renderer.layerColor, MonitorLayerColor(primaries: .rec2020, kind: .pq))
    XCTAssertEqual(renderer.pass(for: leading)?.outputColor.encoding, .signalNative)
  }
}
