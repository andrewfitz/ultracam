// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitUI

@MainActor
final class DisplayDriverSafetyTests: XCTestCase {
  func testConfigurationIsRevalidatedAfterPublicMutation() throws {
    let gpu = try requireGPU()
    var configuration = MonitorMetalViewConfiguration()
    configuration.maximumDrawableCount = Int.max
    configuration.preferredFrameLatency = .nan
    let view = MonitorMetalView(engine: gpu.engine, configuration: configuration)
    XCTAssertEqual(view.configuration.maximumDrawableCount, 3)
    XCTAssertEqual(view.metalLayer.maximumDrawableCount, 3)
    XCTAssertEqual(view.configuration.preferredFrameLatency, 2)
    configuration.maximumDrawableCount = Int.min
    configuration.preferredFrameLatency = -.infinity
    let lower = configuration.normalized()
    XCTAssertEqual(lower.maximumDrawableCount, 2)
    XCTAssertEqual(lower.preferredFrameLatency, 2)
  }

  func testOffscreenDrawWhileAlreadyPausedReleasesAfterGPUCompletion() throws {
    let gpu = try requireGPU()
    let queue = try XCTUnwrap(gpu.device.makeCommandQueue())
    let event = try XCTUnwrap(gpu.device.makeSharedEvent())
    let blocker = try XCTUnwrap(queue.makeCommandBuffer())
    blocker.encodeWaitForEvent(event, value: 1)
    blocker.commit()
    defer { event.signaledValue = 1 }
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame(width: 32, height: 18))
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]),
      mode: .convenience(queue: queue))
    view.isPaused = true
    view.drawOffscreen(into: gpu.texture(.bgra8Unorm, 32, 18))
    XCTAssertNotNil(view.renderer.frame(for: source))
    event.signaledValue = 1
    let end = Date().addingTimeInterval(3)
    while view.renderer.frame(for: source) != nil && Date() < end {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertNil(view.renderer.frame(for: source), "a paused offscreen draw needs its own completion marker")
  }
}
