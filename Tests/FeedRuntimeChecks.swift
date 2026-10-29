import CoreMedia
import CoreVideo
import XCTest

@MainActor @objcMembers final class FeedRuntimeChecks: XCTestCase {
  private func image() throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
    return try XCTUnwrap(status == kCVReturnSuccess ? image : nil)
  }

  private func frame(_ value: Int) throws -> ProcessedFrame<CVPixelBuffer> {
    ProcessedFrame(payload: try image(), metadata: ProcessedFrameMetadata(
      presentationTime: CMTime(value: Int64(value), timescale: 30),
      duration: CMTime(value: 1, timescale: 30), width: 2, height: 2,
      pixelFormat: UInt32(kCVPixelFormatType_32BGRA)))
  }

  func testCoordinatorKeepsStableOrderAndLazilyCreatesSessions() {
    let first = FeedDescriptor(id: FeedID(rawValue: "feed-a"), name: "Wide")
    let second = FeedDescriptor(id: FeedID(rawValue: "feed-b"), name: "Tight")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(
      feeds: [first, second], selectedFeedID: second.id, outputMode: .program,
      virtualCameraRegistryVersion: 7))

    XCTAssertEqual(coordinator.descriptors.map(\.id), [first.id, second.id])
    XCTAssertEqual(coordinator.selectedFeedID, second.id)
    XCTAssertTrue(coordinator.orderedSessions.isEmpty)

    let selected = coordinator.selectedSession
    XCTAssertEqual(selected.id, second.id)
    XCTAssertEqual(coordinator.orderedSessions.map(\.id), [second.id])
    XCTAssertEqual(coordinator.snapshot.outputMode, .program)
    XCTAssertEqual(coordinator.snapshot.virtualCameraRegistryVersion, 7)
  }

  func testSessionsHaveIndependentLifecycleAndRouteQueues() throws {
    let first = FeedDescriptor(id: FeedID(rawValue: "feed-a"), name: "Wide")
    let second = FeedDescriptor(id: FeedID(rawValue: "feed-b"), name: "Tight")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(feeds: [first, second]))
    let left = coordinator.session(for: first.id)
    let right = coordinator.session(for: second.id)
    let leftRoute = try coordinator.addOutputRoute(feedID: first.id, routeID: "camera",
      capacity: 2, policy: .reject)
    let rightRoute = try coordinator.addOutputRoute(feedID: second.id, routeID: "camera",
      capacity: 2, policy: .reject)

    XCTAssertTrue(coordinator.start(first.id))
    XCTAssertTrue(coordinator.start(second.id))
    XCTAssertEqual(left.state, .running)
    XCTAssertEqual(right.state, .running)

    XCTAssertEqual(coordinator.publish(try frame(1), to: first.id)["camera"], .enqueued)
    XCTAssertEqual(coordinator.publish(try frame(2), to: second.id)["camera"], .enqueued)
    XCTAssertEqual(leftRoute.pendingCount, 1)
    XCTAssertEqual(rightRoute.pendingCount, 1)

    coordinator.stop(first.id)
    XCTAssertEqual(left.state, .idle)
    XCTAssertEqual(leftRoute.pendingCount, 0)
    XCTAssertEqual(right.state, .running)
    XCTAssertEqual(rightRoute.pendingCount, 1)
    XCTAssertFalse(left.publish(try frame(3)).outcomes.keys.contains("camera"))
  }

  func testDisabledOrRunningFeedsCannotBeStartedOrRemoved() {
    let disabled = FeedDescriptor(id: FeedID(rawValue: "disabled"), name: "Disabled", enabled: false)
    let active = FeedDescriptor(id: FeedID(rawValue: "active"), name: "Active")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(feeds: [disabled, active]))
    XCTAssertFalse(coordinator.start(disabled.id))
    XCTAssertEqual(coordinator.session(for: disabled.id).state, .unavailable("Feed is disabled"))
    XCTAssertTrue(coordinator.start(active.id))
    XCTAssertFalse(coordinator.remove(active.id))
    coordinator.stop(active.id)
    XCTAssertTrue(coordinator.remove(active.id))
    XCTAssertEqual(coordinator.descriptors.map(\.id), [disabled.id])
    XCTAssertFalse(coordinator.start(FeedID(rawValue: "missing")))
    XCTAssertEqual(coordinator.descriptors.map(\.id), [disabled.id],
      "Starting an unknown ID must not create a ghost descriptor")
  }

  func testRemovingSelectedFeedSelectsAnotherEnabledFeed() {
    let disabled = FeedDescriptor(id: FeedID(rawValue: "disabled"), name: "Disabled", enabled: false)
    let first = FeedDescriptor(id: FeedID(rawValue: "first"), name: "First")
    let second = FeedDescriptor(id: FeedID(rawValue: "second"), name: "Second")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(
      feeds: [disabled, first, second], selectedFeedID: first.id))

    XCTAssertTrue(coordinator.remove(first.id))
    XCTAssertEqual(coordinator.selectedFeedID, second.id)
  }

  func testCaptureOwnersAreStableAndIndependentPerFeed() {
    let first = FeedID(rawValue: "feed-a")
    let second = FeedID(rawValue: "feed-b")
    let pool = FeedCapturePool(factory: { _ in
      CaptureController(services: CaptureServices(
        start: { _, _, _, _ in }, stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in true }))
    })
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(feeds: [
      FeedDescriptor(id: first, name: "Wide"), FeedDescriptor(id: second, name: "Tight")
    ]), capturePool: pool)

    XCTAssertTrue(pool.feedIDs.isEmpty)
    let left = coordinator.capture(for: first)
    let right = coordinator.capture(for: second)
    XCTAssertFalse(left === right)
    XCTAssertTrue(left === coordinator.capture(for: first))
    XCTAssertTrue(right === coordinator.capture(for: second))
    XCTAssertEqual(Set(pool.feedIDs), Set([first, second]))

    // Removing one configured feed releases only that feed's backend owner.
    XCTAssertTrue(coordinator.remove(first))
    XCTAssertNil(pool.existingController(for: first))
    XCTAssertNotNil(pool.existingController(for: second))
  }

  func testProgramDemandIsReleasedWhenLeavingProgramMode() {
    let first = FeedDescriptor(id: FeedID(rawValue: "feed-a"), name: "Wide")
    let second = FeedDescriptor(id: FeedID(rawValue: "feed-b"), name: "Tight")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(
      feeds: [first, second], outputMode: .program))

    XCTAssertEqual(coordinator.setProgramConsumer(true, at: 0), [.start(feedID: "feed-a")])
    XCTAssertEqual(coordinator.activeDemandFeedIDs, Set(["feed-a"]))
    coordinator.setOutputMode(.separateCameras)
    XCTAssertTrue(coordinator.activeDemandFeedIDs.isEmpty)
  }

  func testDedicatedDemandRejectsDisabledAndUnknownFeeds() {
    let enabled = FeedDescriptor(id: FeedID(rawValue: "enabled"), name: "Enabled")
    let disabled = FeedDescriptor(id: FeedID(rawValue: "disabled"), name: "Disabled", enabled: false)
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(feeds: [enabled, disabled]))

    XCTAssertTrue(coordinator.setDedicatedCameraConsumer(
      feedID: disabled.id, active: true).isEmpty)
    XCTAssertTrue(coordinator.setDedicatedCameraConsumer(
      feedID: FeedID(rawValue: "missing"), active: true).isEmpty)
    XCTAssertTrue(coordinator.activeDemandFeedIDs.isEmpty)
  }

  func testDisabledPersistedSelectionFallsBackToEnabledFeed() {
    let disabled = FeedDescriptor(id: FeedID(rawValue: "disabled"), name: "Disabled", enabled: false)
    let enabled = FeedDescriptor(id: FeedID(rawValue: "enabled"), name: "Enabled")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(
      feeds: [disabled, enabled], selectedFeedID: disabled.id))

    XCTAssertEqual(coordinator.selectedFeedID, enabled.id)
    XCTAssertEqual(coordinator.selectedDescriptor.id, enabled.id)
    XCTAssertFalse(coordinator.select(disabled.id))
  }

}
