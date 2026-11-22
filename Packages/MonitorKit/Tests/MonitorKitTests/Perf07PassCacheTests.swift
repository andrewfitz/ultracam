// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import MonitorKit

final class Perf07PassCacheTests: XCTestCase {
  func testMetal4CleanPeakingDoesNotRequireMaskDependency() throws {
    let m = try requireMTL4()
    let frame = try m.frame(PictureTests.picture(width: 48, height: 24), signal: .rec709)
    let pass = m.gpu.engine.makePass(), feed = m.gpu.engine.makeFeed()
    var state = MonitorState()
    state.focus.enabled = true
    try m.run { submission in
      try feed.analyze(frame, focus: state.focus, into: submission)
    }
    state.clean = true
    try m.run { submission in
      try pass.prepare(
        frame: frame, feed: feed, state: state, viewport: MonitorViewport(width: 48, height: 24),
        target: MonitorRenderTargetFormat(colorPixelFormat: .rgba32Float), submission: submission)
      XCTAssertNil(pass.pending?.focusMask)
      XCTAssertEqual(pass.status.reason(for: .focusPeaking), .cleanFeed)
    }
    state.clean = false
    try m.run { submission in
      try pass.prepare(
        frame: frame, feed: feed, state: state, viewport: MonitorViewport(width: 48, height: 24),
        target: MonitorRenderTargetFormat(colorPixelFormat: .rgba32Float), submission: submission)
      XCTAssertNotNil(pass.pending?.focusMask)
      XCTAssertTrue(pass.status.isActive(.focusPeaking))
    }
  }

  func testHiddenPeakingDoesNotBindMaskAndKeepsUnavailableStatus() throws {
    let gpu = try requireGPU()
    let frame = try SyntheticFrame.random(.v210, width: 96, height: 48, seed: 707)
      .frame(gpu, signal: .rec709)
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    var state = MonitorState()
    state.focus.enabled = true
    try gpu.run { try feed.analyze(frame, focus: state.focus, into: $0) }
    XCTAssertTrue(feed.hasFocusMask(for: frame))
    func prepare(_ input: MonitorFrame) throws {
      try pass.prepareState(
        frame: input, feed: feed, state: state, viewport: MonitorViewport(width: 96, height: 48),
        target: MonitorRenderTargetFormat(colorPixelFormat: .rgba32Float))
    }
    try prepare(frame)
    XCTAssertNotNil(pass.pending?.focusMask)
    XCTAssertTrue(pass.status.isActive(.focusPeaking))
    state.clean = true
    try prepare(frame)
    XCTAssertNil(pass.pending?.focusMask)
    XCTAssertEqual(pass.status.reason(for: .focusPeaking), .cleanFeed)
    state.clean = false
    var processed = frame
    processed.isProcessed = true
    try prepare(processed)
    XCTAssertNil(pass.pending?.focusMask)
    XCTAssertEqual(pass.status.reason(for: .focusPeaking), .requiresCameraSignal)
    try prepare(frame)
    XCTAssertNotNil(pass.pending?.focusMask)
    XCTAssertTrue(pass.status.isActive(.focusPeaking))
  }

  func testMatteOpacityEditsMatchFreshPassWithoutStrokeRebuilds() throws {
    let gpu = try requireGPU()
    let frame = try Fixtures.grey(width: 96, height: 48) { _, _ in 128 }.frame(gpu, signal: .rec709)
    let pass = gpu.engine.makePass()
    var state = MonitorState()
    state.guides.enabled = true
    state.guides.frameGuides = [
      FrameGuide(aspect: 1, style: .matte, matteOpacity: 0.2),
      FrameGuide(aspect: 2.39, style: .matte, matteOpacity: 0.9),
    ]
    _ = try gpu.render(frame, state: state, pass: pass)
    let builds = pass.guideBuildCount
    let statuses = pass.statusRebuildCount
    for opacity in [0.0, 0.4, 1.0, 0.2] {
      state.guides.frameGuides[0].matteOpacity = opacity
      let cached = try gpu.render(frame, state: state, pass: pass)
      let fresh = try gpu.render(frame, state: state)
      XCTAssertEqual(cached.values, fresh.values)
      XCTAssertEqual(pass.currentParameters.guide.w, Float(opacity))
      XCTAssertEqual(pass.guideBuildCount, builds)
      XCTAssertEqual(pass.statusRebuildCount, statuses)
    }
    state.guides.frameGuides[1].matteOpacity = 0.1
    _ = try gpu.render(frame, state: state, pass: pass)
    XCTAssertEqual(pass.guideBuildCount, builds)
    XCTAssertEqual(pass.currentParameters.guide.w, 0.2, "the first matte still wins")
  }
}
