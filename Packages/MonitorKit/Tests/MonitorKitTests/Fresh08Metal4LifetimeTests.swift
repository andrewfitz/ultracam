// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest

@testable import MonitorKit

final class Fresh08Metal4LifetimeTests: XCTestCase {
  func testMaximumGenerationWritesAnUninitializedSlot() throws {
    let m = try requireMTL4()
    let commandBuffer = try XCTUnwrap(m.gpu.device.makeCommandBuffer())
    var ring = MonitorUniformRing(slotLength: 256, label: "Fresh08 maximum generation")
    defer { ring.retire(to: m.gpu.engine.residency) }
    let submission = MonitorSubmission(commandBuffer: commandBuffer, index: 1, completedIndex: 0)
    let first = try ring.slot(for: submission, generation: .max, engine: m.gpu.engine)
    XCTAssertNotNil(first.contents, "the sentinel generation must never mark an unwritten slot valid")
    let repeated = try ring.slot(for: submission, generation: .max, engine: m.gpu.engine)
    XCTAssertNil(repeated.contents)
    XCTAssertEqual(repeated.address, first.address)
    XCTAssertEqual(ring.writes, 1)
  }

  func testGrowthRetainsOldBufferUntilHighestUseCompletes() throws {
    let m = try requireMTL4()
    let engine = m.gpu.engine
    let residency = try MonitorResidency(device: engine.device, label: "Fresh08 isolated residency")
    let commandBuffer = try XCTUnwrap(m.gpu.device.makeCommandBuffer())
    var ring = MonitorUniformRing(slotLength: 256, label: "Fresh08 growth")
    func submission(_ index: UInt64) -> MonitorSubmission {
      MonitorSubmission(commandBuffer: commandBuffer, index: index, completedIndex: 0)
    }
    _ = try ring.slot(for: submission(8), generation: 1, device: engine.device,
      residency: residency, initialSlots: 1)
    let old = try XCTUnwrap(ring.buffer)
    // A repeated generation can be encoded in a lower-index command buffer:
    // that must not shorten the lifetime already recorded for submission 8.
    _ = try ring.slot(for: submission(3), generation: 1, device: engine.device,
      residency: residency, initialSlots: 1)
    let next = try ring.slot(for: submission(9), generation: 2, device: engine.device,
      residency: residency, initialSlots: 1)
    let replacement = try XCTUnwrap(ring.buffer)
    XCTAssertFalse(old === replacement)
    XCTAssertNotNil(next.contents)
    XCTAssertTrue(residency.contains(old))
    XCTAssertTrue(residency.contains(replacement))
    residency.release(through: 7)
    XCTAssertTrue(residency.contains(old))
    residency.release(through: 8)
    XCTAssertFalse(residency.contains(old))
    XCTAssertTrue(residency.contains(replacement))
    ring.retire(to: residency)
    XCTAssertTrue(residency.contains(replacement))
    residency.release(through: 9)
    XCTAssertFalse(residency.contains(replacement))
    XCTAssertEqual(residency.pendingReleaseCount, 0)
  }
}
