import Foundation
import XCTest

@objcMembers final class VirtualCameraRegistryChecks: XCTestCase {
  func testDescriptorIDsAreDeterministicAndSeparateFeedFromProgram() throws {
    let first = VirtualCameraDescriptor.feed(feedID: "feed-1")
    let second = VirtualCameraDescriptor.feed(feedID: "feed-1")
    let other = VirtualCameraDescriptor.feed(feedID: "feed-2")
    let program = VirtualCameraDescriptor.program()

    XCTAssertEqual(first, second)
    XCTAssertNotEqual(first.id, other.id)
    XCTAssertNotEqual(first.id, program.id)
    XCTAssertEqual(first.deviceUID, VirtualCameraDescriptor.deviceUID(for: .feed, feedID: "feed-1"))
    XCTAssertEqual(program.kind, .program)
    XCTAssertNil(program.feedID)
    try first.validate()
    try program.validate()
  }

  func testSnapshotValidationRejectsTamperedIdentityAndDuplicateProgram() throws {
    let appGroup = "group.org.ultracam.registry.\(UUID().uuidString)"
    var descriptor = VirtualCameraDescriptor.feed(feedID: "feed-1")
    descriptor.deviceUID = "tampered"
    XCTAssertThrowsError(try VirtualCameraRegistrySnapshot(
      appGroupIdentifier: appGroup, devices: [descriptor]).validate())

    let snapshot = VirtualCameraRegistrySnapshot(appGroupIdentifier: appGroup,
      devices: [.program(), .program()])
    XCTAssertThrowsError(try snapshot.validate()) { error in
      XCTAssertEqual(error as? VirtualCameraRegistryError, .multipleProgramDevices)
    }
  }

  func testApplyingRequiresNewerGenerationAndSameAppGroup() throws {
    let appGroup = "group.org.ultracam.registry.\(UUID().uuidString)"
    let current = VirtualCameraRegistrySnapshot(generation: 1, appGroupIdentifier: appGroup,
      devices: [.feed(feedID: "feed-1")])
    let same = current
    XCTAssertThrowsError(try current.applying(same)) { error in
      XCTAssertEqual(error as? VirtualCameraRegistryError,
        .staleGeneration(current: 1, candidate: 1))
    }

    let next = current.advancing(to: [.feed(feedID: "feed-2")])
    XCTAssertEqual(try current.applying(next), next)

    let wrongGroup = VirtualCameraRegistrySnapshot(generation: 2,
      appGroupIdentifier: "group.other", devices: [.feed(feedID: "feed-2")])
    XCTAssertThrowsError(try current.applying(wrongGroup)) { error in
      XCTAssertEqual(error as? VirtualCameraRegistryError,
        .appGroupMismatch(expected: appGroup, actual: "group.other"))
    }
  }

  func testApplyingRejectsZeroGenerationCandidate() throws {
    let appGroup = "group.org.ultracam.registry.\(UUID().uuidString)"
    let current = VirtualCameraRegistrySnapshot(appGroupIdentifier: appGroup,
      devices: [.feed(feedID: "feed-1")])
    let candidate = VirtualCameraRegistrySnapshot(appGroupIdentifier: appGroup,
      devices: [.feed(feedID: "feed-2")])

    XCTAssertThrowsError(try current.applying(candidate)) { error in
      XCTAssertEqual(error as? VirtualCameraRegistryError, .invalidGeneration)
    }
  }

  func testStoreKeepsBackupAndRollsBackCorruptPrimary() throws {
    let suiteName = "org.ultracam.tests.registry.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appGroup = "group.org.ultracam.registry.\(UUID().uuidString)"
    let store = VirtualCameraRegistryStore(appGroupIdentifier: appGroup, defaults: defaults)
    let first = VirtualCameraRegistrySnapshot(generation: 1, appGroupIdentifier: appGroup,
      devices: [.feed(feedID: "feed-1")])
    let second = first.advancing(to: [.feed(feedID: "feed-2")])

    try store.save(first)
    try store.save(second)
    XCTAssertEqual(store.load(), second)
    XCTAssertNotNil(defaults.data(forKey: VirtualCameraRegistryStore.backupKey))

    defaults.set(Data("truncated".utf8), forKey: VirtualCameraRegistryStore.key)
    XCTAssertEqual(store.load(), first)
    XCTAssertEqual(store.load(), first, "Rollback repairs the primary slot")
  }

  func testStoreRejectsStaleOrWrongGroupWritesWithoutChangingCurrent() throws {
    let suiteName = "org.ultracam.tests.registry.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appGroup = "group.org.ultracam.registry.\(UUID().uuidString)"
    let store = VirtualCameraRegistryStore(appGroupIdentifier: appGroup, defaults: defaults)
    let current = VirtualCameraRegistrySnapshot(generation: 3, appGroupIdentifier: appGroup,
      devices: [.feed(feedID: "feed-1")])
    try store.save(current)

    let stale = VirtualCameraRegistrySnapshot(generation: 2, appGroupIdentifier: appGroup,
      devices: [.feed(feedID: "feed-2")])
    XCTAssertThrowsError(try store.save(stale)) { error in
      XCTAssertEqual(error as? VirtualCameraRegistryError,
        .staleGeneration(current: 3, candidate: 2))
    }
    let wrongGroup = VirtualCameraRegistrySnapshot(generation: 4,
      appGroupIdentifier: "group.other", devices: [.feed(feedID: "feed-2")])
    XCTAssertThrowsError(try store.save(wrongGroup)) { error in
      XCTAssertEqual(error as? VirtualCameraRegistryError,
        .appGroupMismatch(expected: appGroup, actual: "group.other"))
    }
    XCTAssertEqual(store.load(), current)
  }

  func testMissingAppGroupDoesNotPublishIntoStandardDefaults() throws {
    let marker = Data("standard-domain-must-stay-empty".utf8)
    UserDefaults.standard.set(marker, forKey: VirtualCameraRegistryStore.key)
    defer { UserDefaults.standard.removeObject(forKey: VirtualCameraRegistryStore.key) }
    let store = VirtualCameraRegistryStore(appGroupIdentifier: "")
    let snapshot = VirtualCameraRegistrySnapshot(generation: 1, appGroupIdentifier: "",
      devices: [.feed(feedID: "feed-1")])
    XCTAssertThrowsError(try store.save(snapshot))
    XCTAssertEqual(UserDefaults.standard.data(forKey: VirtualCameraRegistryStore.key), marker)
    XCTAssertNil(store.load())
  }

  func testStoreRejectsGenerationThatWouldFreezeLaterPublishes() throws {
    let suiteName = "org.ultracam.tests.registry.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appGroup = "group.org.ultracam.registry.\(UUID().uuidString)"
    let store = VirtualCameraRegistryStore(appGroupIdentifier: appGroup, defaults: defaults)
    let frozen = VirtualCameraRegistrySnapshot(generation: UInt64.max, appGroupIdentifier: appGroup,
      devices: [.feed(feedID: "feed-1")])
    XCTAssertThrowsError(try store.save(frozen)) { error in
      XCTAssertEqual(error as? VirtualCameraRegistryError, .invalidGeneration)
    }
    XCTAssertNil(store.load())
  }

  func testStoreRejectsZeroGenerationWithoutWriting() throws {
    let suiteName = "org.ultracam.tests.registry.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appGroup = "group.org.ultracam.registry.\(UUID().uuidString)"
    let store = VirtualCameraRegistryStore(appGroupIdentifier: appGroup, defaults: defaults)
    let baseline = VirtualCameraRegistrySnapshot(appGroupIdentifier: appGroup,
      devices: [.feed(feedID: "feed-1")])

    XCTAssertThrowsError(try store.save(baseline)) { error in
      XCTAssertEqual(error as? VirtualCameraRegistryError, .invalidGeneration)
    }
    XCTAssertNil(defaults.data(forKey: VirtualCameraRegistryStore.key))
    XCTAssertNil(defaults.data(forKey: VirtualCameraRegistryStore.backupKey))
  }

  func testStoreDoesNotBackUpCorruptPrimaryBytes() throws {
    let suiteName = "org.ultracam.tests.registry.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appGroup = "group.org.ultracam.registry.\(UUID().uuidString)"
    let store = VirtualCameraRegistryStore(appGroupIdentifier: appGroup, defaults: defaults)
    defaults.set(Data("truncated".utf8), forKey: VirtualCameraRegistryStore.key)

    let snapshot = VirtualCameraRegistrySnapshot(generation: 1,
      appGroupIdentifier: appGroup, devices: [.feed(feedID: "feed-1")])
    try store.save(snapshot)

    XCTAssertEqual(store.load(), snapshot)
    XCTAssertNil(defaults.data(forKey: VirtualCameraRegistryStore.backupKey),
      "A corrupt primary must not be copied into the backup slot")
  }
}
