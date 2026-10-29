import XCTest
import CoreVideo
import IOSurface

@objcMembers final class LUTColorSpaceContractChecks: XCTestCase {
  private let sdr = Colorimetry.rec709Video
  private var hdr: Colorimetry {
    Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
  }

  func testMatchingSpacesAreAcceptedWithoutConversion() throws {
    try LUTColorSpaceContract(input: sdr, output: sdr).validate(source: sdr, destination: sdr)
  }

  func testInputMismatchIsRefusedWithoutExplicitConversion() {
    XCTAssertThrowsError(try LUTColorSpaceContract(input: sdr, output: sdr)
      .validate(source: hdr, destination: sdr)) { error in
        XCTAssertEqual(error as? LUTColorSpaceContractError,
          .inputMismatch(expected: sdr, actual: hdr))
      }
  }

  func testExplicitInputConversionAllowsTheMismatchedEdge() throws {
    try LUTColorSpaceContract(input: sdr, output: sdr).validate(source: hdr, destination: sdr,
      conversion: .sourceToLUTInput(from: hdr, to: sdr))
  }

  func testWrongExplicitConversionStillRefuses() {
    XCTAssertThrowsError(try LUTColorSpaceContract(input: sdr, output: sdr)
      .validate(source: hdr, destination: sdr,
        conversion: .sourceToLUTInput(from: sdr, to: hdr)))
  }
}

@objcMembers final class LUTGPUConversionContractChecks: XCTestCase {
  func testWrongEndpointIsRefusedEvenWhenColorsAlreadyMatch() {
    let contract = LUTColorSpaceContract.rec709Video
    let different = ColorimetryContract.identity.colorimetry
    XCTAssertThrowsError(try contract.validate(source: contract.input, destination: contract.output,
      conversion: .sourceToLUTInput(from: different, to: contract.input)))
    XCTAssertThrowsError(try contract.validate(source: contract.input, destination: contract.output,
      conversion: .lutOutputToDestination(from: contract.output, to: different)))
  }

  func testSDRGamutAndHDRConversionSelectGPUTransforms() throws {
    let source = Colorimetry.rec709Video
    let target = Colorimetry(primaries: .rec2020, transfer: .linear, matrix: .rec2020,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
    XCTAssertEqual(try LUTProcessor.conversionParameters(from: source, to: target), SIMD4<UInt32>(2, 1, 1, 0))
    let hdr = Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
    XCTAssertEqual(try LUTProcessor.conversionParameters(from: hdr, to: source), SIMD4<UInt32>(4, 2, 2, 0))
  }
}

@objcMembers final class LUTDynamicSizeChecks: XCTestCase {
  func testNativeNon4KSourceRetainsDimensionsAndOutputMatrix() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 64, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &image), kCVReturnSuccess)
    let source = try XCTUnwrap(image)
    CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    let colour = Colorimetry(primaries: .rec2020, transfer: .rec709, matrix: .rec2020,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()), colorSpace: LUTColorSpaceContract(input: colour, output: colour))
    let output = try processor.process(source, configuration: PipelineConfiguration(applyLUT: true, downscale: false))
    XCTAssertEqual(CVPixelBufferGetWidth(output), 128)
    XCTAssertEqual(CVPixelBufferGetHeight(output), 64)
    XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil) as? String,
      kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
  }

  func testUnknownTagsRefuseRatherThanAuthorizeConversion() throws {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      nil, &image), kCVReturnSuccess)
    let source = try XCTUnwrap(image)
    CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey, "unknown-transfer" as CFString, .shouldPropagate)
    XCTAssertThrowsError(try LUTProcessor.sourceColorimetry(source))
  }
}

extension LUTDynamicSizeChecks {
  private func graySource(transfer: CFString = kCVImageBufferTransferFunction_ITU_R_709_2,
    pixelFormat: OSType = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, lumaCode: UInt16 = 502) throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 64, pixelFormat,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &image), kCVReturnSuccess)
    let source = try XCTUnwrap(image)
    CVPixelBufferLockBaseAddress(source, [])
    defer { CVPixelBufferUnlockBaseAddress(source, []) }
    for plane in 0..<2 {
      let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, plane)).assumingMemoryBound(to: UInt16.self)
      let count = CVPixelBufferGetBytesPerRowOfPlane(source, plane) * 64 / 2
      for i in 0..<count { pointer[i] = (plane == 0 ? lumaCode : 512) << 6 }
    }
    CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
    return source
  }

  func testExplicitConversionChangesPixelsAndWrongSourceRefuses() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    let source = try graySource(transfer: kCVImageBufferTransferFunction_Linear)
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let colour = try LUTProcessor.sourceColorimetry(source)
    let configuration = PipelineConfiguration(applyLUT: true, downscale: false)
    XCTAssertThrowsError(try processor.process(source, configuration: configuration,
      colorConversion: .sourceToLUTInput(from: .rec709Video, to: .rec709Video)))
    let output = try processor.process(source, configuration: configuration,
      colorConversion: .sourceToLUTInput(from: colour, to: .rec709Video))
    CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt8.self)
    XCTAssertEqual(Int(y[64]), 170, accuracy: 1)
  }

  func testFitWritesBlackBarsAndCropFillsCanvasOnGPU() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    let source = try graySource()
    let processor = try LUTProcessor()
    var configuration = PipelineConfiguration(applyLUT: false, downscale: true)
    for mode in [ProgramScalingMode.fit, .crop] {
      configuration.scalingMode = mode
      let output = try processor.process(source, configuration: configuration)
      CVPixelBufferLockBaseAddress(output, .readOnly)
      let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
      XCTAssertEqual(Int(y[10 * stride + 960]), mode == .fit ? 16 : 126, accuracy: 1)
      XCTAssertEqual(Int(y[540 * stride + 960]), 126, accuracy: 1)
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }
  }
}

extension LUTDynamicSizeChecks {
  func testRGBSourcesExecuteThroughLUTOutput() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    for type: OSType in [kCVPixelFormatType_32BGRA, 0x72323130, 0x5231324c] {
      var image: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 128, 64, type,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &image), kCVReturnSuccess)
      let source = try XCTUnwrap(image)
      CVPixelBufferLockBaseAddress(source, [])
      let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(source)
      for i in 0..<(stride * 64) { bytes[i] = 0 }
      for y in 0..<64 { for x in 0..<128 {
        let i = y * stride + x * 4
        if type == 0x72323130 {
          bytes[i] = 0x3a; bytes[i+1] = 0xc1; bytes[i+2] = 0; bytes[i+3] = 0x40
        } else if type == 0x5231324c {
          for bit in 0..<12 {
            let offset = x * 36 + bit
            bytes[y * stride + offset / 8] |= UInt8(1 << (offset % 8))
          }
        } else {
          bytes[i] = 0; bytes[i+1] = 0; bytes[i+2] = 255; bytes[i+3] = 255
        }
      } }
      CVPixelBufferUnlockBaseAddress(source, [])
      let processor = try LUTProcessor()
      let output = try processor.process(source, configuration: PipelineConfiguration(applyLUT: false, downscale: false))
      CVPixelBufferLockBaseAddress(output, .readOnly)
      let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt8.self)
      XCTAssertEqual(Int(y[64]), 63, accuracy: 1)
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }
  }
}

extension LUTGPUConversionContractChecks {
  func testBothEdgesRequireExactEndpoints() throws {
    let sdr = Colorimetry.rec709Video
    let linear = Colorimetry(primaries: .rec709, transfer: .linear, matrix: .rec709,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
    let contract = LUTColorSpaceContract(input: sdr, output: sdr)
    try contract.validate(source: linear, destination: linear,
      conversion: .sourceAndOutput(fromSource: linear, toLUTInput: sdr,
        fromLUTOutput: sdr, toDestination: linear))
    XCTAssertThrowsError(try contract.validate(source: linear, destination: linear,
      conversion: .sourceAndOutput(fromSource: sdr, toLUTInput: sdr,
        fromLUTOutput: sdr, toDestination: linear)))
  }
}

extension LUTDynamicSizeChecks {
  func testOutputBudgetDeduplicatesPlanesAndEvictsByMonotonicAge() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    final class Clock: @unchecked Sendable {
      let lock = NSLock(); var time: TimeInterval = 10
      func now() -> TimeInterval { lock.withLock { time } }
      func advance() { lock.withLock { time = 20 } }
    }
    let clock = Clock()
    let processor = try LUTProcessor(cacheIdleAge: 4, monotonicNow: { clock.now() })
    let output = try processor.process(graySource(), configuration: PipelineConfiguration(downscale: false))
    let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(output)?.takeUnretainedValue())
    XCTAssertEqual(processor.cachedAllocationCountForTesting, 1)
    XCTAssertEqual(processor.cachedAllocationBytesForTesting, IOSurfaceGetAllocSize(surface))
    processor.sweepOutputCacheForTesting()
    XCTAssertEqual(processor.cachedAllocationCountForTesting, 1)
    clock.advance(); processor.sweepOutputCacheForTesting()
    let deadline = Date().addingTimeInterval(1)
    while processor.cachedAllocationBytesForTesting != 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    XCTAssertEqual(processor.cachedAllocationBytesForTesting, 0)
    // The published output survives cache retirement independently.
    XCTAssertEqual(CVPixelBufferGetWidth(output), 128)
  }

  func testInFlightRecordRetainsBudgetLeaseAcrossStaleCompletionSweep() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    let processor = try LUTProcessor(cacheIdleAge: 0.001)
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    processor.commandTimingObserver = { _ in entered.signal(); _ = release.wait(timeout: .now() + 3) }
    try processor.submit(graySource(), configuration: PipelineConfiguration(downscale: false)) { _ in done.signal() }
    XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
    Thread.sleep(forTimeInterval: 0.005)
    processor.sweepOutputCacheForTesting()
    XCTAssertGreaterThan(processor.cachedAllocationBytesForTesting, 0, "Completion record must retain the backing lease after cache eviction")
    release.signal()
    XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
    let deadline = Date().addingTimeInterval(1)
    while processor.cachedAllocationBytesForTesting != 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    XCTAssertEqual(processor.cachedAllocationBytesForTesting, 0)
  }

  func testBudgetRefusesMinimumThatCannotFit() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    let processor = try LUTProcessor(cacheMaximumBytes: 1)
    XCTAssertThrowsError(try processor.process(graySource(), configuration: PipelineConfiguration(downscale: false))) {
      guard case .minimumDoesNotFit = $0 as? GPUAllocationBudgetFailure else { return XCTFail("Expected minimum byte budget refusal: \($0)") }
    }
    XCTAssertEqual(processor.cachedAllocationBytesForTesting, 0)
  }
}

extension LUTDynamicSizeChecks {
  func testPoolPressureUsesActualSurfaceBytesAndHeldFramesStayValid() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    let source = try graySource()
    let configuration = PipelineConfiguration(downscale: false)
    let probeProcessor = try LUTProcessor()
    let probe = try probeProcessor.process(source, configuration: configuration)
    let bytes = IOSurfaceGetAllocSize(try XCTUnwrap(CVPixelBufferGetIOSurface(probe)?.takeUnretainedValue()))
    let processor = try LUTProcessor(cacheMaximumBytes: bytes * VideoContract.maxFramesInFlight)
    var held: [CVPixelBuffer] = []
    for _ in 0..<VideoContract.maxFramesInFlight { held.append(try processor.process(source, configuration: configuration)) }
    XCTAssertEqual(processor.cachedAllocationBytesForTesting, bytes * VideoContract.maxFramesInFlight)
    XCTAssertThrowsError(try processor.process(source, configuration: configuration)) {
      guard case .outputBackPressure = $0 as? VideoError else { return XCTFail("Expected bounded output pressure: \($0)") }
    }
    for image in held { XCTAssertEqual(CVPixelBufferGetWidth(image), 128) }
    held.removeAll()
  }
}

extension LUTDynamicSizeChecks {
  func testFailedWorkingAllocationRollsBackPreparedSurfaceLeases() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &image), kCVReturnSuccess)
    let processor = try LUTProcessor(cacheMaximumBytes: 12 * 1024 * 1024)
    XCTAssertThrowsError(try processor.process(XCTUnwrap(image), configuration: PipelineConfiguration()))
    XCTAssertEqual(processor.cachedAllocationBytesForTesting, 0, "A failed pre-commit frame must release staged views and their byte leases")
  }
}

extension LUTGPUConversionContractChecks {
  func testTransportDifferencesDoNotChangeLUTRGBEncoding() throws {
    let declared = Colorimetry.rec709Video
    let transport = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec601,
      range: .full, horizontalChromaSiting: .center, verticalChromaSiting: .top)
    try LUTColorSpaceContract(input: declared, output: declared).validate(source: transport, destination: transport)
    // An explicit conversion still must identify its concrete endpoints.
    XCTAssertThrowsError(try LUTColorSpaceContract(input: declared, output: declared)
      .validate(source: transport, destination: declared,
        conversion: .sourceToLUTInput(from: declared, to: declared)))
  }
}

extension LUTDynamicSizeChecks {
  func testTransportRangeMatrixAndSitingDecodeBeforeTheLUT() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    for full in [false, true] {
      let source = try graySource(pixelFormat: full ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        lumaCode: full ? 512 : 502)
      CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
      CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
      let output = try processor.process(source, configuration: PipelineConfiguration(applyLUT: true, downscale: false))
      CVPixelBufferLockBaseAddress(output, .readOnly)
      let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt8.self)
      XCTAssertEqual(Int(y[64]), 126, accuracy: 1)
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }
  }

  func testNegotiatedLUTOutputRejectsWrongRGBEncodingBeforeGPUWork() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    var configuration = PipelineConfiguration(applyLUT: true, downscale: false)
    configuration.lutOutputColorimetry = Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020,
      range: .video, horizontalChromaSiting: .center, verticalChromaSiting: .center)
    XCTAssertThrowsError(try processor.process(graySource(), configuration: configuration)) {
      guard case .outputMismatch = $0 as? LUTColorSpaceContractError else { return XCTFail("Expected negotiated LUT output mismatch: \($0)") }
    }
    XCTAssertEqual(processor.framesInFlight, 0)
    XCTAssertEqual(processor.cachedAllocationBytesForTesting, 0)
  }
}

extension LUTDynamicSizeChecks {
  func testTypedUntaggedPassthroughCopiesPixelsAndStampsAuthoritativeColor() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 64, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &made), kCVReturnSuccess)
    let image = try XCTUnwrap(made)
    CVPixelBufferLockBaseAddress(image, [])
    let initial = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt32.self)
    for i in 0..<(CVPixelBufferGetBytesPerRow(image) * 64 / 4) { initial[i] = UInt32(i) & 0x3fff_ffff }
    CVPixelBufferUnlockBaseAddress(image, [])
    CVBufferRemoveAllAttachments(image)
    let colour = Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020,
      range: .video, horizontalChromaSiting: .center, verticalChromaSiting: .top)
    let format = try SourceFormat(width: 128, height: 64, pixelAspect: Rational(4, 3),
      pixel: PixelFormatID(rawValue: CVPixelBufferGetPixelFormatType(image)), colour: colour,
      rate: .constant(VideoContract.fastDuration))
    let source = try SourceAdmissionSnapshot(format: format,
      epochID: CaptureEpochID(sessionID: UUID(), epoch: 0),
      clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .lut)
    let metadata = SourceAdmissionMetadata(pixelBuffer: image, presentationTime: .zero,
      duration: VideoContract.fastDuration, epochID: source.epochID, formatSignature: source.formatSignature)
    final class ResultBox: @unchecked Sendable {
      let lock = NSLock(); var value: Result<CVPixelBuffer, Error>?
      func set(_ value: Result<CVPixelBuffer, Error>) { lock.withLock { self.value = value } }
      func get() -> Result<CVPixelBuffer, Error>? { lock.withLock { value } }
    }
    let box = ResultBox(), done = DispatchSemaphore(value: 0)
    let processor = try LUTProcessor()
    try processor.submitPassthrough(image, source: source, metadata: metadata) {
      box.set($0.result); done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    let output = try XCTUnwrap(box.get()).get()
    XCTAssertFalse(output === image)
    XCTAssertEqual(try LUTProcessor.sourceColorimetry(output), colour)
    XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, nil) as? String,
      kCVImageBufferColorPrimaries_ITU_R_2020 as String)
    XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String,
      kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferChromaLocationTopFieldKey, nil) as? String,
      kCVImageBufferChromaLocation_Top as String)
    XCTAssertNil(CVBufferCopyAttachment(image, kCVImageBufferColorPrimariesKey, nil), "Copy must not mutate source attachments")
    CVPixelBufferLockBaseAddress(image, .readOnly); CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly); CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let a = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt32.self)
    let b = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt32.self)
    for y in 0..<64 { for x in 0..<((128 + 5) / 6 * 4) {
      XCTAssertEqual(a[y * CVPixelBufferGetBytesPerRow(image) / 4 + x],
        b[y * CVPixelBufferGetBytesPerRow(output) / 4 + x])
    } }
  }
}

extension LUTDynamicSizeChecks {
  func testPhysicalPixelAspectFitRemovesNativePixelAspectMetadata() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    let source = try graySource()
    CVBufferSetAttachment(source, kCVImageBufferPixelAspectRatioKey,
      [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 2,
       kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1] as CFDictionary, .shouldPropagate)
    var configuration = PipelineConfiguration(downscale: false)
    configuration.sourcePixelAspect = try Rational(2, 1)
    let processor = try LUTProcessor()
    let output = try processor.process(source, configuration: configuration)
    XCTAssertNil(CVBufferCopyAttachment(output, kCVImageBufferPixelAspectRatioKey, nil),
      "Physical fitting produces square output pixels; native PAR would apply the correction twice")
    XCTAssertNotNil(CVBufferCopyAttachment(source, kCVImageBufferPixelAspectRatioKey, nil))
    CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
    XCTAssertEqual(Int(y[5 * stride + 64]), 16, accuracy: 1)
    XCTAssertEqual(Int(y[32 * stride + 64]), 126, accuracy: 1)
  }
}
