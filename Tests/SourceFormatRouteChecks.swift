import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import XCTest

/// Actual source storage -> declared-source GPU encoder -> published camera contract.
@objcMembers final class SourceFormatRouteChecks: XCTestCase {
  func testMacCameraModesReachTypedCaptureConsumersBeforeOutputNegotiation() throws {
    let duration = FrameRateTarget.fps30.duration
    for size in [ResizeTarget.hd720, .hd1080] {
      for pixel in [PixelFormatID.video420, .full420, .twoVuy] {
        let fixture = try SourceRouteFixture(pixel: pixel, width: size.width, height: size.height)
        let format = try SourceFormat(width: size.width, height: size.height, pixel: pixel,
          colour: fixture.format.colour, rate: .constant(duration), clock: .hostTime)
        for sampleRate in [44100, 48000] {
          try assertTypedMacCameraRoute(fixture.image, format: format, sampleRate: sampleRate)
        }
        var configuration = PipelineConfiguration(downscale: false, convertTo420: false)
        configuration.sourceWidth = format.width
        configuration.sourceHeight = format.height
        configuration.sourceDuration = duration
        if pixel == .video420 {
          let description = try CameraSink.requestedFormat(configuration: configuration,
            passthroughFormat: pixel.rawValue, sourceFormat: format)
          let output = DerivedOutputContract(format: description, duration: duration)
          XCTAssertNotNil(output.matchingPublishedIndex(in: try OutputFormatCatalog.descriptions()))
        } else {
          XCTAssertThrowsError(try CameraSink.requestedFormat(configuration: configuration,
            passthroughFormat: pixel.rawValue, sourceFormat: format)) {
            XCTAssertTrue($0.localizedDescription.contains("choose a supported Color format"))
          }
        }
      }
    }
  }

  private func assertTypedMacCameraRoute(_ image: CVPixelBuffer, format: SourceFormat, sampleRate: Int) throws {
    let audio = try SourceAudioFormat(sampleRate: Double(sampleRate), channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
    let plugin = FakeCapturePlugin(format: format, audio: .present(audio))
    let feed = FeedID(rawValue: "mac-camera-route")
    let label = "\(format.width)x\(format.height) \(format.pixel) \(sampleRate) Hz"
    let previewed = expectation(description: "\(label) owned bypass preview")
    let inputIdentity = UInt(bitPattern: Unmanaged.passUnretained(image).toOpaque())
    var services = CaptureServices.registryBridge(feedID: feed, makeSession: { _ in plugin.makeSession() })
    services.preview = { sample in
      guard let preview = CMSampleBufferGetImageBuffer(sample) else {
        XCTFail("Missing image in \(label) preview")
        return
      }
      XCTAssertNotEqual(UInt(bitPattern: Unmanaged.passUnretained(preview).toOpaque()), inputIdentity, label)
      XCTAssertEqual(CVPixelBufferGetWidth(preview), format.width, label)
      XCTAssertEqual(CVPixelBufferGetHeight(preview), format.height, label)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(preview), format.pixel.rawValue, label)
      XCTAssertEqual(CMSampleBufferGetDuration(sample), format.rate.nominal, label)
      previewed.fulfill()
    }
    let controller = CaptureController(services: services)
    controller.setCameraOutputEnabled(false)
    defer { controller.onUpdate = nil; controller.stop() }
    let monitored = expectation(description: "\(label) monitor source")
    let monitor = RouteMonitor(width: format.width, height: format.height, type: format.pixel.rawValue, offered: monitored)
    controller.setMonitorSink(monitor)
    let started = expectation(description: "\(label) capture startup")
    let recorded = expectation(description: "\(label) native video admission")
    let heard = expectation(description: "\(label) independent PCM admission")
    let start = CMClockGetTime(CMClockGetHostTimeClock())
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, _ in false }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in false },
      videoWithAdmission: { source, metadata, admission, admitted in
        XCTAssertTrue(admitted, label)
        XCTAssertEqual(UInt(bitPattern: Unmanaged.passUnretained(source).toOpaque()), inputIdentity, label)
        XCTAssertEqual(metadata.presentationTime, start, label)
        XCTAssertEqual(metadata.duration, format.rate.nominal, label)
        XCTAssertEqual(admission.format, format, label)
        recorded.fulfill()
        return admitted
      },
      sourceAudioWithAdmission: { planes, frames, declared, pts, _, _, pair in
        XCTAssertNil(pair, label)
        XCTAssertEqual(declared, audio, label)
        XCTAssertEqual(frames, sampleRate / 30, label)
        XCTAssertEqual(planes.map(\.count), [frames * MemoryLayout<Float32>.size], label)
        XCTAssertEqual(pts, start, label)
        heard.fulfill()
        return true
      }))
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { started.fulfill() } }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: true)
    wait(for: [started], timeout: 3)
    controller.onUpdate = nil
    let session = try XCTUnwrap(plugin.sessions.first)
    let mapping = try ClockMapping(sourceAnchor: start, hostAnchor: start, rate: .one)
    let videoClock = session.context
    XCTAssertTrue(session.submit(.event(.clockMappingChanged(CaptureClockMappingUpdate(
      epochID: videoClock.epochID, clockID: videoClock.clockBindings.video, revision: 1,
      effectiveSequence: videoClock.nextSequence + 1, mapping: mapping)))), label)
    let audioClock = session.context
    XCTAssertTrue(session.submit(.event(.clockMappingChanged(CaptureClockMappingUpdate(
      epochID: audioClock.epochID, clockID: try XCTUnwrap(audioClock.clockBindings.audio), revision: 2,
      effectiveSequence: audioClock.nextSequence + 1, mapping: mapping)))), label)
    let context = session.context
    let frame = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
      presentationTime: start, duration: format.rate.nominal, signalValid: true, timecode: nil)
    let frames = sampleRate / 30
    let packet = try CaptureAudioPacket(planes: [Data(count: frames * MemoryLayout<Float32>.size)],
      sampleFrameCount: frames, format: audio, packetTime: start)
    XCTAssertTrue(session.submitGroup([.frame(CapturedPixelBuffer(immutable: image), frame), .rawAudio(packet)]), label)
    wait(for: [recorded, heard, monitored, previewed], timeout: 8)
    withExtendedLifetime(monitor) {}
  }

  func testNativeCameraBypassPreservesPixelsRangeAndUnspecifiedColour() throws {
    let processor = try LUTProcessor()
    for (width, height) in [(1280, 720), (1920, 1080)] {
      for pixel in [PixelFormatID.video420, .full420, .twoVuy] {
        let fixture = try SourceRouteFixture(pixel: pixel, width: width, height: height)
        let colour = Colorimetry(primaries: .unspecified, transfer: .unspecified,
          matrix: pixel == .twoVuy ? .rec601 : .unspecified, range: fixture.format.colour.range,
          horizontalChromaSiting: .unspecified, verticalChromaSiting: .unspecified)
        let format = try SourceFormat(width: width, height: height, pixel: pixel, colour: colour,
          rate: .constant(FrameRateTarget.fps30.duration))
        let source = try SourceAdmissionSnapshot(format: format,
          epochID: CaptureEpochID(sessionID: UUID(), epoch: 0),
          clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .capture)
        let metadata = SourceAdmissionMetadata(pixelBuffer: fixture.image, presentationTime: .zero,
          duration: format.rate.nominal, epochID: source.epochID, formatSignature: source.formatSignature)
        if pixel == .twoVuy {
          // A valid producer tag that the typed transfer enum cannot express.
          CVBufferSetAttachment(fixture.image, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_240M_1995, .shouldNotPropagate)
        }
        try source.validate(metadata, stage: .capture)
        let done = expectation(description: "Native bypass \(width) \(VideoContract.fourCC(pixel.rawValue))")
        let result = Mutex<Result<CVPixelBuffer, Error>?>(nil)
        try processor.submitPassthrough(fixture.image, source: source, metadata: metadata) { completion in
          result.withLock { $0 = completion.result }
          done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let output = try XCTUnwrap(result.withLock { $0 }).get()
        XCTAssertFalse(output === fixture.image)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(output))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), pixel.rawValue)
        XCTAssertEqual(CVPixelBufferGetWidth(output), width)
        XCTAssertEqual(CVPixelBufferGetHeight(output), height)
        XCTAssertEqual(try LUTProcessor.sourceColorimetry(output), colour)
        XCTAssertNil(CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, nil))
        if pixel == .twoVuy {
          XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String,
            kCVImageBufferTransferFunction_SMPTE_240M_1995 as String)
        } else {
          XCTAssertNil(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil))
        }
        XCTAssertEqual(CVBufferCopyAttachment(output, kCMFormatDescriptionExtension_FullRangeVideo, nil) as? Bool,
          colour.range == .full)
        try assertActiveRowsEqual(fixture.image, output)
      }
    }
  }

  func testOrdinaryCameraBufferIsAdmittedAndTheLiveGPUPathsRefuseIt() throws {
    let processor = try LUTProcessor()
    for pixel in [PixelFormatID.video420, .full420, .twoVuy] {
      let fixture = try SourceRouteFixture(pixel: pixel, shareable: false)
      let source = try SourceAdmissionSnapshot(format: fixture.format,
        epochID: CaptureEpochID(sessionID: UUID(), epoch: 0),
        clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .capture)
      let metadata = SourceAdmissionMetadata(pixelBuffer: fixture.image, presentationTime: .zero,
        duration: fixture.format.rate.nominal, epochID: source.epochID, formatSignature: source.formatSignature)
      try source.validate(metadata, stage: .capture)
      XCTAssertThrowsError(try processor.submitPassthrough(fixture.image, source: source, metadata: metadata) { _ in
        XCTFail("Ordinary storage must not produce an owned GPU-copy completion")
      }) { error in
        guard case .unshareableStorage = error as? LiveFrameRouteError else { return XCTFail("\(error)") }
      }
      XCTAssertThrowsError(try processor.submit(fixture.image, configuration: PipelineConfiguration(),
        source: source, metadata: metadata) { _ in XCTFail("Ordinary storage must not reach GPU effects") }) { error in
        guard case .unshareableStorage = error as? LiveFrameRouteError else { return XCTFail("\(error)") }
      }
    }
  }

  private func assertActiveRowsEqual(_ input: CVPixelBuffer, _ output: CVPixelBuffer) throws {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(input, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
    XCTAssertEqual(CVPixelBufferLockBaseAddress(output, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
    if CVPixelBufferIsPlanar(input) {
      for plane in 0..<2 {
        let source = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(input, plane))
        let target = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, plane))
        for row in 0..<CVPixelBufferGetHeightOfPlane(input, plane) {
          XCTAssertEqual(memcmp(source.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(input, plane)),
            target.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(output, plane)), width), 0)
        }
      }
    } else {
      let source = try XCTUnwrap(CVPixelBufferGetBaseAddress(input))
      let target = try XCTUnwrap(CVPixelBufferGetBaseAddress(output))
      for row in 0..<height {
        XCTAssertEqual(memcmp(source.advanced(by: row * CVPixelBufferGetBytesPerRow(input)),
          target.advanced(by: row * CVPixelBufferGetBytesPerRow(output)), width * 2), 0)
      }
    }
  }

  func testEveryNewSourceReachesAnExactPublishedProcessedCameraFormat() throws {
    let catalog = try OutputFormatCatalog.descriptions()
    for pixel in [PixelFormatID.twoVuy, .yuvs, .video420, .full420, .bgra8, .r210, .r12L, .uyva, .p216, .i420, .pa16] {
      for size in [ResizeTarget.hd720, .hd1080] {
        do {
          let width = pixel == .r12L ? (size == .hd720 ? 3840 : 4096) : 128
          let fixture = try SourceRouteFixture(pixel: pixel, width: width)
          let processor = try LUTProcessor()
          defer { processor.releaseIdleResources() }
          try processor.load(CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 })),
            colorSpace: LUTColorSpaceContract(input: fixture.format.colour, output: .rec709Video))
          var configuration = PipelineConfiguration(applyLUT: true, downscale: true)
          configuration.resizeTarget = size
          configuration.sourceWidth = fixture.format.width
          configuration.sourceHeight = fixture.format.height
          configuration.sourceDuration = VideoContract.fastDuration
          configuration.lutOutputColorimetry = .rec709Video
          let snapshot = try SourceAdmissionSnapshot(format: fixture.format,
            epochID: CaptureEpochID(sessionID: UUID(), epoch: 0),
            clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .lut)
          let metadata = SourceAdmissionMetadata(pixelBuffer: fixture.image, presentationTime: .zero,
            duration: VideoContract.fastDuration, epochID: snapshot.epochID, formatSignature: snapshot.formatSignature)
          let completed = expectation(description: "production GPU completion")
          let result = Mutex<Result<CVPixelBuffer, Error>?>(nil)
          try processor.submit(fixture.image, configuration: configuration, source: snapshot, metadata: metadata) { completion in
            result.withLock { $0 = completion.result }; completed.fulfill()
          }
          wait(for: [completed], timeout: 10)
          let output = try XCTUnwrap(result.withLock { $0 }).get()
          XCTAssertFalse(output === fixture.image)
          XCTAssertEqual(CVPixelBufferGetWidth(output), size.width)
          XCTAssertEqual(CVPixelBufferGetHeight(output), size.height)
          let sample = try VideoContract.sample(output, at: .zero, duration: configuration.duration)
          let requested = try CameraSink.requestedFormat(configuration: configuration,
            passthroughFormat: pixel.rawValue, sourceFormat: fixture.format)
          XCTAssertNil(CameraSink.mismatch(sample, format: requested, duration: configuration.duration))
          let derived = DerivedOutputContract(format: requested, duration: configuration.duration)
          let index = try XCTUnwrap(derived.matchingPublishedIndex(in: catalog))
          XCTAssertTrue(OutputFormatCatalog.matches(sample, description: catalog[index]))
          XCTAssertNil(derived.mismatch(sample))
          // Read only the finished result: a nonlinear LUT turns 50% gray into 25%.
          CVPixelBufferLockBaseAddress(output, .readOnly)
          defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
          let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt8.self)
          let middle = size.height / 2 * CVPixelBufferGetBytesPerRowOfPlane(output, 0) + size.width / 2
          XCTAssertEqual(Int(y[middle]), 71, accuracy: 2, "Source pixels must actually decode and pass through the LUT")
        }
      }
    }
  }
}

private final class RouteMonitor: MonitorFrameSink, @unchecked Sendable {
  let width: Int
  let height: Int
  let type: OSType
  let offered: XCTestExpectation

  init(width: Int, height: Int, type: OSType, offered: XCTestExpectation) {
    self.width = width
    self.height = height
    self.type = type
    self.offered = offered
  }

  func offer(_ image: CVPixelBuffer, pts: CMTime, captureGeneration: UInt64, sequence: UInt64, untouched: Bool) {
    XCTAssertEqual(CVPixelBufferGetWidth(image), width)
    XCTAssertEqual(CVPixelBufferGetHeight(image), height)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), type)
    XCTAssertTrue(untouched)
    offered.fulfill()
  }

  func invalidate(rejectingCaptureGeneration rejected: UInt64?) {}
}
