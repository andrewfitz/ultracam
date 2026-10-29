import XCTest

@objcMembers final class RouteDemandCoordinatorChecks: XCTestCase {
  func testSourceDemandTruthTable() {
    let values = [false, true]
    for dedicated in values {
      for program in values {
        for manual in values {
          for preview in values {
            let expected = dedicated || program || manual
            XCTAssertEqual(RouteDemandCoordinator.sourceDemand(dedicatedCamera: dedicated,
              program: program, manualOutput: manual, previewOnly: preview), expected,
              "dedicated=\(dedicated) program=\(program) manual=\(manual) preview=\(preview)")
          }
        }
      }
    }
  }

  func testDedicatedProgramManualAndPreviewRoutes() {
    var coordinator = RouteDemandCoordinator()
    let preview = coordinator.acquirePreview(feedID: "A")
    XCTAssertFalse(coordinator.sourceDemand(for: "A"), "Preview alone cannot start capture")
    XCTAssertTrue(coordinator.snapshot(for: "A").isPreviewOnly)
    XCTAssertEqual(coordinator.activeFeedIDs, Set(["A"]),
      "Route diagnostics include preview-only leases")
    XCTAssertTrue(coordinator.activeSourceFeedIDs.isEmpty,
      "Preview-only leases must not report source demand")
    XCTAssertEqual(coordinator.drainTransitions(), [])

    let dedicated = coordinator.acquireDedicatedCamera(feedID: "A")
    XCTAssertEqual(coordinator.drainTransitions(), [.start(feedID: "A")])
    XCTAssertTrue(coordinator.sourceDemand(for: "A"))
    XCTAssertEqual(coordinator.activeSourceFeedIDs, Set(["A"]))
    XCTAssertTrue(coordinator.snapshot(for: "A").dedicatedCamera)

    coordinator.selectProgram(feedID: "A")
    XCTAssertEqual(coordinator.drainTransitions(), [])
    XCTAssertTrue(coordinator.snapshot(for: "A").program)

    coordinator.selectManualOutput(feedID: "A")
    XCTAssertTrue(coordinator.snapshot(for: "A").manualOutput)
    XCTAssertEqual(coordinator.drainTransitions(), [])

    XCTAssertTrue(coordinator.release(dedicated))
    XCTAssertEqual(coordinator.drainTransitions(), [])
    XCTAssertTrue(coordinator.sourceDemand(for: "A"), "Program and manual routes keep A active")

    coordinator.selectProgram(feedID: nil)
    XCTAssertTrue(coordinator.sourceDemand(for: "A"), "Manual output still keeps A active")
    coordinator.selectManualOutput(feedID: nil)
    XCTAssertEqual(coordinator.drainTransitions(), [.stop(feedID: "A")])
    XCTAssertFalse(coordinator.sourceDemand(for: "A"))

    XCTAssertTrue(coordinator.release(preview))
    XCTAssertEqual(coordinator.snapshot(for: "A"), FeedDemandSnapshot(feedID: "A",
      dedicatedCamera: false, program: false, manualOutput: false, previewOnly: false))
  }

  func testAcquireAndReleaseAreIdempotentAndOwnerScoped() {
    var coordinator = RouteDemandCoordinator()
    let first = coordinator.acquire(feedID: "A", route: .dedicatedCamera)
    let duplicate = coordinator.acquire(feedID: "A", route: .dedicatedCamera)
    XCTAssertEqual(first, duplicate)
    XCTAssertEqual(coordinator.leaseCount(feedID: "A", route: .dedicatedCamera), 1)
    XCTAssertEqual(coordinator.drainTransitions(), [.start(feedID: "A")])

    let clientTwo = coordinator.acquire(feedID: "A", route: .dedicatedCamera, ownerID: "client-2")
    XCTAssertNotEqual(first, clientTwo)
    XCTAssertEqual(coordinator.leaseCount(feedID: "A", route: .dedicatedCamera), 2)
    XCTAssertEqual(coordinator.drainTransitions(), [])

    XCTAssertTrue(coordinator.release(first))
    XCTAssertFalse(coordinator.release(first), "A second release of the same lease is a no-op")
    XCTAssertTrue(coordinator.sourceDemand(for: "A"))
    XCTAssertEqual(coordinator.drainTransitions(), [])

    let replacement = coordinator.acquire(feedID: "A", route: .dedicatedCamera)
    XCTAssertNotEqual(first, replacement)
    XCTAssertFalse(coordinator.release(first), "A stale token cannot release a new lease")
    XCTAssertTrue(coordinator.release(replacement))
    XCTAssertTrue(coordinator.release(clientTwo))
    XCTAssertEqual(coordinator.drainTransitions(), [.stop(feedID: "A")])
  }

  func testProgramAndManualSelectionReplaceOnlyTheirOwnRoute() {
    var coordinator = RouteDemandCoordinator()
    coordinator.selectProgram(feedID: "A")
    XCTAssertEqual(coordinator.drainTransitions(), [.start(feedID: "A")])
    coordinator.selectManualOutput(feedID: "B")
    XCTAssertEqual(coordinator.drainTransitions(), [.start(feedID: "B")])

    coordinator.selectProgram(feedID: "B", at: 1)
    XCTAssertEqual(coordinator.selectedProgramFeedID, "B")
    XCTAssertTrue(coordinator.sourceDemand(for: "A") == false)
    XCTAssertTrue(coordinator.sourceDemand(for: "B"))
    XCTAssertEqual(coordinator.drainTransitions(), [.stop(feedID: "A")])
    XCTAssertTrue(coordinator.snapshot(for: "B").program)
    XCTAssertTrue(coordinator.snapshot(for: "B").manualOutput)

    coordinator.selectManualOutput(feedID: nil, at: 1)
    XCTAssertEqual(coordinator.drainTransitions(), [])
    XCTAssertTrue(coordinator.sourceDemand(for: "B"), "Program selection remains active")
    coordinator.selectProgram(feedID: nil, at: 1)
    XCTAssertEqual(coordinator.drainTransitions(), [.stop(feedID: "B")])
  }

  func testStartAndStopDebounceCanBeCancelledAndRearmed() {
    var coordinator = RouteDemandCoordinator(startDebounce: 1, stopDebounce: 2)
    _ = coordinator.acquire(feedID: "A", route: .program, at: 10)
    XCTAssertEqual(coordinator.advance(to: 10.9), [])
    XCTAssertEqual(coordinator.advance(to: 11), [.start(feedID: "A")])
    XCTAssertTrue(coordinator.isRunning(feedID: "A"))

    XCTAssertTrue(coordinator.release(feedID: "A", route: .program, at: 12))
    XCTAssertEqual(coordinator.advance(to: 13.9), [])
    _ = coordinator.acquire(feedID: "A", route: .manualOutput, at: 14)
    XCTAssertEqual(coordinator.advance(to: 100), [])
    XCTAssertTrue(coordinator.isRunning(feedID: "A"), "A cancelled stop must remain running")

    XCTAssertTrue(coordinator.release(feedID: "A", route: .manualOutput, at: 101))
    XCTAssertEqual(coordinator.advance(to: 102.9), [])
    XCTAssertEqual(coordinator.advance(to: 103), [.stop(feedID: "A")])
    XCTAssertFalse(coordinator.isRunning(feedID: "A"))
  }

  func testSetRunningAllowsFailedStartRetry() {
    var coordinator = RouteDemandCoordinator(startDebounce: 1)
    _ = coordinator.acquire(feedID: "A", route: .program, at: 0)
    XCTAssertEqual(coordinator.advance(to: 1), [.start(feedID: "A")])
    coordinator.setRunning(feedID: "A", running: false, at: 2)
    XCTAssertEqual(coordinator.advance(to: 2.9), [])
    XCTAssertEqual(coordinator.advance(to: 3), [.start(feedID: "A")])
  }

}
