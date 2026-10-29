import AVFoundation
import Foundation
import XCTest

@objcMembers final class CPUCompatibilityActivityChecks: XCTestCase {
  private final class Writer: SourceRecordingWriter {
    var value = SourceRecordingWriterTelemetry()
    var telemetry: SourceRecordingWriterTelemetry { value }
    func start() throws {}
    func appendVideo(_ sample: CMSampleBuffer) throws {}
    func appendAudio(_ sample: CMSampleBuffer) throws {}
    func finish() throws {}
  }
  func testCompatibilityActivityTracksRecentFramesAndPreservesTotals() throws {
    let writer = Writer()
    let core = try SourceRecorderCore(configuration: SourceRecordingConfiguration(
      feedID: .init("compatibility-activity"), outputURL: URL(fileURLWithPath: "/tmp/unused-compatibility-activity.mov"), width: 16, height: 16), writerFactory: { writer })
    try core.start()
    var sampler = RecordingStatisticsSampler()
    let policy = RecordingCompatibilityPolicy(allowCPUConversion: true)
    _ = sampler.sample(core.telemetry, elapsed: 0, fileBytes: 0, fileURL: nil, now: 1, compatibilityPolicy: policy)
    writer.value.systemCompatibilityFrames = 1
    writer.value.gpuConversionFailures = 1
    let active = sampler.sample(core.telemetry, elapsed: 1, fileBytes: 0, fileURL: nil, now: 2, compatibilityPolicy: policy)
    XCTAssertEqual(active.systemCompatibilityFrames, 1)
    XCTAssertTrue(active.compatibilityConversionActive)
    XCTAssertEqual(active.compatibilityPolicy, policy)
    XCTAssertEqual(active.gpuConversionFailures, 1)
    let quiet = sampler.sample(core.telemetry, elapsed: 2, fileBytes: 0, fileURL: nil, now: 3, compatibilityPolicy: policy)
    XCTAssertFalse(quiet.compatibilityConversionActive)
    XCTAssertEqual(quiet.systemCompatibilityFrames, 1)
    try core.pause()
    writer.value.systemCompatibilityFrames = 2
    let paused = sampler.sample(core.telemetry, elapsed: 2, fileBytes: 0, fileURL: nil, now: 4, compatibilityPolicy: policy)
    XCTAssertFalse(paused.compatibilityConversionActive)
    try core.resume()
    writer.value.systemCompatibilityFrames = 3
    let resumed = sampler.sample(core.telemetry, elapsed: 3, fileBytes: 0, fileURL: nil, now: 5, compatibilityPolicy: policy)
    XCTAssertTrue(resumed.compatibilityConversionActive)
    let stopped = sampler.sample(core.telemetry, elapsed: 3, fileBytes: 0, fileURL: nil, now: 6, stopped: true, compatibilityPolicy: policy)
    XCTAssertFalse(stopped.compatibilityConversionActive)
    XCTAssertEqual(stopped.systemCompatibilityFrames, 3)
  }
  @MainActor func testCompatibilityBadgeIsPerCameraAndHiddenOutsideRecording() {
    var camera = UICameraRecording(status: .recording)
    camera.systemCompatibilityFrames = 2
    camera.compatibilityConversionActive = true
    XCTAssertEqual(camera.compatibilityBadge, "Compatibility conversion · Recording · 2")
    XCTAssertNil(UICameraRecording(status: .recording).compatibilityBadge)
    camera.status = .paused
    XCTAssertNil(camera.compatibilityBadge)
    camera.status = .recording; camera.compatibilityConversionActive = false
    XCTAssertNil(camera.compatibilityBadge)
    XCTAssertEqual(camera.systemCompatibilityFrames, 2)
  }
}
