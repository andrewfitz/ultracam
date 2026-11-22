// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest

@testable import MonitorKit

final class Perf08MaskDependencyTests: XCTestCase {
  func testMaskReplacementAndReleaseDiscardOnlyObsoleteDependencies() throws {
    let m = try requireMTL4()
    let feed = m.gpu.engine.makeFeed()
    var state = MonitorState()
    state.focus.enabled = true
    let small = try m.frame(PictureTests.picture(width: 48, height: 24), signal: .rec709)
    let large = try m.frame(PictureTests.picture(width: 96, height: 48), signal: .rec709)
    let commandBuffer = try XCTUnwrap(m.gpu.device.makeCommandBuffer())
    let pending = MonitorSubmission(commandBuffer: commandBuffer, index: 11, completedIndex: 0)
    let first = try feed.prepareAnalysis(small, focus: state.focus)
    feed.maskLastWrite = 7
    feed.noteMaskRead(pending)
    let same = try feed.prepareAnalysis(small, focus: state.focus)
    XCTAssertTrue(first.mask === same.mask)
    XCTAssertEqual(feed.maskLastRead, 11)
    XCTAssertTrue(feed.maskWritePending(pending), "reusing a mask must preserve its outstanding writes")
    let replacement = try feed.prepareAnalysis(large, focus: state.focus)
    XCTAssertFalse(first.mask === replacement.mask)
    XCTAssertEqual(feed.maskLastRead, 0)
    XCTAssertEqual(feed.maskLastWrite, 0)
    XCTAssertFalse(feed.maskWritePending(pending), "a new allocation has no earlier writer")
    feed.maskLastWrite = 9
    feed.noteMaskRead(pending)
    feed.releaseFocusMask()
    XCTAssertNil(feed.focusMask)
    XCTAssertEqual(feed.maskLastRead, 0)
    XCTAssertEqual(feed.maskLastWrite, 0)
  }

  func testResizedMetal4AnalysisAndPictureMatchClassic() throws {
    let m = try requireMTL4()
    let feed = m.gpu.engine.makeFeed(), classicFeed = m.gpu.engine.makeFeed()
    let pass = m.gpu.engine.makePass(), classicPass = m.gpu.engine.makePass()
    var state = MonitorState()
    state.focus.enabled = true
    state.focus.opacity = 1
    let small = try m.frame(PictureTests.picture(width: 48, height: 24), signal: .rec709)
    let large = try m.frame(PictureTests.picture(width: 96, height: 48), signal: .rec709)
    let target = m.target(96, 48)
    let classicTarget = m.gpu.texture(.rgba32Float, 96, 48, usage: [.renderTarget, .shaderRead])
    try m.run { submission in
      try feed.analyze(small, focus: state.focus, into: submission)
      feed.noteMaskRead(submission)
      try feed.analyze(large, focus: state.focus, into: submission)
      XCTAssertEqual(feed.maskLastRead, 0, "resizing must not inherit the small mask's read dependency")
      XCTAssertEqual(feed.maskLastWrite, submission.index, "the new analysis establishes its own dependency")
      try pass.encode(frame: large, feed: feed, state: state, target: target, into: submission)
      XCTAssertEqual(feed.maskLastRead, submission.index)
    }
    try m.gpu.run { commandBuffer in
      try classicFeed.analyze(large, focus: state.focus, into: commandBuffer)
      try classicPass.encode(frame: large, feed: classicFeed, state: state,
        target: classicTarget, into: commandBuffer)
    }
    assertSamePixels(Pixels(target).values, Pixels(classicTarget).values)
  }
}
