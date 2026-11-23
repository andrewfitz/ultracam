#if CAPTURE_LIFECYCLE_TESTS
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class MacCameraVideoChecks: XCTestCase {
  private static let duration30 = CMTime(value: 1, timescale: 30)
  private static let duration15 = CMTime(value: 1, timescale: 15)

  func testNativeVideoKeepsPixelStorageAndImageInterpretation() throws {
    for (pixel, range, surfaceBacked) in [
      (PixelFormatID.video420, Colorimetry.Range.video, true), (.full420, .full, false)
    ] {
      let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
      let transcript = MacCameraVideoTranscript()
      defer { session.stop() }
      session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }))
      let timestamp = CMTime(value: 211, timescale: 30)
      let sample = try Self.sample(at: timestamp, duration: Self.duration30, pixel: pixel,
        surfaceBacked: surfaceBacked, tags: [
          (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
          (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG),
          (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020),
          (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left)
        ])
      session.deliverFixtureFrame(sample)
      let (declaration, format) = try XCTUnwrap(transcript.declarations.first)
      let frame = try XCTUnwrap(transcript.frames.first)
      let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))

      XCTAssertEqual(transcript.frames.count, 1)
      XCTAssertTrue(frame.buffer === image)
      XCTAssertEqual(CVPixelBufferGetIOSurface(frame.buffer) != nil, surfaceBacked)
      XCTAssertEqual(frame.info.presentationTime, timestamp)
      XCTAssertEqual(frame.info.duration, Self.duration30)
      XCTAssertEqual(format.width, 640)
      XCTAssertEqual(format.height, 480)
      XCTAssertEqual(format.pixel, pixel)
      XCTAssertEqual(format.colour.range, range)
      XCTAssertEqual(format.colour.primaries, .rec2020)
      XCTAssertEqual(format.colour.transfer, .hlg)
      XCTAssertEqual(format.colour.matrix, .rec2020)
      XCTAssertEqual(format.colour.horizontalChromaSiting, .left)
      XCTAssertEqual(format.colour.verticalChromaSiting, .center)
      XCTAssertLessThan(declaration.sequence, frame.delivery.sequence)
      let admission = try SourceAdmissionSnapshot(format: format, epochID: declaration.epochID,
        clockBindings: declaration.clockBindings, stage: .capture)
      try admission.validate(SourceAdmissionMetadata(pixelBuffer: frame.buffer,
        presentationTime: frame.info.presentationTime, duration: frame.info.duration,
        epochID: frame.info.epochID, formatSignature: frame.info.formatSignature), stage: .capture)
    }
  }

  func testVideoGeometryChangeStartsAnOrderedEpochAndKeepsMissingTagsUnspecified() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }))
    session.deliverFixtureFrame(try Self.sample(at: .zero, duration: Self.duration30))
    session.deliverFixtureFrame(try Self.sample(at: Self.duration30, duration: Self.duration30, width: 1280,
      height: 720))

    XCTAssertEqual(transcript.declarations.count, 2)
    XCTAssertEqual(transcript.frames.count, 2)
    let (first, oldFormat) = try XCTUnwrap(transcript.declarations.first)
    let (second, newFormat) = try XCTUnwrap(transcript.declarations.last)
    let oldFrame = try XCTUnwrap(transcript.frames.first)
    let newFrame = try XCTUnwrap(transcript.frames.last)
    XCTAssertNotEqual(first.epochID, second.epochID)
    XCTAssertEqual(oldFrame.info.epochID, first.epochID)
    XCTAssertEqual(newFrame.info.epochID, second.epochID)
    XCTAssertEqual(newFrame.info.formatSignature, newFormat.signature)
    XCTAssertEqual(oldFormat.width, 640)
    XCTAssertEqual(newFormat.width, 1280)
    XCTAssertEqual(newFormat.height, 720)
    XCTAssertEqual(newFormat.colour.primaries, .unspecified)
    XCTAssertEqual(newFormat.colour.transfer, .unspecified)
    XCTAssertEqual(newFormat.colour.matrix, .unspecified)
    XCTAssertLessThan(oldFrame.delivery.sequence, second.sequence)
    XCTAssertLessThan(second.sequence, newFrame.delivery.sequence)
    XCTAssertTrue(transcript.deliveries.contains { delivery in
      guard case .event(.discontinuity) = delivery.payload else { return false }
      return oldFrame.delivery.sequence < delivery.sequence && delivery.sequence < newFrame.delivery.sequence
    })
  }

  func testUnqualifiedNativeHDRDoesNotPublishAnEightBitDeclaration() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }))
    let nativeHDR = PixelFormatID(rawValue: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    session.deliverFixtureFrame(try Self.sample(at: .zero, duration: Self.duration30, pixel: nativeHDR,
      tags: [(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG)]))

    XCTAssertTrue(transcript.frames.isEmpty)
    XCTAssertTrue(transcript.declarations.isEmpty)
    XCTAssertTrue(transcript.deliveries.contains { delivery in
      guard case .event(.unsupportedInput(let message)) = delivery.payload else { return false }
      return message.contains("x420") && message.contains("Hardware")
    })
  }

  func testSelectedDimensionsRejectResizedDeliveryAndAdmitRotationAndActiveModeChanges() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    let subtype = PixelFormatID.video420.rawValue
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }), rate: .constant(Self.duration30),
      native: subtype, dimensions: CMVideoDimensions(width: 1920, height: 1080))
    func deliver(_ index: Int64, width: Int, height: Int) throws {
      session.deliverFixtureFrame(try Self.sample(at: CMTime(value: index, timescale: 30),
        duration: Self.duration30, width: width, height: height))
    }

    try deliver(0, width: 1280, height: 720)
    XCTAssertTrue(transcript.declarations.isEmpty)
    XCTAssertTrue(transcript.frames.isEmpty)
    try deliver(1, width: 1920, height: 1080)
    try deliver(2, width: 1280, height: 720)
    XCTAssertEqual(transcript.frames.count, 1)
    XCTAssertEqual(transcript.declarations.count, 1)
    XCTAssertTrue(transcript.deliveries.contains { delivery in
      guard case .event(.unsupportedInput(let message)) = delivery.payload else { return false }
      return message.contains("1920 × 1080") && message.contains("1280 × 720") && message.contains("Hardware")
    })

    try deliver(3, width: 1080, height: 1920)
    session.setFixtureDimensions(CMVideoDimensions(width: 1280, height: 720))
    try deliver(4, width: 1280, height: 720)
    XCTAssertEqual(transcript.declarations.map { $0.0.epochID.epoch }, [0, 1, 2])
    XCTAssertEqual(transcript.declarations.map { [$0.1.width, $0.1.height] },
      [[1920, 1080], [1080, 1920], [1280, 720]])
    XCTAssertEqual(transcript.frames.map(\.info.presentationTime),
      [1, 3, 4].map { CMTime(value: $0, timescale: 30) })
    XCTAssertEqual(transcript.frames.map(\.info.epochID.epoch), [0, 1, 2])
  }

  func testDriverSuppliedEightBitSDRRequiresConsentForSelectedHDRMode() throws {
    let native = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    let output = PixelFormatID.video420
    let sample = try Self.sample(at: .zero, duration: Self.duration30, pixel: output, tags: [
      (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
      (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
      (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    ])
    let consent = VendorSettingValue.choice("hdr-mode:\(output.rawValue)")
    XCTAssertNil(MacCameraCapturePlugin.parseFallback(consent, modeID: "other-hdr-mode"))
    let approved = try XCTUnwrap(MacCameraCapturePlugin.parseFallback(consent, modeID: "hdr-mode"))
    for fallback in [nil, PixelFormatID.full420.rawValue, approved] {
      let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
      let transcript = MacCameraVideoTranscript()
      defer { session.stop() }
      session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }), native: native, fallback: fallback)
      session.deliverFixtureFrame(sample)
      if fallback == approved {
        let (_, format) = try XCTUnwrap(transcript.declarations.first)
        let frame = try XCTUnwrap(transcript.frames.first)
        XCTAssertEqual(format.pixel, output)
        XCTAssertEqual(format.colour.transfer, .rec709)
        XCTAssertTrue(frame.buffer === CMSampleBufferGetImageBuffer(sample))
      } else {
        XCTAssertTrue(transcript.frames.isEmpty)
        XCTAssertTrue(transcript.declarations.isEmpty)
        XCTAssertTrue(transcript.deliveries.contains { delivery in
          guard case .event(.unsupportedInput(let message)) = delivery.payload else { return false }
          return message.contains("x420") && message.contains("420v") && message.contains("Input Delivery")
        })
      }
    }
  }

  func testContradictoryRangeIsRefusedBeforeDeclaring() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }))
    session.deliverFixtureFrame(try Self.sample(at: .zero, duration: Self.duration30,
      tags: [(kCMFormatDescriptionExtension_FullRangeVideo, kCFBooleanTrue)]))

    XCTAssertTrue(transcript.frames.isEmpty)
    XCTAssertTrue(transcript.declarations.isEmpty)
    XCTAssertTrue(transcript.deliveries.contains { delivery in
      guard case .event(.unsupportedInput(let message)) = delivery.payload else { return false }
      return message.contains("range") && message.contains("420v")
    })
  }

  func testFieldMetadataCannotPassAsProgressiveVideo() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }))
    session.deliverFixtureFrame(try Self.sample(at: .zero, duration: Self.duration30))
    let tags: [(CFString, CFTypeRef)] = [
      (kCVImageBufferFieldDetailKey, kCVImageBufferFieldDetailTemporalTopFirst),
      (kCVImageBufferFieldCountKey, NSNumber(value: 1.5)),
      (kCVImageBufferFieldCountKey, NSNumber(value: 2))
    ]
    for (index, tag) in tags.enumerated() {
      let pts = CMTime(value: Int64(index + 1), timescale: 30)
      let sample = try Self.sample(at: pts, duration: Self.duration30)
      // A driver can attach metadata to the buffer that its format description omits.
      CVBufferSetAttachment(try XCTUnwrap(sample.imageBuffer), tag.0, tag.1, .shouldNotPropagate)
      session.deliverFixtureFrame(sample)
    }
    XCTAssertEqual(transcript.frames.map(\.info.presentationTime), [.zero])
    XCTAssertEqual(transcript.declarations.count, 1)
    XCTAssertEqual(session.counters.conversionFailures, 3)
  }

  func testVariableVideoDeliversValidTimingImmediatelyAndInfersMissingDuration() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    let rate = FrameRate.variable(nominal: Self.duration30, shortest: Self.duration30, longest: Self.duration15)
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }), rate: rate)
    let times = [0, 1, 3, 5].map { CMTime(value: $0, timescale: 30) }
    session.deliverFixtureFrame(try Self.sample(at: times[0], duration: Self.duration30))
    XCTAssertEqual(transcript.frames.map(\.info.duration), [Self.duration30])
    session.deliverFixtureFrame(try Self.sample(at: times[1], duration: Self.duration15))
    XCTAssertEqual(transcript.frames.map(\.info.duration), [Self.duration30, Self.duration15])
    session.deliverFixtureFrame(try Self.sample(at: times[2], duration: .invalid))
    XCTAssertEqual(transcript.frames.count, 2)
    session.deliverFixtureFrame(try Self.sample(at: times[3], duration: Self.duration30))
    XCTAssertEqual(transcript.frames.map(\.info.presentationTime), times)
    XCTAssertEqual(transcript.frames.map(\.info.duration),
      [Self.duration30, Self.duration15, Self.duration15, Self.duration30])
    XCTAssertEqual(transcript.declarations.map { $0.1.rate }, [rate])
    XCTAssertEqual(session.fixtureTiming.unresolvedDurations, 0)
  }

  func testDriverDropsAndMissingDurationsStayDistinctFromMeasuredCadence() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    let rate = FrameRate.variable(nominal: Self.duration30, shortest: Self.duration30, longest: Self.duration15)
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }), rate: rate)
    func deliver(_ pts: Int64, duration: CMTime) throws {
      session.deliverFixtureFrame(try Self.sample(at: CMTime(value: pts, timescale: 30), duration: duration))
    }
    try deliver(0, duration: Self.duration30)
    try deliver(1, duration: Self.duration15)
    XCTAssertEqual(try XCTUnwrap(session.fixtureTiming.measuredFPS), 30, accuracy: 0.01)
    try deliver(3, duration: Self.duration15)
    XCTAssertLessThan(try XCTUnwrap(session.fixtureTiming.measuredFPS), 30)
    XCTAssertEqual(session.fixtureTiming.inferredGaps, 0)
    XCTAssertEqual(session.counters.deviceDroppedFrames, 0)

    try deliver(5, duration: .invalid)
    let cadenceBeforeDrop = try XCTUnwrap(session.fixtureTiming.measuredFPS)
    session.reportFixtureDrop(kCMSampleBufferDroppedFrameReason_FrameWasLate as String)
    XCTAssertEqual(session.counters.deviceDroppedFrames, 1)
    XCTAssertEqual(session.fixtureTiming.unresolvedDurations, 1)
    try deliver(10, duration: Self.duration15)
    XCTAssertEqual(try XCTUnwrap(session.fixtureTiming.measuredFPS), cadenceBeforeDrop, accuracy: 0.01)
    XCTAssertEqual(session.fixtureTiming.inferredGaps, 1)

    try deliver(12, duration: .invalid)
    session.stop()
    XCTAssertEqual(session.fixtureTiming.unresolvedDurations, 2)
    XCTAssertEqual(transcript.frames.map(\.info.presentationTime),
      [0, 1, 3, 10].map { CMTime(value: $0, timescale: 30) })
  }

  func testValidOutOfBoundsVariableDurationIsDiscardedInsteadOfInferred() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    let rate = FrameRate.variable(nominal: Self.duration30, shortest: Self.duration30, longest: Self.duration15)
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }), rate: rate)
    let invalidDuration = CMTime(value: 1, timescale: 60)
    session.deliverFixtureFrame(try Self.sample(at: .zero, duration: Self.duration30))
    session.deliverFixtureFrame(try Self.sample(at: Self.duration30, duration: invalidDuration))
    XCTAssertEqual(session.fixtureTiming.unresolvedDurations, 1)
    session.deliverFixtureFrame(try Self.sample(at: Self.duration15, duration: Self.duration30))
    XCTAssertEqual(transcript.frames.map(\.info.presentationTime), [.zero, Self.duration15])
    XCTAssertEqual(transcript.declarations.map { $0.1.rate }, [rate])
    XCTAssertEqual(session.fixtureTiming.unresolvedDurations, 1)
  }

  func testFixedVideoNormalizesMissingAndRoundedDurations() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    let exact = CMTime(value: 1001, timescale: 30_000)
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }), rate: .constant(exact))
    session.deliverFixtureFrame(try Self.sample(at: .zero, duration: .invalid))
    session.deliverFixtureFrame(try Self.sample(at: exact, duration: CMTime(value: 33_367, timescale: 1_000_000)))
    XCTAssertEqual(transcript.declarations.map { $0.1.rate }, [.constant(exact)])
    XCTAssertEqual(transcript.frames.map(\.info.duration), [exact, exact])
  }

  func testRejectsUnverifiedStartupPTSBeforeDeclaringOrDelivering() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }))
    let host = CMTime(value: 100, timescale: 1)
    for stale in [CMTime.zero, CMTime(value: 1, timescale: 60)] {
      session.deliverFixtureFrame(try Self.sample(at: stale, duration: Self.duration30), verifyHostAt: host)
    }
    XCTAssertTrue(transcript.deliveries.isEmpty)
    let fresh = host - Self.duration30
    let sample = try Self.sample(at: fresh, duration: Self.duration30)
    session.deliverFixtureFrame(sample, verifyHostAt: host)
    session.deliverFixtureFrame(try Self.sample(at: host, duration: Self.duration30),
      verifyHostAt: host + Self.duration30)
    XCTAssertEqual(transcript.declarations.count, 1)
    XCTAssertEqual(transcript.frames.map(\.info.presentationTime), [fresh, host])
    XCTAssertEqual(transcript.frames.map(\.info.duration), [Self.duration30, Self.duration30])
  }

  func testFixedRateStaysStableThroughTimestampJitterAndShortBurst() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    let fixed = CMTime(value: 1, timescale: 60)
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }), rate: .constant(fixed))
    var time = CMTime.zero
    // A short catch-up burst and gradual 5–11% jitter must stay in the fixed epoch.
    for microseconds in [0, 8_300, 8_400, 8_350, 8_350, 17_500, 17_600, 17_450,
                         18_450, 18_550, 18_500, 15_000, 15_090, 15_110, 16_420, 16_700, 16_300] {
      transcript.releaseFrames()
      time = time + CMTime(value: Int64(microseconds), timescale: 1_000_000)
      session.deliverFixtureFrame(try Self.sample(at: time, duration: fixed))
      XCTAssertEqual(transcript.frames.map(\.info.presentationTime), [time])
    }
    XCTAssertEqual(transcript.declarations.map { $0.1.rate }, [.constant(fixed)])
    XCTAssertEqual(session.counters.deviceDroppedFrames, 0)
  }

  func testSustainedUndroppedCadenceChangeRedeclaresOnce() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }), rate: .constant(Self.duration30))
    session.deliverFixtureFrame(try Self.sample(at: .zero, duration: Self.duration30))
    session.deliverFixtureFrame(try Self.sample(at: Self.duration30, duration: Self.duration30))
    for index in 1...12 {
      transcript.releaseFrames()
      let time = CMTime(value: 1 + 2 * Int64(index), timescale: 30)
      session.deliverFixtureFrame(try Self.sample(at: time, duration: Self.duration15))
      XCTAssertEqual(transcript.frames.map(\.info.presentationTime), [time])
    }
    XCTAssertEqual(transcript.declarations.map { $0.1.rate }, [.constant(Self.duration30),
      .variable(nominal: Self.duration15, shortest: Self.duration30, longest: Self.duration15)])
    XCTAssertEqual(transcript.declarations.map { $0.0.epochID.epoch }, [0, 1])
    XCTAssertLessThan(try XCTUnwrap(session.fixtureTiming.measuredFPS), 17)
    XCTAssertEqual(session.counters.deviceDroppedFrames, 0)
  }

  func testPeriodicTimestampGapsWithNominalDurationsKeepFixedDeclaration() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let transcript = MacCameraVideoTranscript()
    defer { session.stop() }
    session.startFixture(handlers: CaptureHandlers(deliver: { transcript.append($0) }), rate: .constant(Self.duration30))
    for index in 0...12 {
      transcript.releaseFrames()
      let time = CMTime(value: Int64(index), timescale: 15)
      session.deliverFixtureFrame(try Self.sample(at: time, duration: Self.duration30))
      XCTAssertEqual(transcript.frames.map(\.info.duration), [Self.duration30])
    }
    XCTAssertEqual(transcript.declarations.map { $0.1.rate }, [.constant(Self.duration30)])
    XCTAssertEqual(session.fixtureTiming.inferredGaps, 12)
    XCTAssertEqual(session.counters.deviceDroppedFrames, 0)
  }

  // Automatic capture consents to a conversion for "format@automatic": the
  // hardware cadence may drift (auto frame rate, low light) without leaving
  // that scope. Dropping the conversion on a rate-only change refused every
  // later frame. A real AVCaptureDevice is needed to drive refreshMode itself.
  func testAutomaticRateDriftKeepsConsentedInputConversion() {
    XCTAssertTrue(MacCameraCaptureSession.keepsInputConversion(formatChanged: false, requestedDuration: nil))
    XCTAssertFalse(MacCameraCaptureSession.keepsInputConversion(formatChanged: true, requestedDuration: nil))
    XCTAssertFalse(MacCameraCaptureSession.keepsInputConversion(formatChanged: false, requestedDuration: Self.duration30))
    XCTAssertFalse(MacCameraCaptureSession.keepsInputConversion(formatChanged: true, requestedDuration: Self.duration30))
  }

  func testModeCapabilitiesKeepExactRatesAndRejectDisjointGaps() throws {
    let exact = CMTime(value: 1001, timescale: 30_000)
    let fast = VendorCaptureRateRange(shortest: CMTime(value: 1, timescale: 60),
      longest: CMTime(value: 1, timescale: 50))
    let slow = VendorCaptureRateRange(shortest: exact, longest: CMTime(value: 1, timescale: 24))
    let sample = try Self.sample(at: .zero, duration: exact)
    let description = try XCTUnwrap(sample.formatDescription)
    let mode = MacCameraMode.Capabilities(description: description, ranges: [fast, slow], colorSpaces: [0, 1]).settingFormat
    XCTAssertTrue(mode.rates.contains { $0.duration.value == 1001 && $0.duration.timescale == 30_000 })
    XCTAssertEqual(mode.rates.first?.duration, exact)
    XCTAssertTrue(mode.label.contains("Display P3"))
    XCTAssertTrue(mode.supports(try XCTUnwrap(VendorCaptureMode.customDuration("27.5"))))
    XCTAssertFalse(mode.supports(try XCTUnwrap(VendorCaptureMode.customDuration("40"))))
    XCTAssertFalse(mode.supports(Self.duration30))
    XCTAssertFalse(mode.supports(.invalid))
    XCTAssertFalse(mode.supports(.zero))
    let saved = VendorCaptureMode.value(formatID: mode.id, duration: exact)
    let restored = try XCTUnwrap(VendorCaptureMode(selection: saved))
    XCTAssertEqual(restored.formatID, mode.id)
    XCTAssertEqual(restored.duration, exact)
    XCTAssertEqual(VendorCaptureMode.customDuration("30000/1001"), exact)

    let reordered = MacCameraMode.Capabilities(description: description, ranges: [slow, fast], colorSpaces: [1, 0])
    XCTAssertEqual(reordered.settingFormat.id, mode.id)
    let differentColor = MacCameraMode.Capabilities(description: description, ranges: [fast, slow], colorSpaces: [0])
    XCTAssertNotEqual(differentColor.settingFormat.id, mode.id)
    XCTAssertNotEqual(differentColor.settingFormat.label, mode.label)
    let fullRangeSample = try Self.sample(at: .zero, duration: exact, pixel: .full420)
    let differentSubtype = MacCameraMode.Capabilities(description: try XCTUnwrap(fullRangeSample.formatDescription),
      ranges: [fast, slow], colorSpaces: [0, 1])
    XCTAssertNotEqual(differentSubtype.settingFormat.id, mode.id)
  }

  private static func sample(at timestamp: CMTime, duration: CMTime, width: Int = 640, height: Int = 480,
    pixel: PixelFormatID = .video420, surfaceBacked: Bool = false, tags: [(CFString, CFTypeRef)] = []) throws -> CMSampleBuffer {
    var image: CVPixelBuffer?
    let attributes = surfaceBacked ? [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary : nil
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, pixel.rawValue, attributes, &image), kCVReturnSuccess)
    let buffer = try XCTUnwrap(image)
    for (key, value) in tags { CVBufferSetAttachment(buffer, key, value, .shouldPropagate) }
    var description: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
      formatDescriptionOut: &description), noErr)
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
      formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }
}

private final class MacCameraVideoTranscript: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CaptureDelivery] = []

  var deliveries: [CaptureDelivery] { lock.withLock { storage } }
  func append(_ delivery: CaptureDelivery) { lock.withLock { storage.append(delivery) } }
  func releaseFrames() {
    lock.withLock {
      storage.removeAll {
        if case .frame = $0.payload { return true }
        return false
      }
    }
  }

  var declarations: [(CaptureDelivery, SourceFormat)] {
    deliveries.compactMap { delivery in
      guard case .event(.formatChanged(let format)) = delivery.payload else { return nil }
      return (delivery, format)
    }
  }

  var frames: [(delivery: CaptureDelivery, buffer: CVPixelBuffer, info: CaptureFrameInfo)] {
    deliveries.compactMap { delivery in
      guard case .frame(let buffer, let info) = delivery.payload else { return nil }
      return (delivery, buffer.value, info)
    }
  }
}
#endif
