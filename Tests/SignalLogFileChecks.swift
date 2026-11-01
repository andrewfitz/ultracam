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
}
