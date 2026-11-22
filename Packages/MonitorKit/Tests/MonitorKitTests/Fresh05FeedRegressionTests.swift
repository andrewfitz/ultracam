// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import MonitorKit

final class Fresh05FeedRegressionTests: XCTestCase {
  func testRelabelledFrameRequiresFreshFocusDecodeOnEveryStage() throws {
    let gpu = try requireGPU()
    let frame = try SyntheticFrame.random(.v210, width: 12, height: 4, seed: 505)
      .frame(gpu, signal: .rec709)
    for stage in [SignalStage.source, .output, .monitor] {
      let feed = gpu.engine.makeFeed()
      var focus = FocusSettings()
      focus.enabled = true
      focus.stage = stage
      try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
      XCTAssertTrue(feed.hasFocusMask(for: frame, stage: stage, monitorLUTEnabled: true))
      var relabelled = frame
      relabelled.signal.range = .full
      XCTAssertEqual(relabelled.id, frame.id)
      XCTAssertFalse(relabelled.signal.hasDistinctOutputReading)
      XCTAssertFalse(feed.hasFocusMask(for: relabelled, stage: stage, monitorLUTEnabled: true))
      try gpu.run { try feed.analyze(relabelled, focus: focus, into: $0) }
      XCTAssertEqual(feed.analysisCount, 2)
      XCTAssertTrue(feed.hasFocusMask(for: relabelled, stage: stage, monitorLUTEnabled: true))
      XCTAssertFalse(feed.hasFocusMask(for: frame, stage: stage, monitorLUTEnabled: true))
    }
  }

  func testMixedFrozenPlaneAndMetadataAreCopiedOnClassicPath() throws {
    let gpu = try requireGPU()
    let feed = gpu.engine.makeFeed()
    let live = try SyntheticFrame.random(.nv12, width: 12, height: 4, seed: 51).frame(gpu, signal: .rec709)
    let other = try SyntheticFrame.random(.nv12, width: 12, height: 4, seed: 52).frame(gpu, signal: .rec709)
    var frozen: MonitorFrame?
    try gpu.run { frozen = try feed.freeze(live, into: $0) }
    let original = try XCTUnwrap(frozen)
    let before = gpu.decode(original)
    let mixed = try mixedFrame(original, other)
    try gpu.run { frozen = try feed.freeze(mixed, into: $0) }
    let result = try XCTUnwrap(frozen)
    assertMixedCopy(result, mixed, original)
    XCTAssertEqual(gpu.decode(result), gpu.decode(mixed))
    XCTAssertEqual(gpu.decode(original), before)
    let created = gpu.engine.resourcesCreated
    try gpu.run { XCTAssertEqual(try feed.freeze(result, into: $0).id, result.id) }
    XCTAssertEqual(gpu.engine.resourcesCreated, created)
    // A value copy keeps the same id and planes, but a relabel is not a self-freeze.
    var relabelled = result
    relabelled.signal.range = .legal
    try gpu.run { frozen = try feed.freeze(relabelled, into: $0) }
    let relabelledCopy = try XCTUnwrap(frozen)
    XCTAssertEqual(relabelledCopy.signal, relabelled.signal)
    XCTAssertFalse(relabelledCopy.luma === result.luma)
    XCTAssertEqual(gpu.decode(relabelledCopy), gpu.decode(relabelled))
  }

  func testMixedFrozenPlaneAndMetadataAreCopiedOnMetal4Path() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let feed = gpu.engine.makeFeed()
    let live = try m.frame(SyntheticFrame.random(.nv12, width: 12, height: 4, seed: 51), signal: .rec709)
    let other = try m.frame(SyntheticFrame.random(.nv12, width: 12, height: 4, seed: 52), signal: .rec709)
    var frozen: MonitorFrame?
    try m.run { frozen = try feed.freeze(live, into: $0) }
    let original = try XCTUnwrap(frozen)
    let before = gpu.decode(original)
    let mixed = try mixedFrame(original, other)
    try m.run { frozen = try feed.freeze(mixed, into: $0) }
    let result = try XCTUnwrap(frozen)
    assertMixedCopy(result, mixed, original)
    XCTAssertEqual(gpu.decode(result), gpu.decode(mixed))
    XCTAssertEqual(gpu.decode(original), before)
    let created = gpu.engine.resourcesCreated
    try m.run { XCTAssertEqual(try feed.freeze(result, into: $0).id, result.id) }
    XCTAssertEqual(gpu.engine.resourcesCreated, created)
    var relabelled = result
    relabelled.signal.range = .legal
    try m.run { frozen = try feed.freeze(relabelled, into: $0) }
    let relabelledCopy = try XCTUnwrap(frozen)
    XCTAssertEqual(relabelledCopy.signal, relabelled.signal)
    XCTAssertFalse(relabelledCopy.luma === result.luma)
    XCTAssertEqual(gpu.decode(relabelledCopy), gpu.decode(relabelled))
  }

  private func mixedFrame(_ original: MonitorFrame, _ other: MonitorFrame) throws -> MonitorFrame {
    var signal = original.signal
    signal.range = .full
    var frame = try MonitorFrame(
      layout: original.layout, width: original.width, height: original.height, luma: original.luma, chroma: other.chroma,
      signal: signal, pixelAspectRatio: 2,
      cleanAperture: MonitorRect(x: 1, y: 0, width: 8, height: 4))
    frame.isProcessed = true
    return frame
  }

  private func assertMixedCopy(_ result: MonitorFrame, _ mixed: MonitorFrame, _ original: MonitorFrame) {
    XCTAssertFalse(result.luma === original.luma)
    XCTAssertFalse(result.chroma === original.chroma)
    XCTAssertNotEqual(result.id, original.id)
    XCTAssertEqual(result.width, mixed.width)
    XCTAssertEqual(result.height, mixed.height)
    XCTAssertEqual(result.signal, mixed.signal)
    XCTAssertEqual(result.pixelAspectRatio, mixed.pixelAspectRatio)
    XCTAssertEqual(result.cleanAperture, mixed.cleanAperture)
    XCTAssertTrue(result.isProcessed)
  }

}
