// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import MonitorKit

final class Fresh07PassTransitionTests: XCTestCase {
  /// A replacing false-colour view can omit the picture's LUTs, until a
  /// navigator or an independently staged measurement needs them again.
  func testReplacingFalseColorRetainsOnlyStagesActuallyRead() {
    var state = MonitorState()
    state.pictureStage = .monitor
    let layout = MonitorLayout(
      frame: MonitorFrameGeometry(width: 96, height: 48), state: state,
      viewportWidth: 96, viewportHeight: 48)
    var p = PassParameters()
    p.luts = SIMD4(1, 1, 0, 0)
    p.outputReading.w = 1
    p.modes.x = FalseColorMeasureCode.stageIRE.rawValue
    p.modes.y = 0
    XCTAssertEqual(MonitorPass.variant(p, state: state, layout: layout).luts, 4)
    p.zebra = SIMD4(1, 2, 1, 16)
    XCTAssertEqual(MonitorPass.variant(p, state: state, layout: layout).luts, 1)
    p.zebra.z = 2
    XCTAssertEqual(MonitorPass.variant(p, state: state, layout: layout).luts, 3)
    p.zebra.z = 0
    p.colorFlags = SIMD4(0, 1, 1, 1)
    XCTAssertEqual(MonitorPass.variant(p, state: state, layout: layout).luts, 1)
    p.colorFlags.y = 0
    p.navigatorRect = SIMD4(0, 0, 12, 6)
    XCTAssertEqual(MonitorPass.variant(p, state: state, layout: layout).luts, 3)
  }

  func testGuideMatteDisappearsInCleanModeAndReturnsFromCache() throws {
    let gpu = try requireGPU()
    let frame = try Fixtures.grey(width: 96, height: 48) { _, _ in 128 }.frame(gpu, signal: .rec709)
    let pass = gpu.engine.makePass(), feed = gpu.engine.makeFeed()
    var state = MonitorState()
    state.guides.enabled = true
    state.guides.frameGuides = [FrameGuide(aspect: 1, style: .matte, matteOpacity: 0.4)]
    func prepare() throws {
      try pass.prepareState(
        frame: frame, feed: feed, state: state, viewport: MonitorViewport(width: 96, height: 48),
        target: MonitorRenderTargetFormat(colorPixelFormat: .rgba32Float))
    }
    try prepare()
    let visible = pass.currentParameters
    XCTAssertEqual(visible.guide.z, 1)
    XCTAssertEqual(visible.guide.w, 0.4)
    state.clean = true
    try prepare()
    XCTAssertEqual(pass.currentParameters.guide.z, 0)
    state.clean = false
    try prepare()
    XCTAssertEqual(pass.currentParameters.matte, visible.matte)
    XCTAssertEqual(pass.currentParameters.guide, visible.guide)
    let builds = pass.guideBuildCount
    state.guides.opacity = 0.2
    try prepare()
    XCTAssertEqual(pass.guideBuildCount, builds)
    XCTAssertEqual(pass.currentParameters.guide.x, 0.2)
    XCTAssertEqual(pass.currentParameters.guide.w, 0.4)
    state.guides.frameGuides[0].matteOpacity = 0.8
    try prepare()
    XCTAssertEqual(pass.currentParameters.guide.w, 0.8)
    XCTAssertEqual(pass.guideBuildCount, builds)
  }
}
