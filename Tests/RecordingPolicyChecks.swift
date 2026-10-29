import Foundation
import XCTest

@objcMembers final class RecordingPolicyChecks: XCTestCase {
  func testPolicyRequiresExplicitCompatibility() {
    XCTAssertEqual(RecordingCompatibilityPolicy().route(gpuAvailable: true), .gpu)
    XCTAssertEqual(RecordingCompatibilityPolicy().route(gpuAvailable: false), .refused)
    XCTAssertEqual(RecordingCompatibilityPolicy(allowCPUConversion: true).route(gpuAvailable: true), .gpu)
    XCTAssertEqual(RecordingCompatibilityPolicy(allowCPUConversion: true).route(gpuAvailable: false), .systemCompatibility)
    XCTAssertEqual(RecordingCompatibilityPolicy().route(gpuAvailable: true, gpuFailed: true), .refused)
  }
  func testBoundedJournalAndPairedRecovery() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appendingPathComponent("take.mov")
    let store = try RecordingTakeSidecar(movieURL: movie, metadata: .init(sourceSignature: "source", outputSignature: "output"), maximumJournalBytes: 128)
    try store.append(.init(kind: "quantization", detail: "original=1001/30000"))
    XCTAssertThrowsError(try store.append(.init(kind: "quantization", detail: String(repeating: "x", count: 256))))
    let other = folder.appendingPathComponent("other.ultracam.json")
    try Data("untouched".utf8).write(to: other)
    let recovered = folder.appendingPathComponent("recovered.mov")
    try store.copyForRecoveredMovie(recovered)
    XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingTakeSidecar.url(for: recovered).path))
    try store.removePairMetadata()
    XCTAssertEqual(try Data(contentsOf: other), Data("untouched".utf8))
  }
  func testAtomicFinishAndCounterDefaults() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appendingPathComponent("take.mov")
    let store = try RecordingTakeSidecar(movieURL: movie, metadata: .init(sourceSignature: "s", outputSignature: "o"))
    try store.finish(finalError: "stopped")
    let snapshot = try JSONDecoder().decode(RecordingTakeSidecar.Snapshot.self, from: Data(contentsOf: store.url))
    XCTAssertEqual(snapshot.finalError, "stopped")
    XCTAssertTrue(snapshot.finished)
    let legacy = Data("{\"metadata\":{\"sourceSignature\":\"s\",\"outputSignature\":\"o\",\"policy\":{\"allowCPUConversion\":false}},\"unknownFutureField\":42}".utf8)
    XCTAssertEqual(try JSONDecoder().decode(RecordingTakeSidecar.Snapshot.self, from: legacy).counters, [:])
    XCTAssertThrowsError(try store.append(.init(kind: "late", detail: "late")))
    XCTAssertThrowsError(try RecordingTakeSidecar(movieURL: movie, metadata: .init(sourceSignature: "s", outputSignature: "o")))
  }
  func testFailedSnapshotWritesCanRetryWithoutClosingOrDuplicatingJournal() throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let store = try RecordingTakeSidecar(movieURL: folder.appendingPathComponent("take.mov"),
      metadata: .init(sourceSignature: "s", outputSignature: "o"))
    let backup = folder.appendingPathComponent("snapshot-backup")
    func blockSnapshot() throws {
      try fm.moveItem(at: store.url, to: backup)
      try fm.createDirectory(at: store.url, withIntermediateDirectories: false)
      try Data("block".utf8).write(to: store.url.appendingPathComponent("child"))
    }
    func unblockSnapshot() throws {
      try fm.removeItem(at: store.url)
      try fm.moveItem(at: backup, to: store.url)
    }
    try blockSnapshot()
    XCTAssertThrowsError(try store.finish(finalError: "retry"))
    XCTAssertFalse(store.snapshot.finished)
    try unblockSnapshot()
    try blockSnapshot()
    XCTAssertThrowsError(try store.append(.init(kind: "quantization", detail: "original")))
    XCTAssertEqual(store.snapshot.journalBytes, 0)
    XCTAssertEqual(try Data(contentsOf: store.journalURL).count, 0)
    try unblockSnapshot()
    try store.append(.init(kind: "quantization", detail: "original"))
    XCTAssertEqual(try String(contentsOf: store.journalURL, encoding: .utf8).split(separator: "\n").count, 1)
    try blockSnapshot()
    XCTAssertThrowsError(try store.updateCounters(["cpu": 2]))
    XCTAssertEqual(store.snapshot.counters, [:])
    try unblockSnapshot()
    try store.finish(finalError: "retry")
    XCTAssertTrue(store.snapshot.finished)
  }

  func testOldMinimalMetadataAndFutureOutputDescriptorRemainReadable() throws {
    let minimal = Data("{\"metadata\":{\"sourceSignature\":\"s\",\"outputSignature\":\"o\"}}".utf8)
    let old = try? JSONDecoder().decode(RecordingTakeSidecar.Snapshot.self, from: minimal)
    XCTAssertNotNil(old)
    XCTAssertEqual(old?.metadata.policy, RecordingCompatibilityPolicy())
    XCTAssertEqual(old?.counters, [:])
    let future = Data("{\"metadata\":{\"sourceSignature\":\"s\",\"outputSignature\":\"o\",\"policy\":{\"allowCPUConversion\":false},\"outputContract\":{\"version\":99,\"sourceFormat\":{\"futureFormat\":true},\"encoderInputPixelFormat\":1,\"codec\":1}}}".utf8)
    let newer = try? JSONDecoder().decode(RecordingTakeSidecar.Snapshot.self, from: future)
    XCTAssertNotNil(newer)
    XCTAssertNil(newer?.metadata.outputContract)
    XCTAssertEqual(newer?.metadata.sourceSignature, "s")
  }

}
