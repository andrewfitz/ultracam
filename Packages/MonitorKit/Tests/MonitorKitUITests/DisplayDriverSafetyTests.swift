// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Metal
import MonitorKitCore
import XCTest

@testable import MonitorKit
@testable import MonitorKitUI

@MainActor
final class DisplayDriverSafetyTests: XCTestCase {
  func testTearingDownTheViewKeepsFrameBackingUntilCommandsFinish() throws {
    let gpu = try requireGPU()
    for callerOwnsBuffer in [false, true] {
      let queue = try XCTUnwrap(gpu.device.makeCommandQueue())
      let event = try XCTUnwrap(gpu.device.makeSharedEvent())
      let blocker = try XCTUnwrap(queue.makeCommandBuffer())
      blocker.encodeWaitForEvent(event, value: 1)
      blocker.commit()
      defer { event.signaledValue = 1 }
      let callerBuffer = callerOwnsBuffer ? try XCTUnwrap(queue.makeCommandBuffer()) : nil
      weak var held: NSObject?
      weak var releasedView: MonitorMetalView?
      try autoreleasepool {
        let owner = NSObject()
        held = owner
        let frame = try gpu.sdrFrame(width: 32, height: 18)
        let source = MonitorSource()
        source.submit(try MonitorFrame(
          layout: frame.layout, width: frame.width, height: frame.height,
          packed: frame.packed, luma: frame.luma, chroma: frame.chroma, signal: frame.signal,
          pixelAspectRatio: frame.pixelAspectRatio, retained: (owner, nil)))
        let view = MonitorMetalView(
          engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]),
          mode: .convenience(queue: queue))
        releasedView = view
        view.drawOffscreen(into: gpu.texture(.bgra8Unorm, 32, 18), commandBuffer: callerBuffer)
        source.clear()
      }
      XCTAssertNil(releasedView)
      XCTAssertNotNil(held, "the frame backing is still in use (caller buffer: \(callerOwnsBuffer))")
      callerBuffer?.commit()
      let fence = try XCTUnwrap(queue.makeCommandBuffer())
      fence.commit()
      event.signaledValue = 1
      fence.waitUntilCompleted()
      let deadline = Date().addingTimeInterval(2)
      while held != nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      XCTAssertNil(held, "the frame backing is released after GPU completion")
    }
  }

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
