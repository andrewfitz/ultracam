import Foundation
import XCTest

@objcMembers final class VirtualCameraRegistryPublishingChecks: XCTestCase {
  func testPublishesEveryEnabledCameraThenProgramAtTwoOrMore() throws {
    let first = FeedDescriptor(id: FeedID(rawValue: "wide"), name: "Wide")
    let disabled = FeedDescriptor(id: FeedID(rawValue: "disabled"), name: "Disabled", enabled: false)
    let second = FeedDescriptor(id: FeedID(rawValue: "tight"), name: "Tight")
    let group = "group.org.ultracam.publish.\(UUID().uuidString)"
    let snapshot = VirtualCameraRegistrySnapshot.forFeeds([first, disabled, second], appGroupIdentifier: group)

    XCTAssertEqual(snapshot.generation, 1)
    XCTAssertEqual(snapshot.devices.map(\.kind), [.feed, .feed, .program])
    XCTAssertEqual(snapshot.devices.map(\.feedID), ["wide", "tight", nil])
    XCTAssertEqual(snapshot.devices.map(\.displayName), [
      "Ultracam · Wide", "Ultracam · Tight", "Ultracam · Program"])
    XCTAssertEqual(Set(snapshot.devices.map(\.deviceUID)).count, 3)
    try snapshot.validate()
  }

  func testOneCameraPublishesNoProgramAndGenerationAdvances() throws {
    let feed = FeedDescriptor(id: .primary, name: "Primary")
    let group = "group.org.ultracam.publish.\(UUID().uuidString)"
    let current = VirtualCameraRegistrySnapshot(generation: 9, appGroupIdentifier: group,
      devices: [.feed(feedID: feed.id.rawValue)])
    let next = VirtualCameraRegistrySnapshot.forFeeds([feed], previous: current, appGroupIdentifier: group)

    XCTAssertEqual(next.generation, 10)
    XCTAssertEqual(next.devices.map(\.kind), [.feed], "A second, slower way to the same picture is noise")
    try next.validate()
  }

  /// Whatever an older build saved, the list is the same: the key is written back, unread.
  @MainActor func testTheSavedOutputModeChangesNothingPublished() throws {
    let feeds = [FeedDescriptor(id: FeedID(rawValue: "wide"), name: "Wide"), FeedDescriptor(id: FeedID(rawValue: "tight"), name: "Tight")]
    let separate = FeedCoordinator(snapshot: AppSettingsSnapshot(feeds: feeds, outputMode: .separateCameras))
    let program = FeedCoordinator(snapshot: AppSettingsSnapshot(feeds: feeds, outputMode: .program))
    XCTAssertEqual(separate.virtualCameraDescriptors, program.virtualCameraDescriptors)
    XCTAssertEqual(separate.virtualCameraDescriptors.map(\.kind), [.feed, .feed, .program])
    XCTAssertEqual(program.snapshot.outputMode, .program, "A downgrade finds what it left")
    XCTAssertEqual(separate.snapshot.outputMode, .separateCameras)
  }

  func testProgramStopsAtTheLastDeviceTheExtensionHas() throws {
    func feeds(_ count: Int) -> [FeedDescriptor] {
      (0..<count).map { FeedDescriptor(id: FeedID(rawValue: "camera-\($0)"), name: "Camera \($0)") }
    }
    XCTAssertEqual(VirtualCameraRegistrySnapshot.devices(for: feeds(31)).count, 32)
    XCTAssertTrue(VirtualCameraRegistrySnapshot.devices(for: feeds(31)).contains { $0.kind == .program })
    let full = VirtualCameraRegistrySnapshot.devices(for: feeds(32))
    XCTAssertEqual(full.count, 32)
    XCTAssertFalse(full.contains { $0.kind == .program })
    XCTAssertNoThrow(try VirtualCameraRegistrySnapshot(generation: 1, devices: full).validateDeviceCount())
    XCTAssertThrowsError(try VirtualCameraRegistrySnapshot(generation: 1,
      devices: VirtualCameraRegistrySnapshot.devices(for: feeds(33))).validateDeviceCount())
  }

  func testForeignGroupDoesNotSupplyGeneration() {
    let feed = FeedDescriptor(name: "Primary")
    let current = VirtualCameraRegistrySnapshot(generation: 99,
      appGroupIdentifier: "group.foreign", devices: [.feed(feedID: feed.id.rawValue)])
    let next = VirtualCameraRegistrySnapshot.forFeeds([feed],
      previous: current, appGroupIdentifier: VirtualCameraRegistrySnapshot.defaultAppGroupIdentifier)
    XCTAssertEqual(next.generation, 1)
  }

  func testInvalidSameGroupSnapshotDoesNotSupplyGeneration() {
    let feed = FeedDescriptor(name: "Primary")
    let group = "group.org.ultracam.publish.\(UUID().uuidString)"
    let invalid = VirtualCameraRegistrySnapshot(generation: 99,
      appGroupIdentifier: group, devices: [.program(), .program()])
    let next = VirtualCameraRegistrySnapshot.forFeeds([feed],
      previous: invalid, appGroupIdentifier: group)

    XCTAssertEqual(next.generation, 1)
    XCTAssertNoThrow(try next.validate())
  }

  func testCameraProviderLoadsPublishedFeedDevicesAtStartup() throws {
    let suiteName = "org.ultracam.tests.camera-startup.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let group = "group.org.ultracam.camera-startup.\(UUID().uuidString)"
    let store = VirtualCameraRegistryStore(appGroupIdentifier: group, defaults: defaults)
    let wide = VirtualCameraDescriptor.feed(feedID: "wide", displayName: "Wide")
    let tight = VirtualCameraDescriptor.feed(feedID: "tight", displayName: "Tight")
    try store.save(VirtualCameraRegistrySnapshot(generation: 1,
      appGroupIdentifier: group, devices: [wide, tight]))

    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registryStore: store)
    XCTAssertEqual(camera.devices.count, 2)
    XCTAssertEqual(camera.descriptors.map(\.feedID), ["wide", "tight"])
    XCTAssertNotEqual(camera.device(for: wide.id)?.deviceID, camera.device(for: tight.id)?.deviceID)
    XCTAssertNotEqual(camera.descriptors[0].sourceStreamID, camera.descriptors[1].sourceStreamID)
  }
}

