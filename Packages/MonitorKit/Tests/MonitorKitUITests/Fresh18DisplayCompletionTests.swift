// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Metal
import MonitorKit
import XCTest

@testable import MonitorKitUI

@MainActor
final class Fresh18DisplayCompletionTests: XCTestCase {
  func testMacOSAncestorVisibilityStopsAndRestartsHeadroomSampling() throws {
    let gpu = try requireGPU()
    _ = NSApplication.shared
    let view = MonitorMetalView(engine: gpu.engine, mode: .convenience(queue: gpu.queue))
    let container = NSView(frame: view.frame)
    container.addSubview(view)
    let window = NSWindow(
      contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    defer { window.close() }
    // No on-screen window needed: visibility defaults to true until AppKit
    // reports occlusion, so these assertions isolate ancestor hide callbacks.
    XCTAssertTrue(view.isDisplayLinkRunning)
    XCTAssertNotNil(view.headroomTimer)
    container.isHidden = true
    XCTAssertFalse(view.isDisplayLinkRunning)
    XCTAssertNil(view.headroomTimer)
    container.isHidden = false
    XCTAssertTrue(view.isDisplayLinkRunning)
    XCTAssertNotNil(view.headroomTimer)
    view.removeFromSuperview()
    XCTAssertFalse(view.isDisplayLinkRunning)
    XCTAssertNil(view.headroomTimer)
  }

  func testMultipleCallerBuffersDoNotLetOwnQueueVouchForEarlierCallerWork() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]),
      mode: .convenience(queue: gpu.queue))
    let first = try XCTUnwrap(gpu.queue.makeCommandBuffer())
    let second = try XCTUnwrap(gpu.queue.makeCommandBuffer())
    let target = gpu.texture(.bgra8Unorm, 32, 18)
    source.submit(try gpu.sdrFrame(width: 32, height: 18))
    view.drawOffscreen(into: target, commandBuffer: first)
    source.submit(try gpu.sdrFrame(width: 32, height: 18, seed: 1))
    view.drawOffscreen(into: target, commandBuffer: second)
    XCTAssertEqual(view.renderer.retiredCount, 1)
    // Neither caller buffer has been committed. The convenience queue's empty
    // idle marker cannot establish completion of either of them.
    view.isPaused = true
    let marker = try XCTUnwrap(view.driver.probe)
    marker.waitUntilCompleted()
    view.driver.releaseIdle()
    XCTAssertEqual(view.renderer.retiredCount, 1)
    first.commit()
    second.commit()
    second.waitUntilCompleted()
    view.completionReporter.noteCompleted(through: view.renderer.encodeCount)
    view.driver.releaseIdle()
    XCTAssertEqual(view.renderer.retiredCount, 0)
  }
}
