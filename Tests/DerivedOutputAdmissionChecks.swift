import CoreMedia
import CoreVideo
import Metal
import Synchronization
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
  /// The live feed route: physical 2160p59.94 v210, Sony interpretation,
  /// LUT to Rec.709, 1080 Fit, 420v and a 29.97 output cadence.
  func testSonyLUTResizedOutputMatchesNegotiatedCameraWithSourceGeometryTags() throws {
    guard let device = LUTProcessor.sharedDevice, device.supportsFamily(.metal4) else {
      throw XCTSkip("Metal 4 required")
    }
    let processor = try LUTProcessor()
    defer { processor.releaseIdleResources() }
    let sony = Colorimetry(primaries: .sGamut3Cine, transfer: .sLog3, matrix: .rec709,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
    var cube = "TITLE \"Identity transport probe\"\nLUT_3D_SIZE 2\n"
    for blue in 0...1 { for green in 0...1 { for red in 0...1 {
      cube += "\(red) \(green) \(blue)\n"
    } } }
    try processor.load(LUTProcessor.makeLUT(CubeLUT(text: cube)),
      colorSpace: LUTColorSpaceContract(input: sony, output: .rec709Video))
    let source = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      colour: .rec709Video, rate: .constant(VideoContract.fastDuration))
    var configuration = PipelineConfiguration(applyLUT: true, downscale: true,
      convertTo420: true, reduceFrameRate: true)
    configuration.resizeTarget = .hd1080
    configuration.colorTarget = .yuv4208
    configuration.frameRateTarget = .fps2997
    configuration.sourceWidth = 3840
    configuration.sourceHeight = 2160
    configuration.sourceDuration = VideoContract.fastDuration
    configuration.sourceColorimetryOverride = sony
    configuration.lutOutputColorimetry = .rec709Video
    configuration.scalingMode = .fit
    let negotiated = try CameraSink.requestedFormat(configuration: configuration,
      passthroughFormat: source.pixel.rawValue, sourceFormat: source)
    let factory = VideoSampleFactory()
    for (squareAspect, fieldCount, fieldDetail) in [
      (false, 0, false), (true, 0, false), (false, 1, false), (true, 1, false),
      (false, 2, false), (false, 1, true)
    ] {
      let input = try image(width: 3840, height: 2160, pixel: kCVPixelFormatType_422YpCbCr10)
      CVPixelBufferLockBaseAddress(input, [])
      memset(CVPixelBufferGetBaseAddress(input)!, 0, CVPixelBufferGetBytesPerRow(input) * 2160)
      CVPixelBufferUnlockBaseAddress(input, [])
      if squareAspect {
        CVBufferSetAttachment(input, kCVImageBufferPixelAspectRatioKey,
          [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 1,
           kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1] as CFDictionary, .shouldPropagate)
      }
      if fieldCount > 0 {
        CVBufferSetAttachment(input, kCVImageBufferFieldCountKey, NSNumber(value: fieldCount), .shouldPropagate)
      }
      if fieldDetail {
        CVBufferSetAttachment(input, kCVImageBufferFieldDetailKey,
          kCVImageBufferFieldDetailTemporalTopFirst, .shouldPropagate)
      }
      let output = try processor.process(input, configuration: configuration,
        declaredSourceColorimetry: source.colour)
      let sample = try factory.sample(output, at: CMTime(value: 1, timescale: 1), duration: VideoContract.slowDuration)
      let actual = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
      let diagnostic = "PAR=\(squareAspect), fields=\(fieldCount), detail=\(fieldDetail); negotiated=\(String(describing: CMFormatDescriptionGetExtensions(negotiated))); actual=\(String(describing: CMFormatDescriptionGetExtensions(actual)))"
      let mismatch = CameraSink.mismatch(sample, format: negotiated, duration: VideoContract.slowDuration)
      if fieldCount == 2 || fieldDetail {
        XCTAssertNotNil(mismatch, diagnostic)
      } else {
        XCTAssertNil(mismatch, diagnostic)
      }
      if fieldCount > 0 {
        XCTAssertEqual(CVBufferCopyAttachment(input, kCVImageBufferFieldCountKey, nil) as? NSNumber,
          NSNumber(value: fieldCount), "Processing must not modify the capture frame")
      }
    }
  }

  func testOriginalFlatAndLUTCameraRoutesAcrossRepresentativeEffects() throws {
    guard let device = LUTProcessor.sharedDevice, device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 required") }
    let processor = try LUTProcessor()
    defer { processor.releaseIdleResources() }
    let sony = Colorimetry(primaries: .sGamut3Cine, transfer: .sLog3, matrix: .rec709,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
    let cube = try CubeLUT(text: "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
    try processor.load(cube, colorSpace: LUTColorSpaceContract(input: sony, output: .rec709Video))
    let source = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      colour: .rec709Video, rate: .constant(VideoContract.fastDuration))
    // Effects off ignores the saved LUT switch. Effects on retains each
    // geometry/cadence/layout choice independently of the main LUT switch.
    let cases = [(false, false, false, false, false), (false, true, true, true, true),
      (true, false, false, false, false), (true, false, true, true, true),
      (true, false, false, true, false), (true, false, true, false, false),
      (true, true, true, true, true), (true, true, false, false, false)]
    for (effects, savedLUT, resize, color, cap) in cases {
      var configuration = PipelineConfiguration(applyLUT: effects && savedLUT,
        downscale: effects && resize, convertTo420: effects && color, reduceFrameRate: effects && cap)
      configuration.resizeTarget = .hd1080
      configuration.colorTarget = .yuv4208
      configuration.frameRateTarget = .fps2997
      configuration.sourceWidth = 3840; configuration.sourceHeight = 2160
      configuration.sourceDuration = VideoContract.fastDuration
      // Mirrors the controller's effective policy; the saved Sony profile is
      // retained separately and applies when the burn-in LUT is enabled.
      configuration.sourceColorimetryOverride = configuration.applyLUT ? sony : nil
      configuration.lutOutputColorimetry = configuration.applyLUT ? .rec709Video : nil
      let input = try image(width: 3840, height: 2160, pixel: kCVPixelFormatType_422YpCbCr10)
      CVBufferSetAttachment(input, kCVImageBufferPixelAspectRatioKey,
        [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 1,
         kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1] as CFDictionary, .shouldPropagate)
      CVBufferSetAttachment(input, kCVImageBufferFieldCountKey, NSNumber(value: 1), .shouldPropagate)
      CVPixelBufferLockBaseAddress(input, [])
      let stride = CVPixelBufferGetBytesPerRow(input)
      let words: [UInt32] = [512 | (400 << 10) | (512 << 20), 400 | (512 << 10) | (400 << 20),
        512 | (400 << 10) | (512 << 20), 400 | (512 << 10) | (400 << 20)]
      for y in 0..<2160 {
        let row = CVPixelBufferGetBaseAddress(input)!.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
        for x in 0..<(3840 / 6) { for word in 0..<4 { row[x * 4 + word] = words[word] } }
      }
      CVPixelBufferUnlockBaseAddress(input, [])
      let output: CVPixelBuffer
      if configuration.untouched {
        let admission = try SourceAdmissionSnapshot(format: source,
          epochID: CaptureEpochID(sessionID: UUID(), epoch: 0),
          clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .lut)
        let metadata = SourceAdmissionMetadata(width: 3840, height: 2160, pixel: .v210,
          isPlanar: false, planeCount: 0, rowBytes: CVPixelBufferGetBytesPerRow(input),
          dataSize: CVPixelBufferGetDataSize(input), presentationTime: CMTime(value: 1, timescale: 1),
          duration: VideoContract.fastDuration, epochID: admission.epochID, formatSignature: admission.formatSignature)
        let done = expectation(description: "typed native camera output")
        let result = Mutex<LUTProcessor.Completed?>(nil)
        try processor.submitPassthrough(input, source: admission, metadata: metadata) { completed in
          result.withLock { $0 = completed }
          done.fulfill()
        }
        wait(for: [done], timeout: 5)
        output = try XCTUnwrap(result.withLock { $0 }).result.get()
      } else {
        output = try processor.process(input, configuration: configuration, declaredSourceColorimetry: source.colour)
      }
      let expected = try CameraSink.requestedFormat(configuration: configuration,
        passthroughFormat: source.pixel.rawValue, sourceFormat: source)
      let sample = try VideoContract.sample(output, at: CMTime(value: 1, timescale: 1), duration: configuration.duration)
      let actual = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
      let diagnostic = "effects=\(effects) LUT=\(savedLUT) resize=\(resize) color=\(color) cap=\(cap); actual=\(String(describing: CMFormatDescriptionGetExtensions(actual))); expected=\(String(describing: CMFormatDescriptionGetExtensions(expected)))"
      XCTAssertNil(CameraSink.mismatch(sample, format: expected, duration: configuration.duration), diagnostic)
      XCTAssertEqual(source.colour, .rec709Video)
      if !configuration.applyLUT {
        XCTAssertEqual(CMFormatDescriptionGetExtension(actual, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
          kCVImageBufferColorPrimaries_ITU_R_709_2 as String, diagnostic)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        if configuration.untouched {
          let row = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt32.self)
          for i in 0..<4 { XCTAssertEqual(row[i], words[i], diagnostic) }
        } else if CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
          let y = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)
          let uv = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt8.self)
          XCTAssertEqual(Double(y[0]), 100, accuracy: 1, diagnostic)
          XCTAssertEqual(Double(uv[0]), 128, accuracy: 1, diagnostic)
          XCTAssertEqual(Double(uv[1]), 128, accuracy: 1, diagnostic)
        } else {
          let y = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt16.self)
          XCTAssertEqual(Double(y[0] >> 6), 400, accuracy: 1, diagnostic)
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
      }
    }
  }

  func testFeedCameraExplicitlyRefusesVFRBeforeDeviceDiscovery() throws {
    let source = try SourceFormat(width: 1920, height: 1080,
      pixel: PixelFormatID(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      rate: .variable(nominal: FrameRateTarget.fps30.duration,
        shortest: FrameRateTarget.fps60.duration, longest: FrameRateTarget.fps24.duration))
    XCTAssertThrowsError(try CameraSink.validateCameraSource(source)) { error in
      XCTAssertTrue(error.localizedDescription.contains("Preview and recording remain available"))
    }
    let program = CameraSink(route: CameraSinkRoute(descriptor: .program()))
    var fixedOutput = PipelineConfiguration()
    fixedOutput.sourceDuration = source.rate.nominal
    let contract = try program.outputContract(configuration: fixedOutput,
      passthroughFormat: source.pixel.rawValue, sourceFormat: source)
    XCTAssertEqual(contract.duration, FrameRateTarget.fps30.duration,
      "Program fixes cadence at the output boundary independently of source timing")
  }

  func testNativeCameraMismatchIsLocalAndNamesTheResolvingEffect() throws {
    let source = try SourceFormat(width: 1920, height: 1080, pixel: .full420,
      colour: Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709, range: .full,
        horizontalChromaSiting: .center, verticalChromaSiting: .center),
      rate: .constant(FrameRateTarget.fps30.duration))
    var configuration = PipelineConfiguration(applyLUT: false, downscale: false,
      convertTo420: false, reduceFrameRate: false)
    configuration.sourceWidth = source.width
    configuration.sourceHeight = source.height
    configuration.sourceDuration = source.rate.nominal
    XCTAssertThrowsError(try CameraSink.requestedFormat(configuration: configuration,
      passthroughFormat: source.pixel.rawValue, sourceFormat: source)) { error in
      XCTAssertTrue(error.localizedDescription.contains("420f"))
      XCTAssertTrue(error.localizedDescription.contains("Effects"))
      XCTAssertTrue(error.localizedDescription.contains("Color format"))
    }
    configuration.convertTo420 = true
    let processed = try CameraSink.requestedFormat(configuration: configuration,
      passthroughFormat: source.pixel.rawValue, sourceFormat: source)
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(processed), PixelFormatID.video420.rawValue)
    XCTAssertEqual(CMFormatDescriptionGetExtension(processed,
      extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool, false)
    XCTAssertNotNil(DerivedOutputContract(format: processed, duration: source.rate.nominal)
      .matchingPublishedIndex(in: try OutputFormatCatalog.descriptions()))
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

  func testProgramBridgeUsesOnePublishedContractForPreflightConnectAndSend() throws {
    struct Output: @unchecked Sendable {
      let result: Result<CVPixelBuffer, Error>
    }
    let sink = CameraSink(route: CameraSinkRoute(descriptor: .program()))
    let installed = try OutputFormatCatalog.descriptions()
    let normalizer = try ProgramNormalizer()
    for pixel in [PixelFormatID.video420, .full420, .twoVuy, .bgra8] {
      let native420 = pixel == .video420
      let input = try SourceRouteFixture(pixel: pixel,
        width: native420 ? 1280 : 640, height: native420 ? 720 : 480)
      LUTProcessor.stampDeclaredColorimetry(input.format.colour, on: input.image)
      var configuration = PipelineConfiguration(downscale: false, convertTo420: false,
        reduceFrameRate: !native420, frameRateTarget: .fps30, sourcePauseAllowanceSeconds: 0.5)
      let source = try SourceFormat(width: input.format.width, height: input.format.height,
        pixel: pixel, colour: input.format.colour,
        rate: .constant(native420 ? FrameRateTarget.fps30.duration : FrameRateTarget.fps24.duration))
      configuration = FeedLifecycleDemandPolicy.programContract(configuration: configuration, pipelineEnabled: true,
        detectedSourceDuration: nil, source: source)

      let fanout = FrameFanOut<CVPixelBuffer>()
      let consumer = try fanout.addRoute(id: "camera", capacity: 4, policy: .reject)
      var preflight: DerivedOutputContract?
      var connected: DerivedOutputContract?
      var sent = 0
      let bridge = ProgramOutputBridge(route: consumer, connect: { format, pauseAllowance in
        XCTAssertEqual(pauseAllowance, 0.5)
        connected = try sink.outputContract(program: format)
      }, disconnect: {}, send: { sample in
        let contract = try XCTUnwrap(connected)
        XCTAssertNil(CameraSink.mismatch(sample, format: contract.format, duration: contract.duration))
        sent += 1
        return true
      }, preNegotiate: { format, _ in
        preflight = try sink.outputContract(program: format)
      })
      defer { bridge.disconnect() }
      bridge.enforceContract = true
      bridge.requestPreNegotiation(configuration: configuration, passthroughFormat: pixel.rawValue)
      try bridge.setDemand(true, configuration: configuration, passthroughFormat: pixel.rawValue)
      let prepared = try XCTUnwrap(preflight)
      let negotiated = try XCTUnwrap(connected)
      let target = try XCTUnwrap(bridge.contract)
      XCTAssertEqual(prepared.matchingPublishedIndex(in: installed), try XCTUnwrap(negotiated.matchingPublishedIndex(in: installed)))
      XCTAssertEqual(prepared.duration, FrameRateTarget.fps30.duration)
      XCTAssertEqual(negotiated.duration, FrameRateTarget.fps30.duration)
      XCTAssertEqual(target.width, 1280)
      XCTAssertEqual(target.height, 720)
      XCTAssertEqual(target.pixelFormat, native420 ? pixel.rawValue : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
      XCTAssertEqual(target.colour.horizontalChromaSiting, .center)

      let output = Mutex<Output?>(nil)
      let completed = DispatchSemaphore(value: 0)
      try normalizer.normalize(input.image, to: target) { result in
        output.withLock { $0 = Output(result: result) }
        completed.signal()
      }
      XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
      let buffer = try XCTUnwrap(output.withLock { $0 }).result.get()
      _ = fanout.publish(ProcessedFrame(payload: buffer, metadata: ProcessedFrameMetadata(
        presentationTime: CMTime(value: 1, timescale: 1), duration: target.duration,
        width: target.width, height: target.height, pixelFormat: target.pixelFormat)))
      bridge.pump()
      bridge.waitUntilIdle()
      XCTAssertEqual(sent, 1, VideoContract.fourCC(pixel.rawValue))
      XCTAssertEqual(bridge.currentStatistics.invalid, 0)
    }
  }
}
