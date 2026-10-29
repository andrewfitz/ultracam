import AVFoundation
import CoreVideo
import Synchronization
import XCTest

@objcMembers final class RecordingTakeLifecycleChecks: XCTestCase {
  private enum Injected: Error { case metadata }
  func testResolvedAudioAdmissionDoesNotFabricateAbsenceOrUnsupportedTracks() throws {
    let source = try snapshot()
    XCTAssertThrowsError(try RecordingTakeContext(sourceAdmission: source, audioDeclaration: .unknown).validateCurrentAudio())
    XCTAssertNoThrow(try RecordingTakeContext(sourceAdmission: source, audioDeclaration: .absent).validateCurrentAudio())
    let unsupported = try SourceAudioFormat(sampleRate: 96000, channels: 6, sample: .float32,
      interleaved: true, layout: .init(), clock: .deviceClock)
    XCTAssertThrowsError(try RecordingTakeContext(sourceAdmission: source, audioDeclaration: .present(unsupported)).validateCurrentAudio())
    let supported = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: .init(), clock: .pairedWithFrames)
    XCTAssertNoThrow(try RecordingTakeContext(sourceAdmission: source, audioDeclaration: .present(supported)).validateCurrentAudio())
    let configuration = try SourceRecordingConfiguration(feedID: .init("audio-contract"),
      outputURL: URL(fileURLWithPath: "/tmp/unused-audio-contract.mov"), width: 3840, height: 2160)
    let writer = try AVAssetSourceRecordingWriter(configuration: configuration)
    XCTAssertThrowsError(try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .unknown)))
    XCTAssertThrowsError(try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .present(unsupported))))
    XCTAssertNoThrow(try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent)))
    XCTAssertThrowsError(try writer.appendAudio(sample())) { error in
      XCTAssertTrue(error.localizedDescription.contains("declared absent"), error.localizedDescription)
    }
  }
  func testBlockedSidecarIOLeavesCaptureBinderBoundedAndMetadataQueueCapped() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let source = try snapshot()
    let config = try SourceRecordingConfiguration(feedID: .init("metadata-bound"),
      outputURL: folder.appendingPathComponent("partial.mov"), width: 3840, height: 2160,
      videoCodec: kCMVideoCodecType_AppleProRes422HQ, sidecarMovieURL: folder.appendingPathComponent("final.mov"),
      sidecarCreated: { entered.signal(); release.wait() })
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { _, _, _, _ in noErr })
    let core = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    try core.start()
    let bound = Mutex<Result<Void, Error>?>(nil)
    let returned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      let result = Result { try core.bindTakeContext(.init(sourceAdmission: source,
        audioDeclaration: .absent, mappingRevision: 0)) }
      bound.withLock { $0 = result }
      returned.signal()
    }
    let didEnter = entered.wait(timeout: .now() + 2)
    let didReturn = returned.wait(timeout: .now() + 2)
    XCTAssertEqual(didEnter, .success)
    XCTAssertEqual(didReturn, .success, "Capture binding must return while sidecar I/O remains blocked")
    guard didEnter == .success, didReturn == .success else {
      release.signal()
      if didReturn != .success { _ = returned.wait(timeout: .now() + 2) }
      try? core.stop()
      return
    }
    try XCTUnwrap(bound.withLock { $0 }).get()
    for revision in 1...63 {
      try core.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent, mappingRevision: UInt64(revision)))
    }
    XCTAssertThrowsError(try core.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent, mappingRevision: 64)))
    XCTAssertEqual(core.state, .failed)
    release.signal()
    try core.stop()
    XCTAssertEqual(core.telemetry.enqueuedVideo, 0)
  }
  func testRealMovieFinalizesMetadataBeforePublishingAndPairsRecovery() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let manager = try RecordingOutputManager(rootDirectory: folder, minimumFreeBytes: 0)
    let output = try manager.beginExternalWriterSession(feedID: "camera")
    let source = try snapshot()
    let config = try SourceRecordingConfiguration(feedID: .init("metadata-real"), outputURL: output.temporaryURL,
      width: 3840, height: 2160, videoCodec: kCMVideoCodecType_AppleProRes422HQ,
      sourceAdmission: source, sidecarMovieURL: output.finalURL, sidecarCreated: { try output.claimSidecar() })
    let writer = try AVAssetSourceRecordingWriter(configuration: config)
    try writer.start()
    try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent, mappingRevision: 7))
    try writer.appendVideo(sample())
    try writer.finish()
    let metadata = try JSONDecoder().decode(RecordingTakeSidecar.Snapshot.self,
      from: Data(contentsOf: RecordingTakeSidecar.url(for: output.finalURL)))
    XCTAssertTrue(metadata.finished)
    XCTAssertEqual(metadata.metadata.epoch, source.epochID)
    XCTAssertEqual(metadata.metadata.audioDeclaration, .absent)
    XCTAssertEqual(metadata.metadata.mappingRevision, 7)
    XCTAssertNil(metadata.metadata.videoMapping)
    XCTAssertNotEqual(metadata.metadata.sourceSignature, metadata.metadata.outputSignature)
    output.preserveForRecovery()
    let interrupted = try XCTUnwrap(RecordingRecovery.scan(root: folder).first)
    let result = Mutex<Result<URL, Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      let recovered: Result<URL, Error>
      do { recovered = .success(try await RecordingRecovery.recover(interrupted, root: folder)) }
      catch { recovered = .failure(error) }
      result.withLock { $0 = recovered }; done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now() + 15), .success)
    let recovered = try XCTUnwrap(result.withLock { $0 }).get()
    XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.path))
    XCTAssertEqual(try Data(contentsOf: RecordingTakeSidecar.url(for: recovered)),
      try Data(contentsOf: RecordingTakeSidecar.url(for: output.finalURL)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.temporaryURL.path))
  }
  func testOwnedCancellationDeletesPairAndPreservesUnrelatedOccupiedMetadata() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let manager = try RecordingOutputManager(rootDirectory: folder, minimumFreeBytes: 0)
    let source = try snapshot()
    let owned = try manager.beginExternalWriterSession(feedID: "owned")
    let config = try SourceRecordingConfiguration(feedID: .init("owned"), outputURL: owned.temporaryURL,
      width: 3840, height: 2160, sidecarMovieURL: owned.finalURL, sidecarCreated: { try owned.claimSidecar() })
    let writer = try AVAssetSourceRecordingWriter(configuration: config)
    try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
    try owned.cancel()
    XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingTakeSidecar.url(for: owned.finalURL).path))
    let other = try manager.beginExternalWriterSession(feedID: "other")
    let foreign = RecordingTakeSidecar.url(for: other.finalURL)
    try Data("foreign".utf8).write(to: foreign)
    let otherConfig = try SourceRecordingConfiguration(feedID: .init("other"), outputURL: other.temporaryURL,
      width: 3840, height: 2160, sidecarMovieURL: other.finalURL, sidecarCreated: { try other.claimSidecar() })
    let occupied = try AVAssetSourceRecordingWriter(configuration: otherConfig)
    XCTAssertThrowsError(try occupied.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent)))
    try other.cancel()
    XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign".utf8))
  }
  func testMoviePublicationRequiresFinishedOwnedMetadata() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let manager = try RecordingOutputManager(rootDirectory: folder, minimumFreeBytes: 0)
    let unfinished = try manager.beginExternalWriterSession(feedID: "unfinished")
    let metadata = try RecordingTakeSidecar(movieURL: unfinished.finalURL,
      metadata: .init(sourceSignature: "source", outputSignature: "output"))
    try unfinished.claimSidecar()
    try Data("fragment".utf8).write(to: unfinished.temporaryURL)
    XCTAssertThrowsError(try unfinished.finish())
    XCTAssertFalse(FileManager.default.fileExists(atPath: unfinished.finalURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.url.path))
    let completed = try manager.beginExternalWriterSession(feedID: "completed")
    let ready = try RecordingTakeSidecar(movieURL: completed.finalURL,
      metadata: .init(sourceSignature: "source", outputSignature: "output"))
    try completed.claimSidecar()
    try ready.finish()
    try Data("movie".utf8).write(to: completed.temporaryURL)
    XCTAssertEqual(try completed.finish(), completed.finalURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: ready.url.path))
  }

  func testJournalPreservationFailureClosesAdmissionBeforeQueuedMedia() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try snapshot()
    let final = folder.appendingPathComponent("final.mov")
    let config = try SourceRecordingConfiguration(feedID: .init("journal-failure"),
      outputURL: folder.appendingPathComponent("partial.mov"), width: 3840, height: 2160,
      videoCodec: kCMVideoCodecType_AppleProRes422HQ, sourceAdmission: source, sidecarMovieURL: final)
    var submissions = 0
    let writer = try AVAssetSourceRecordingWriter(configuration: config,
      encodeFrame: { _, _, _, _ in submissions += 1; return noErr }, maximumSidecarJournalBytes: 1)
    let core = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    try core.start()
    try core.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent, mappingRevision: 0))
    let mapping = try ClockMapping(sourceAnchor: .zero, hostAnchor: CMTime(value: 100, timescale: 1), rate: .one)
    try core.noteClockMapping(.init(epochID: source.epochID, clockID: source.clockBindings.video,
      revision: 1, effectiveSequence: 2, mapping: mapping))
    _ = core.appendVideo(try sample())
    try core.stop()
    XCTAssertEqual(submissions, 0)
    XCTAssertEqual(core.state, .failed)
    XCTAssertTrue(core.telemetry.lastError?.contains("metadata") == true)
    XCTAssertFalse(core.appendVideo(try sample()))
    let metadata = try RecordingTakeSidecar.readSnapshot(for: final)
    XCTAssertTrue(metadata.finished)
    XCTAssertNotNil(metadata.finalError)
  }

  func testSidecarTimescaleMatchesActualMovieForEquivalent2997Declarations() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for (index, declaredDuration) in [CMTime(value: 2002, timescale: 60000), CMTime(value: 1001, timescale: 30000)].enumerated() {
      let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(declaredDuration))
      let source = try SourceAdmissionSnapshot(format: format, epochID: .init(sessionID: UUID(), epoch: 0),
        clockBindings: .init(video: .init(), audio: nil), stage: .recordingSource)
      let movie = folder.appendingPathComponent("rate-\(index).mov")
      let config = try SourceRecordingConfiguration(feedID: .init("rate-\(index)"), outputURL: movie,
        width: 3840, height: 2160, videoCodec: kCMVideoCodecType_AppleProRes422HQ,
        frameRate: .fps2997, sourceAdmission: source, sidecarMovieURL: movie)
      let writer = try AVAssetSourceRecordingWriter(configuration: config)
      try writer.start()
      try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
      try writer.appendVideo(sample(duration: declaredDuration))
      try writer.finish()
      let metadata = try RecordingTakeSidecar.readSnapshot(for: movie)
      let result = Mutex<Result<Int32, Error>?>(nil)
      let done = DispatchSemaphore(value: 0)
      Task.detached {
        let scale: Result<Int32, Error>
        do {
          let tracks = try await AVURLAsset(url: movie).loadTracks(withMediaType: .video)
          guard let video = tracks.first else { throw NSError(domain: "MissingVideo", code: 1) }
          scale = .success(try await video.load(.naturalTimeScale))
        } catch { scale = .failure(error) }
        result.withLock { $0 = scale }; done.signal()
      }
      XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
      let actual = try XCTUnwrap(result.withLock { $0 }).get()
      XCTAssertEqual(actual, 30000)
      XCTAssertEqual(metadata.metadata.timestampTimescale, actual)
    }
  }

  private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
  private func snapshot() throws -> SourceAdmissionSnapshot {
    try SourceAdmissionSnapshot(format: SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(RecordingFrameRate.fps5994.frameDuration)), epochID: .init(sessionID: UUID(), epoch: 0),
      clockBindings: .init(video: .init(), audio: nil), stage: .recordingSource)
  }
  private func sample(duration: CMTime = RecordingFrameRate.fps5994.frameDuration) throws -> CMSampleBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
      formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: duration,
      presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }
}
