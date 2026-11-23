// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Metal
import MonitorKit
import SwiftUI
import XCTest

@testable import MonitorKitUI

@MainActor
final class Fresh18DisplayCompletionTests: XCTestCase {
  func testReplacingHostedMonitorReplacesTheNativeView() throws {
    let gpu = try requireGPU()
    _ = NSApplication.shared
    let first = MonitorMetalView(engine: gpu.engine), second = MonitorMetalView(engine: gpu.engine)
    let host = NSHostingView(rootView: MonitorSceneView(view: first))
    let window = NSWindow(contentRect: first.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    func settle(until done: () -> Bool) {
      let end = Date().addingTimeInterval(2)
      while !done(), Date() < end {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
    }
    settle { first.isDescendant(of: host) }
    XCTAssertTrue(first.isDescendant(of: host))
    host.rootView = MonitorSceneView(view: second)
    settle { !first.isDescendant(of: host) && second.isDescendant(of: host) }
    XCTAssertNil(first.window)
    XCTAssertTrue(second.isDescendant(of: host))
  }

  func testSnapshotAfterSourceClearStillPresentsTheBlackFrame() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]),
      mode: .convenience(queue: gpu.queue))
    view.updateDrawableSize()
    func tick() throws {
      let drawable = try XCTUnwrap(view.metalLayer.nextDrawable())
      view.driver.tick(drawable: drawable, texture: drawable.texture, timestamp: 0, commandBuffer: nil)
      try gpu.run { _ in }
    }
    try tick()
    let drawn = view.drawCount
    XCTAssertGreaterThan(drawn, 0)
    try tick()
    XCTAssertEqual(view.drawCount, drawn)
    source.clear()
    let size = view.metalLayer.drawableSize
    let snapshot = gpu.texture(view.metalLayer.pixelFormat, Int(size.width), Int(size.height))
    view.drawOffscreen(into: snapshot)
    XCTAssertEqual(view.drawCount, drawn + 1)
    try tick()
    XCTAssertEqual(view.drawCount, drawn + 2)
    try tick()
    XCTAssertEqual(view.drawCount, drawn + 2)
  }

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
    // Neither caller buffer has been committed. A marker on the convenience
    // queue cannot establish completion of either of them.
    view.isPaused = true
    try gpu.run { _ in }
    view.driver.releaseIdle()
    XCTAssertEqual(view.renderer.retiredCount, 1)
    second.commit()
    second.waitUntilCompleted()
    view.driver.releaseIdle()
    XCTAssertEqual(view.renderer.retiredCount, 1, "the first caller still owns the retired frame")
    for _ in 0...max(3, gpu.engine.framesInFlight) {
      view.drawOffscreen(into: target)
      try gpu.run { _ in }
    }
    XCTAssertEqual(view.renderer.retiredCount, 1, "later encodes cannot retire uncommitted caller work")
    source.clear()
    first.commit()
    first.waitUntilCompleted()
    let deadline = Date().addingTimeInterval(2)
    while view.renderer.frame(for: source) != nil, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertNil(view.renderer.frame(for: source), "completion releases the paused frame without a host report")
    XCTAssertEqual(view.renderer.retiredCount, 0)
  }
}
