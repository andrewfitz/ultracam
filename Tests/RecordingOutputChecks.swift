import Foundation
import XCTest

private struct FixedRecordingOutputDiskSpace: RecordingOutputDiskSpaceProviding {
  let bytes: UInt64

  func availableBytes(at directory: URL) throws -> UInt64 { bytes }
}

private final class ChangingRecordingOutputDiskSpace: RecordingOutputDiskSpaceProviding, @unchecked Sendable {
  var bytes: UInt64
  init(bytes: UInt64) { self.bytes = bytes }
  func availableBytes(at directory: URL) throws -> UInt64 { bytes }
}

@objcMembers final class RecordingOutputChecks: XCTestCase {
  /// External volumes can report 0 "available for important usage" while their
  /// plain available capacity is terabytes; that drive must not read as full.
  func testFreeSpaceUsesTheLargerVolumeFigure() {
    XCTAssertEqual(VolumeFreeSpace.bytes(important: 0, available: 2_213_248_704_512), 2_213_248_704_512)
    XCTAssertEqual(VolumeFreeSpace.bytes(important: 900, available: 500), 900)
    XCTAssertEqual(VolumeFreeSpace.bytes(important: nil, available: 500), 500)
    XCTAssertEqual(VolumeFreeSpace.bytes(important: 500, available: nil), 500)
    XCTAssertNil(VolumeFreeSpace.bytes(important: nil, available: nil))
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ultracam-recording-output-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  func testPerFeedPathsAndAtomicFinalization() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, fileExtension: ".MOV",
      minimumFreeBytes: 100, diskSpace: FixedRecordingOutputDiskSpace(bytes: 10_000))
    let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let session = try manager.beginSession(feedID: "camera-a", sessionID: id, expectedBytes: 4)

    XCTAssertEqual(session.paths.feedDirectory.lastPathComponent, "camera-a")
    XCTAssertEqual(session.paths.finalFile.pathExtension, "mov")
    XCTAssertNotNil(session.paths.finalFile.lastPathComponent.range(
      of: #"^camera-a_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_\d{3}_AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE(?:-\d+)?\.mov$"#, options: .regularExpression))
    XCTAssertTrue(FileManager.default.fileExists(atPath: session.temporaryURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: session.finalURL.path))

    try session.append(Data([1, 2, 3, 4]))
    let finalized = try session.finish()
    XCTAssertEqual(finalized, session.finalURL)
    XCTAssertEqual(session.state, .finished)
    XCTAssertFalse(FileManager.default.fileExists(atPath: session.temporaryURL.path))
    XCTAssertEqual(try Data(contentsOf: finalized), Data([1, 2, 3, 4]))
  }

  func testPausePreservesTemporaryFileAndSessionsAreIndependent() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0,
      diskSpace: FixedRecordingOutputDiskSpace(bytes: 10_000))
    let first = try manager.beginSession(feedID: "one", expectedBytes: 2)
    let second = try manager.beginSession(feedID: "two", expectedBytes: 2)

    try first.append(Data([10]))
    try first.pause()
    XCTAssertEqual(first.state, .paused)
    XCTAssertEqual(first.bytesWritten, 1)
    XCTAssertThrowsError(try first.append(Data([11]))) { error in
      XCTAssertEqual(error as? RecordingOutputError,
        .invalidState(.paused, operation: "append data"))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.temporaryURL.path))

    try second.append(Data([20]))
    _ = try second.finish()
    XCTAssertEqual(second.state, .finished)
    XCTAssertEqual(first.state, .paused)

    try first.resume()
    try first.append(Data([11]))
    _ = try first.finish()
    XCTAssertEqual(try Data(contentsOf: first.finalURL), Data([10, 11]))
  }

  func testRejectsTraversalAndEscapingSymlink() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.deletingLastPathComponent()
      .appendingPathComponent("ultracam-recording-outside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0,
      diskSpace: FixedRecordingOutputDiskSpace(bytes: 10_000))

    for feedID in ["../outside", "/tmp/recording", "", ".", "..", "feed/child"] {
      XCTAssertThrowsError(try manager.makeSession(feedID: feedID)) { error in
        XCTAssertEqual(error as? RecordingOutputError, .invalidFeedID)
      }
    }
    let symlink = root.appendingPathComponent("escaped", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    XCTAssertThrowsError(try manager.makeSession(feedID: "escaped")) { error in
      XCTAssertEqual(error as? RecordingOutputError, .unsafePath)
    }
  }

  func testAdmissionRejectsInsufficientSpaceAndReleasesReservation() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 100,
      diskSpace: FixedRecordingOutputDiskSpace(bytes: 110), volumes: RecordingVolumeSpaceRegistry())
    XCTAssertThrowsError(try manager.makeSession(feedID: "too-large", expectedBytes: 11)) { error in
      XCTAssertEqual(error as? RecordingOutputError,
        .insufficientDiskSpace(required: 111, available: 110))
    }

    let accepted = try manager.beginSession(feedID: "fits", expectedBytes: 10)
    _ = try accepted.finish()
    XCTAssertEqual(accepted.state, .finished)
  }

  func testRepeatedSessionDoesNotReplaceExistingOutput() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0,
      diskSpace: FixedRecordingOutputDiskSpace(bytes: 10_000))
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let first = try manager.beginSession(feedID: "camera", sessionID: id)
    try first.append(Data([1]))
    _ = try first.finish()
    let second = try manager.makeSession(feedID: "camera", sessionID: id)
    XCTAssertNotEqual(first.finalURL, second.finalURL)
    XCTAssertNotEqual(first.finalURL.lastPathComponent, second.finalURL.lastPathComponent)
    XCTAssertEqual(try Data(contentsOf: first.finalURL), Data([1]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.finalURL.path))
  }

  func testExternalWriterSessionLeavesPathForContainerAndFinalizesAtomically() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0,
      diskSpace: FixedRecordingOutputDiskSpace(bytes: 10_000))
    let session = try manager.beginExternalWriterSession(feedID: "camera-a")

    // AVAssetWriter owns creation of the temporary container. The output
    // manager must not pre-create a path that would make AVAssetWriter reject
    // its URL as already occupied.
    XCTAssertFalse(FileManager.default.fileExists(atPath: session.temporaryURL.path))
    try Data([0x66, 0x74, 0x79, 0x70]).write(to: session.temporaryURL,
      options: [.atomic])
    let finalURL = try session.finish()

    XCTAssertEqual(finalURL, session.finalURL)
    XCTAssertEqual(session.state, .finished)
    XCTAssertFalse(FileManager.default.fileExists(atPath: session.temporaryURL.path))
    XCTAssertEqual(try Data(contentsOf: finalURL), Data([0x66, 0x74, 0x79, 0x70]))
  }

  func testExternalWriterWithoutContainerCannotCreateEmptyFinalFile() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0,
      diskSpace: FixedRecordingOutputDiskSpace(bytes: 10_000))
    let session = try manager.beginExternalWriterSession(feedID: "camera-b")

    XCTAssertThrowsError(try session.finish()) { error in
      XCTAssertEqual(error as? RecordingOutputError,
        .ioFailure("The media writer did not produce a temporary output file."))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: session.finalURL.path))
  }

  func testExternalWriterPauseAndResumePreservesSession() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0,
      diskSpace: FixedRecordingOutputDiskSpace(bytes: 10_000))
    let session = try manager.beginExternalWriterSession(feedID: "camera-c")
    try Data([0x66, 0x74, 0x79, 0x70]).write(to: session.temporaryURL, options: [.atomic])

    try session.pause()
    XCTAssertEqual(session.state, .paused)
    try session.resume()
    XCTAssertEqual(session.state, .recording)
    XCTAssertEqual(try session.finish(), session.finalURL)
  }

  func testRecoveryIgnoresLiveSessionsAndRetainsFailedMedia() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
    let take = try manager.beginExternalWriterSession(feedID: "Wide")
    let media = Data([1, 2, 3, 4])
    try media.write(to: take.temporaryURL)
    XCTAssertTrue(try RecordingRecovery.scan(root: root).isEmpty)
    take.preserveForRecovery()
    let found = try RecordingRecovery.scan(root: root)
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(found.first?.temporaryURL.resolvingSymlinksInPath().path, take.temporaryURL.resolvingSymlinksInPath().path)
    XCTAssertEqual(try Data(contentsOf: take.temporaryURL), media)
    XCTAssertFalse(FileManager.default.fileExists(atPath: take.finalURL.path))
  }

  func testRecoveryJournalAcceptsConfiguredCustomExtension() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, fileExtension: "mxf", minimumFreeBytes: 0)
    let take = try manager.beginExternalWriterSession(feedID: "Wide")
    try Data([1, 2, 3]).write(to: take.temporaryURL)
    take.preserveForRecovery()
    let interrupted = try XCTUnwrap(RecordingRecovery.scan(root: root).first)
    XCTAssertEqual(interrupted.finalURL.pathExtension, "mxf")
    XCTAssertEqual(interrupted.temporaryURL.resolvingSymlinksInPath(), take.temporaryURL.resolvingSymlinksInPath())
  }

  func testCompletedAndCancelledSessionsRemoveRecoveryJournal() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
    for finish in [true, false] {
      let take = try manager.beginExternalWriterSession(feedID: "Wide")
      try Data([1]).write(to: take.temporaryURL)
      let journal = RecordingRecoveryJournal.url(for: take.temporaryURL)
      XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
      if finish { _ = try take.finish() } else { try take.cancel() }
      XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    XCTAssertTrue(try RecordingRecovery.scan(root: root).isEmpty)
  }

  func testRecoveryRejectsForeignFilesTraversalAndSymlinks() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
    let take = try manager.beginExternalWriterSession(feedID: "Wide")
    try Data([1]).write(to: take.temporaryURL)
    take.preserveForRecovery()
    let original = try Data(contentsOf: take.temporaryURL)
    let journalURL = RecordingRecoveryJournal.url(for: take.temporaryURL)
    let journal = try Data(contentsOf: journalURL)
    let malformed = RecordingRecoveryJournal.Entry(temporaryName: "../../outside", finalName: "outside.mov")
    try JSONEncoder().encode(malformed).write(to: journalURL)
    XCTAssertTrue(try RecordingRecovery.scan(root: root).isEmpty)
    try journal.write(to: journalURL)
    let target = root.appendingPathComponent("unrelated.partial")
    try original.write(to: target)
    try FileManager.default.removeItem(at: take.temporaryURL)
    try FileManager.default.createSymbolicLink(at: take.temporaryURL, withDestinationURL: target)
    XCTAssertTrue(try RecordingRecovery.scan(root: root).isEmpty)
    try FileManager.default.removeItem(at: journalURL)
    try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: target)
    XCTAssertTrue(try RecordingRecovery.scan(root: root).isEmpty)
    XCTAssertEqual(try Data(contentsOf: target), original)
  }

  func testSelectedSymlinkRootPassesRecoveryContainmentWithoutAllowingFeedEscapes() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    let manager = try RecordingOutputManager(rootDirectory: alias, minimumFreeBytes: 0)
    let partial = try manager.beginExternalWriterSession(feedID: "Wide")
    try Data("not a movie".utf8).write(to: partial.temporaryURL)
    partial.preserveForRecovery()
    let take = try XCTUnwrap(RecordingRecovery.scan(root: alias).first)
    XCTAssertEqual(take.temporaryURL.resolvingSymlinksInPath(), partial.temporaryURL.resolvingSymlinksInPath())
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("escape"), withDestinationURL: outside)
    XCTAssertEqual(try RecordingRecovery.scan(root: alias).count, 1)
    let done = expectation(description: "Selected root admitted; invalid media refused")
    Task {
      do { _ = try await RecordingRecovery.recover(take, root: alias); XCTFail("Invalid media recovered") }
      catch RecordingOutputError.unsafePath { XCTFail("Selected root alias must pass containment") }
      catch { }
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    XCTAssertEqual(try Data(contentsOf: partial.temporaryURL), Data("not a movie".utf8))
  }

  func testRecoveryFailurePreservesOriginalAndCanBeRetried() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
    let take = try manager.beginExternalWriterSession(feedID: "Wide")
    let original = Data("not a movie".utf8)
    try original.write(to: take.temporaryURL)
    take.preserveForRecovery()
    let interrupted = try XCTUnwrap(RecordingRecovery.scan(root: root).first)
    let completed = expectation(description: "Recovery rejects invalid media")
    Task {
      do {
        _ = try await RecordingRecovery.recover(interrupted, root: root)
        XCTFail("Invalid media was recovered")
      } catch { }
      completed.fulfill()
    }
    wait(for: [completed], timeout: 5)
    XCTAssertEqual(try Data(contentsOf: take.temporaryURL), original)
    XCTAssertEqual(try RecordingRecovery.scan(root: root).count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: take.finalURL.path))
  }

  func testRecordingFolderBookmarkSurvivesStoreRecreationAndClears() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "UltracamRecordingBookmarkTests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try RecordingFolderStore(defaults: defaults).save(root)
    XCTAssertEqual(try RecordingFolderStore(defaults: defaults).load()?.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
    try RecordingFolderStore(defaults: defaults).save(nil)
    XCTAssertNil(try RecordingFolderStore(defaults: defaults).load())
  }

  func testIndependentManagersRespectJournalReservationBeforeMediaArrives() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstManager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
    let first = try firstManager.beginExternalWriterSession(feedID: "Wide")
    let secondManager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
    let second = try secondManager.beginExternalWriterSession(feedID: "Wide")
    XCTAssertNotEqual(first.temporaryURL, second.temporaryURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingRecoveryJournal.url(for: first.temporaryURL).path))
    try first.cancel()
    try second.cancel()
  }

  func testFailedStartCancellationCannotDeleteAnUnownedFile() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
    let take = try manager.makeSession(feedID: "Wide")
    try FileManager.default.createDirectory(at: take.paths.feedDirectory, withIntermediateDirectories: true)
    let original = Data("another writer owns this file".utf8)
    try original.write(to: take.temporaryURL)
    XCTAssertThrowsError(try take.start())
    try take.cancel()
    XCTAssertEqual(try Data(contentsOf: take.temporaryURL), original)
  }

  func testExternalWriterRechecksFloorWithoutCountingWrittenReservationTwice() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = ChangingRecordingOutputDiskSpace(bytes: 1_000)
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 100, diskSpace: disk,
      volumes: RecordingVolumeSpaceRegistry())
    for expectedBytes: UInt64 in [0, 80] {
      disk.bytes = 1_000
      let session = try manager.beginExternalWriterSession(feedID: "Wide", expectedBytes: expectedBytes)
      let media = Data(repeating: 7, count: 80)
      try media.write(to: session.temporaryURL)
      disk.bytes = 110
      XCTAssertNoThrow(try session.checkExternalWriterCapacity())
      XCTAssertEqual(session.bytesWritten, 80)
      disk.bytes = 99
      XCTAssertThrowsError(try session.checkExternalWriterCapacity()) { error in
        XCTAssertEqual(error as? RecordingOutputError, .insufficientDiskSpace(required: 100, available: 99))
      }
      XCTAssertEqual(try Data(contentsOf: session.temporaryURL), media)
      session.preserveForRecovery()
    }
  }

  /// The in-take check also needs room for what the take holds in memory
  /// and writes before the next check; feeds on one volume share it.
  func testExternalWriterHeadroomCountsEveryTakeOnTheVolume() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = ChangingRecordingOutputDiskSpace(bytes: 1_000)
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 100, diskSpace: disk,
      volumes: RecordingVolumeSpaceRegistry())
    let wide = try manager.beginExternalWriterSession(feedID: "Wide")
    let tight = try manager.beginExternalWriterSession(feedID: "Tight")
    XCTAssertNoThrow(try wide.checkExternalWriterCapacity(headroom: 500))
    XCTAssertThrowsError(try tight.checkExternalWriterCapacity(headroom: 500)) { error in
      XCTAssertEqual(error as? RecordingOutputError, .insufficientDiskSpace(required: 1_100, available: 1_000))
    }
    XCTAssertNoThrow(try tight.checkExternalWriterCapacity(headroom: 400))
    // A finished take no longer needs its headroom.
    wide.preserveForRecovery()
    XCTAssertNoThrow(try tight.checkExternalWriterCapacity(headroom: 900))
    XCTAssertThrowsError(try tight.checkExternalWriterCapacity(headroom: 901))
    tight.preserveForRecovery()
  }

  /// Three ProRes HQ feeds recording to three folders on one drive each saw
  /// only their own folder's headroom, so the drive filled before any check
  /// failed. Reservations, headroom and the floor are pooled per volume.
  func testManagersOnTheSameVolumeShareFreeSpace() throws {
    let first = try makeRoot()
    let second = try makeRoot()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    XCTAssertEqual(RecordingVolumeSpaceRegistry.volumeKey(for: first),
      RecordingVolumeSpaceRegistry.volumeKey(for: second), "Both folders are on the test volume")
    let volumes = RecordingVolumeSpaceRegistry()
    let disk = ChangingRecordingOutputDiskSpace(bytes: 1_000)
    let wideManager = try RecordingOutputManager(rootDirectory: first, minimumFreeBytes: 100,
      diskSpace: disk, volumes: volumes)
    let tightManager = try RecordingOutputManager(rootDirectory: second, minimumFreeBytes: 100,
      diskSpace: disk, volumes: volumes)

    // Reservations made through one folder's manager count for the other.
    let reserved = try wideManager.makeSession(feedID: "Reserved", expectedBytes: 500)
    XCTAssertThrowsError(try tightManager.makeSession(feedID: "Reserved", expectedBytes: 500)) { error in
      XCTAssertEqual(error as? RecordingOutputError, .insufficientDiskSpace(required: 1_100, available: 1_000))
    }
    try reserved.cancel()

    // So does each live take's headroom; the floor is counted once.
    let wide = try wideManager.beginExternalWriterSession(feedID: "Wide")
    let tight = try tightManager.beginExternalWriterSession(feedID: "Tight")
    XCTAssertNoThrow(try wide.checkExternalWriterCapacity(headroom: 450))
    XCTAssertThrowsError(try tight.checkExternalWriterCapacity(headroom: 451)) { error in
      XCTAssertEqual(error as? RecordingOutputError, .insufficientDiskSpace(required: 1_001, available: 1_000))
    }
    XCTAssertNoThrow(try tight.checkExternalWriterCapacity(headroom: 450))
    XCTAssertEqual(volumes.usage(for: second).headroom, 900)
    wide.preserveForRecovery()
    tight.preserveForRecovery()
    XCTAssertEqual(volumes.usage(for: first).headroom, 0)
    XCTAssertEqual(volumes.usage(for: first).reserved, 0)

    // A different registry (a different volume) is not affected.
    let elsewhere = try RecordingOutputManager(rootDirectory: second, minimumFreeBytes: 100,
      diskSpace: disk, volumes: RecordingVolumeSpaceRegistry())
    let held = try wideManager.makeSession(feedID: "Held", expectedBytes: 800)
    XCTAssertNoThrow(try elsewhere.makeSession(feedID: "Other", expectedBytes: 800).cancel())
    try held.cancel()
  }

  /// A paused take keeps its file but stops holding headroom its siblings
  /// need; resuming counts it again at once.
  func testPausedTakeHoldsOnlyWhatItStillOwesUntilResume() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let volumes = RecordingVolumeSpaceRegistry()
    let disk = ChangingRecordingOutputDiskSpace(bytes: 1_000)
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 100, diskSpace: disk,
      volumes: volumes)
    let wide = try manager.beginExternalWriterSession(feedID: "Wide")
    let tight = try manager.beginExternalWriterSession(feedID: "Tight")
    try wide.checkExternalWriterCapacity(headroom: 600)
    XCTAssertThrowsError(try tight.checkExternalWriterCapacity(headroom: 600))
    try wide.pause()
    XCTAssertEqual(volumes.usage(for: root).headroom, 600, "The rejected sibling check adds no claim; pause retains accepted work until it reports what it owes")
    // Its recorder reports what is still being written; recorded, not checked.
    XCTAssertNoThrow(try wide.checkExternalWriterCapacity(headroom: 100))
    XCTAssertEqual(volumes.usage(for: root).headroom, 100)
    XCTAssertNoThrow(try tight.checkExternalWriterCapacity(headroom: 600))
    try wide.resume()
    XCTAssertEqual(volumes.usage(for: root).headroom, 1_200, "Resume restores the last full headroom")
    XCTAssertThrowsError(try tight.checkExternalWriterCapacity(headroom: 600))
    // A failed recorder reports only what it still owes; here, nothing.
    try wide.checkExternalWriterCapacity(headroom: 0)
    XCTAssertNoThrow(try tight.checkExternalWriterCapacity(headroom: 800))
    wide.preserveForRecovery()
    tight.preserveForRecovery()
  }

  /// The in-take recheck used the same URL every time, and a URL caches its
  /// resource values, so a filling drive was never noticed. Each read must
  /// see the volume as it is now. Writes to /tmp, whose volume is quiet.
  func testDiskSpaceProviderReadsTheVolumeFreshEachTime() throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("ultracam-free-space-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let held = directory
    let key: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
    let heldBefore = try held.resourceValues(forKeys: key).volumeAvailableCapacityForImportantUsage
    let provider = FileManagerRecordingOutputDiskSpaceProvider()
    let before = try provider.availableBytes(at: held)
    let fill = directory.appendingPathComponent("fill.bin")
    let size = 256 * 1024 * 1024
    try Data(count: size).write(to: fill)
    let handle = try FileHandle(forWritingTo: fill)
    try handle.synchronize()
    try handle.close()
    let after = try provider.availableBytes(at: held)
    XCTAssertGreaterThan(Int64(before) - Int64(after), Int64(size / 2),
      "The provider must see the space the new file took (before \(before), after \(after))")
    // The stale behaviour this replaces: the held URL still reports the old value.
    XCTAssertEqual(try held.resourceValues(forKeys: key).volumeAvailableCapacityForImportantUsage, heldBefore)
  }

  func testExternalWriterAppendErrorNamesFileOwner() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
    let session = try manager.beginExternalWriterSession(feedID: "Wide")
    XCTAssertThrowsError(try session.append(Data([1]))) { error in
      XCTAssertEqual(error.localizedDescription, "Recording output I/O failed: Cannot append data while the external writer owns the output file.")
    }
    XCTAssertEqual(session.state, .recording)
    try session.cancel()
  }

  func testSessionIDSeparatesUncreatedPathsAcrossManagers() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstManager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
    let secondManager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
    let firstID = UUID()
    let secondID = UUID()
    let first = try firstManager.makeSession(feedID: "Wide", sessionID: firstID)
    let second = try secondManager.makeSession(feedID: "Wide", sessionID: secondID)
    XCTAssertTrue(first.finalURL.lastPathComponent.contains(firstID.uuidString))
    XCTAssertTrue(second.finalURL.lastPathComponent.contains(secondID.uuidString))
    XCTAssertNotEqual(first.temporaryURL, second.temporaryURL)
  }

  func testRecoveryScanReclaimsInterruptedExportAndKeepsOriginal() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
    let session = try manager.beginExternalWriterSession(feedID: "Wide")
    let original = Data([1, 2, 3])
    try original.write(to: session.temporaryURL)
    let staging = session.temporaryURL.appendingPathExtension("export.ultracam-recovery")
    try Data([4, 5]).write(to: staging)
    XCTAssertTrue(try RecordingRecovery.scan(root: root).isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path), "A live export owns the journal lock")
    session.preserveForRecovery()
    XCTAssertEqual(try RecordingRecovery.scan(root: root).count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    XCTAssertEqual(try Data(contentsOf: session.temporaryURL), original)
  }

}
