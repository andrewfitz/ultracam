import CoreMedia
import CoreVideo
import XCTest

@objcMembers final class DerivedOutputAdmissionChecks: XCTestCase {
  private func image(width: Int = 1920, height: Int = 1080, pixel: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                     pq: Bool = false) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, pixel,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
    let image = try XCTUnwrap(result)
    if !pq {
      CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
    if pq {
      CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
      CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
      CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    }
    return image
  }
  func testFeedCameraExplicitlyRefusesVFRBeforeDeviceDiscovery() throws {
    let source = try SourceFormat(width: 1920, height: 1080,
      pixel: PixelFormatID(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      rate: .variable(nominal: FrameRateTarget.fps30.duration,
        shortest: FrameRateTarget.fps60.duration, longest: FrameRateTarget.fps24.duration))
    XCTAssertThrowsError(try CameraSink.validateCameraSource(source)) { error in
      XCTAssertTrue(error.localizedDescription.contains("Preview and recording remain available"))
    }
  }

  func testSinkBuildsDeclaredHDRAndRetainsExplicitLegacy709Compatibility() throws {
    let source = try SourceFormat(width: 1920, height: 1080,
      pixel: PixelFormatID(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      colour: Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020, range: .video,
        horizontalChromaSiting: .unspecified, verticalChromaSiting: .unspecified),
      rate: .constant(FrameRateTarget.fps30.duration))
    let configuration = PipelineConfiguration()
    let declared = try CameraSink.requestedFormat(configuration: configuration,
      passthroughFormat: source.pixel.rawValue, sourceFormat: source)
    let compatibility = try CameraSink.requestedFormat(configuration: configuration,
      passthroughFormat: source.pixel.rawValue, sourceFormat: nil)
    let formats = try OutputFormatCatalog.descriptions()
    XCTAssertEqual(DerivedOutputContract(format: declared, duration: configuration.duration).matchingPublishedIndex(in: formats), 96)
    XCTAssertEqual(DerivedOutputContract(format: compatibility, duration: configuration.duration).matchingPublishedIndex(in: formats), 72)
    XCTAssertFalse(DerivedOutputContract.matchesFormat(declared, compatibility))
  }

  func testSinkNegotiatesResolvedLUTOutputAndManualInterpretation() throws {
    func source(_ colour: Colorimetry) throws -> SourceFormat {
      try SourceFormat(width: 1920, height: 1080,
        pixel: PixelFormatID(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        colour: colour, rate: .constant(FrameRateTarget.fps30.duration))
    }
    let log = Colorimetry(primaries: .rec2020, transfer: .sLog3, matrix: .rec2020, range: .video,
      horizontalChromaSiting: .left, verticalChromaSiting: .center)
    let pq = Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020, range: .video,
      horizontalChromaSiting: .center, verticalChromaSiting: .center)
    let descriptions = try OutputFormatCatalog.descriptions()
    var config = PipelineConfiguration()
    config.applyLUT = true
    config.lutOutputColorimetry = .rec709Video
    let logTo709 = try CameraSink.requestedFormat(configuration: config,
      passthroughFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, sourceFormat: source(log))
    XCTAssertTrue(DerivedOutputContract.matchesFormat(logTo709, descriptions[72]))
    config.lutOutputColorimetry = pq
    let sdrToPQ = try CameraSink.requestedFormat(configuration: config,
      passthroughFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, sourceFormat: source(.rec709Video))
    XCTAssertTrue(DerivedOutputContract.matchesFormat(sdrToPQ, descriptions[96]))
    config.applyLUT = false
    config.lutOutputColorimetry = nil
    config.sourceColorimetryOverride = pq
    let interpreted = try CameraSink.requestedFormat(configuration: config,
      passthroughFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, sourceFormat: source(.rec709Video))
    // A source profile changes RGB encoding only. The no-LUT GPU path keeps
    // the declared source matrix, so this mixed contract cannot select the
    // published PQ entry whose physical output matrix is Rec.2020.
    let resolved = try CameraSink.resolvedOutputColour(configuration: config, sourceFormat: source(.rec709Video))
    XCTAssertEqual(resolved.primaries, .rec2020)
    XCTAssertEqual(resolved.transfer, .pq)
    XCTAssertEqual(resolved.matrix, .rec709)
    XCTAssertEqual(resolved.range, .video)
    XCTAssertEqual(resolved.horizontalChromaSiting, .center)
    XCTAssertEqual(resolved.verticalChromaSiting, .center)
    XCTAssertEqual(CMFormatDescriptionGetExtension(interpreted,
      extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    XCTAssertNil(DerivedOutputContract(format: interpreted, duration: config.duration)
      .matchingPublishedIndex(in: descriptions))
    // The same RGB override on a physically Rec.2020-matrix source exactly
    // matches the published PQ contract, including centered encoded chroma.
    let interpreted2020 = try CameraSink.requestedFormat(configuration: config,
      passthroughFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, sourceFormat: source(log))
    XCTAssertTrue(DerivedOutputContract.matchesFormat(interpreted2020, descriptions[96]))
    XCTAssertEqual(DerivedOutputContract(format: interpreted2020, duration: config.duration)
      .matchingPublishedIndex(in: descriptions), 96)
    config.applyLUT = true
    XCTAssertThrowsError(try CameraSink.requestedFormat(configuration: config,
      passthroughFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, sourceFormat: source(.rec709Video)))
  }

  func testOldAppLegacySelectionCanNegotiateItsTruthfulCentered709Output() throws {
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false)
    let buffer = try image()
    // The shipped app's GPU processor advertises a legacy unsited stream
    // description but encodes centered chroma and labels the image accordingly.
    CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
      kCVImageBufferChromaLocation_Center, .shouldPropagate)
    let sample = try VideoContract.sample(buffer, at: CMTime(value: 1, timescale: 1), duration: VideoContract.fastDuration)
    try camera.queue.sync {
      try camera.setProperties(index: 0, frameDuration: VideoContract.fastDuration)
      XCTAssertFalse(camera.receive(sample, discontinuity: []), "An unprivileged producer cannot rewrite the active contract")
      XCTAssertTrue(camera.receive(sample, discontinuity: [], producerCanNegotiate: true))
      XCTAssertEqual(camera.activeIndex, 72)
      XCTAssertTrue(camera.latest === buffer, "Compatibility preserves the actual image and tags")
      XCTAssertTrue(camera.receive(sample, discontinuity: []))
    }
  }

  func testLegacySelectionDoesNotInventColourForUntaggedProducer() throws {
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false)
    var raw: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &raw), kCVReturnSuccess)
    let sample = try VideoContract.sample(try XCTUnwrap(raw), at: CMTime(value: 1, timescale: 1), duration: VideoContract.fastDuration)
    camera.queue.sync {
      XCTAssertFalse(camera.receive(sample, discontinuity: [], producerCanNegotiate: true))
      XCTAssertEqual(camera.activeIndex, 0)
      XCTAssertNil(camera.latest)
    }
  }

  func testExtensionRejectsNearbyProducerCadenceWithoutMutatingContract() throws {
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false)
    try camera.queue.sync {
      let near = CMTime(value: 1_001_001, timescale: 60_000_000)
      let sample = try VideoContract.sample(image(), at: CMTime(value: 1, timescale: 1), duration: near)
      XCTAssertFalse(camera.receive(sample, discontinuity: []))
      XCTAssertFalse(camera.receive(sample, discontinuity: [], producerCanNegotiate: true))
      XCTAssertEqual(CMTimeCompare(camera.duration, VideoContract.fastDuration), 0)
      XCTAssertEqual(camera.activeIndex, 0)
    }
  }
  func testSinkRefusesHDRThrough709AndExtensionNegotiatesExactHDR() throws {
    let sample = try VideoContract.sample(image(pq: true), at: CMTime(value: 1, timescale: 1), duration: VideoContract.fastDuration)
    let expected = try VideoContract.formatDescription(width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    XCTAssertNotNil(CameraSink.mismatch(sample, format: expected, duration: VideoContract.fastDuration))
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false)
    camera.queue.sync {
      XCTAssertTrue(camera.receive(sample, discontinuity: [], producerCanNegotiate: true))
      XCTAssertEqual(camera.activeIndex, 24)
    }
  }
  func testAllEighteenLegacyOutputsRemainValid() throws {
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false)
    try camera.queue.sync {
      XCTAssertEqual(camera.formats.count, OutputFormatCatalog.published.count)
      for (index, entry) in camera.formats.prefix(18).enumerated() {
        let description = entry.formatDescription
        let size = CMVideoFormatDescriptionGetDimensions(description)
        let buffer = try image(width: Int(size.width), height: Int(size.height), pixel: CMFormatDescriptionGetMediaSubType(description))
        let equivalent = CMTime(value: 2_002, timescale: 120_000)
        let sample = try VideoContract.sample(buffer, at: CMTime(value: Int64(index + 1), timescale: 1), duration: equivalent)
        XCTAssertNil(CameraSink.mismatch(sample, format: description, duration: VideoContract.fastDuration))
        try camera.setProperties(index: index, frameDuration: VideoContract.fastDuration)
        XCTAssertTrue(camera.receive(sample, discontinuity: []), "Legacy slot \(index)")
        XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === buffer)
      }
    }
  }
  func testClientQuantizationDoesNotBecomeProducerTolerance() throws {
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false)
    try camera.queue.sync {
      try camera.setProperties(index: 0, frameDuration: CMTime(value: 33_366_667, timescale: 1_000_000_000))
      XCTAssertEqual(CMTimeCompare(camera.duration, VideoContract.slowDuration), 0)
      XCTAssertThrowsError(try camera.setProperties(index: 0, frameDuration: CMTime(value: 33_367_000, timescale: 1_000_000_000)))
      XCTAssertThrowsError(try camera.setProperties(index: 0, frameDuration: CMTime(value: 33_366_667, timescale: 1_000_000_000), fromProducer: true))
      XCTAssertEqual(CMTimeCompare(camera.duration, VideoContract.slowDuration), 0)
    }
  }
  func testInstalledOutputLayoutIsRequiredWithoutCaptureTableConflation() throws {
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false)
    let formats = camera.formats.map(\.formatDescription)
    let requested = DerivedOutputContract(format: formats[8], duration: VideoContract.fastDuration)
    XCTAssertNil(requested.matchingPublishedIndex(in: Array(formats.prefix(8))))
    XCTAssertEqual(requested.matchingPublishedIndex(in: formats), 8)
  }
  func testProgramBridgeRefusesUndeclaredHDRThroughLegacy709Contract() throws {
    let fanout = FrameFanOut<CVPixelBuffer>()
    let route = try fanout.addRoute(id: "camera", capacity: 4, policy: .reject)
    var sent = 0
    let bridge = ProgramOutputBridge(route: route, connect: { _, _ in }, disconnect: {}, send: { _ in sent += 1; return true })
    bridge.enforceContract = true
    var configuration = PipelineConfiguration()
    configuration.frameRateTarget = .fps5994
    try bridge.setDemand(true, configuration: configuration, passthroughFormat: kCVPixelFormatType_422YpCbCr10)
    let buffer = try image(pq: true)
    CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<2 {
      memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, plane == 0 ? 100 : 128,
        CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    _ = fanout.publish(ProcessedFrame(payload: buffer, metadata: ProcessedFrameMetadata(
      presentationTime: CMTime(value: 1, timescale: 1), duration: VideoContract.fastDuration,
      width: 1920, height: 1080, pixelFormat: CVPixelBufferGetPixelFormatType(buffer))))
    bridge.pump(); bridge.waitUntilIdle()
    XCTAssertEqual(sent, 0)
    XCTAssertEqual(bridge.currentStatistics.staleFormat, 0, "The frame matches negotiated size, pixels and cadence")
    XCTAssertEqual(bridge.currentStatistics.invalid, 1, "Exact colour admission refuses unconverted HDR")
    XCTAssertNotNil(bridge.currentStatistics.lastRefusal)
    XCTAssertEqual(CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String,
      kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String, "The bridge must not retag refused source pixels")
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    XCTAssertEqual(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)[0], 100,
      "A transport bridge must neither convert nor mutate refused HDR pixels")
    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    bridge.disconnect()
  }
}
