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
      diskSpace: FixedRecordingOutputDiskSpace(bytes: 110))
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
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 100, diskSpace: disk)
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
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 100, diskSpace: disk)
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

  static let allTests = [
    ("per-feed paths and atomic finalization", testPerFeedPathsAndAtomicFinalization),
    ("pause preserves temporary file and sessions are independent", testPausePreservesTemporaryFileAndSessionsAreIndependent),
    ("reject traversal and escaping symlink", testRejectsTraversalAndEscapingSymlink),
    ("admission rejects insufficient space", testAdmissionRejectsInsufficientSpaceAndReleasesReservation),
    ("repeated session does not replace output", testRepeatedSessionDoesNotReplaceExistingOutput),
    ("external writer atomic finalization", testExternalWriterSessionLeavesPathForContainerAndFinalizesAtomically),
    ("external writer rejects empty output", testExternalWriterWithoutContainerCannotCreateEmptyFinalFile),
    ("external writer pause and resume", testExternalWriterPauseAndResumePreservesSession),
  ]
}
