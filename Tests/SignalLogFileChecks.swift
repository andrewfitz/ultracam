import XCTest

@objcMembers final class SignalLogFileChecks: XCTestCase {
  func testLinesAreStampedAndAppendedInOrder() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("signal-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = SignalLogFile(folder: folder)
    log.record("Capture started feed-a")
    log.record("Signal back on feed-a after a dropout: 2 frames lost (33 ms without video).")
    log.flush()
    let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.count, 2)
    XCTAssertTrue(lines[0].hasSuffix(" Capture started feed-a"))
    XCTAssertTrue(lines[1].contains("2 frames lost"))
    // 2026-10-31 04:35:25.035 -05:00, to the millisecond and with its zone.
    XCTAssertNotNil(lines[0].range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} [+-]\d\d:\d\d "#, options: .regularExpression))
  }

  func testAFullFileRotatesOnceInsteadOfGrowing() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("signal-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = SignalLogFile(folder: folder, limit: 100)
    for index in 0..<12 { log.record("line \(index)") }
    log.flush()
    let older = folder.appendingPathComponent("signal.1.log")
    let current = try String(contentsOf: log.url, encoding: .utf8)
    XCTAssertTrue(FileManager.default.fileExists(atPath: older.path))
    XCTAssertTrue(current.hasSuffix("line 11\n"))
    XCTAssertLessThanOrEqual(try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: log.url.path)[.size] as? NSNumber).intValue, 100 + 40)
  }

  func testOnlyTheAppWritesTheSharedLog() {
    // Test and ui-verify runs share the capture code; their fixtures' dropouts must not reach the real log.
    XCTAssertNil(SignalLogFile.shared)
  }

  func testFailedRotationPreservesExistingDirectoryAndContinuesAppending() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("signal-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = SignalLogFile(folder: folder, limit: 1)
    let older = folder.appendingPathComponent("signal.1.log")
    try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
    let preserved = older.appendingPathComponent("existing")
    try Data([1]).write(to: preserved)
    log.record("first")
    log.record("second")
    log.flush()
    XCTAssertEqual(try Data(contentsOf: preserved), Data([1]))
    let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.count, 2)
  }

  func testRefusesSymbolicLinkWithoutReplacingArchive() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("signal-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let log = SignalLogFile(folder: folder, limit: 1)
    let older = folder.appendingPathComponent("signal.1.log")
    let target = folder.appendingPathComponent("other.log")
    try Data([1]).write(to: older)
    try Data([2]).write(to: target)
    try FileManager.default.createSymbolicLink(at: log.url, withDestinationURL: target)

    log.record("do not append")
    log.flush()

    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: log.url.path), target.path)
    XCTAssertEqual(try Data(contentsOf: older), Data([1]))
    XCTAssertEqual(try Data(contentsOf: target), Data([2]))
  }
}
