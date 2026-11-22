// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest

@testable import MonitorKit

final class SubmissionMutationAuditTests: XCTestCase {
  func testCompletionMutationKeepsCurrentSubmissionIncomplete() throws {
    let m = try requireMTL4()
    let commandBuffer = try XCTUnwrap(m.gpu.device.makeCommandBuffer())
    var submission = MonitorSubmission(commandBuffer: commandBuffer, index: 7, completedIndex: 3)
    submission.completedIndex = .max
    XCTAssertEqual(submission.completedIndex, 6)
    submission.completedIndex = 2
    XCTAssertEqual(submission.completedIndex, 2, "lower truthful completion reports are preserved")
    submission.index = 1
    XCTAssertEqual(submission.completedIndex, 0)
    submission.completedIndex = 1
    XCTAssertEqual(submission.completedIndex, 0)
  }

  func testIndexMutationClampsCompletionWithoutInventingProgress() throws {
    let m = try requireMTL4()
    let commandBuffer = try XCTUnwrap(m.gpu.device.makeCommandBuffer())
    var submission = MonitorSubmission(commandBuffer: commandBuffer, index: 9, completedIndex: 7)
    submission.index = 4
    XCTAssertEqual(submission.completedIndex, 3)
    submission.index = 12
    XCTAssertEqual(submission.completedIndex, 3, "raising the index proves no further completion")
    submission.index = .max
    submission.completedIndex = .max
    XCTAssertEqual(submission.completedIndex, UInt64.max - 1)
  }
}
