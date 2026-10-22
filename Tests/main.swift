import CoreImage
import CoreMedia
import CoreVideo
import XCTest

func cubeText(size: Int = 2, transform: (Float) -> Float = { $0 }) -> String {
  var lines = ["TITLE \"Synthetic test LUT\"", "LUT_3D_SIZE \(size)"]
  for b in 0..<size {
    for g in 0..<size {
      for r in 0..<size {
        lines.append("\(transform(Float(r) / Float(size - 1))) \(transform(Float(g) / Float(size - 1))) \(transform(Float(b) / Float(size - 1)))")
      }
    }
  }
  return lines.joined(separator: "\n")
}

func syntheticRamp() throws -> CVPixelBuffer {
  var image: CVPixelBuffer?
  let status = CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
    [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &image)
  guard status == kCVReturnSuccess, let image else { throw VideoError.message("Synthetic buffer allocation failed.") }
  CVPixelBufferLockBaseAddress(image, [])
  defer { CVPixelBufferUnlockBaseAddress(image, []) }
  for plane in 0..<2 {
    let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane) / 2
    let pointer = CVPixelBufferGetBaseAddressOfPlane(image, plane)!.assumingMemoryBound(to: UInt16.self)
    for y in 0..<2160 {
      for x in 0..<stride {
        pointer[y * stride + x] = UInt16(plane == 0 ? 64 + min(x, 3839) * 876 / 3839 : 512) << 6
      }
    }
  }
  CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
  return image
}

@objcMembers final class CubeTests: XCTestCase {
  func testOrderingAndWhitespace() throws {
    let cube = try CubeLUT(text: cubeText().replacingOccurrences(of: "LUT_3D_SIZE ", with: "LUT_3D_SIZE\t") + "\n# comment")
    XCTAssertEqual(cube.dimension, 2)
    XCTAssertEqual(Array(cube.rgba[4..<8]), [1, 0, 0, 1])
    XCTAssertEqual(Array(cube.rgba[8..<12]), [0, 1, 0, 1])
    XCTAssertEqual(Array(cube.rgba[16..<20]), [0, 0, 1, 1])
  }
  func testUTF8BOMIsIgnored() throws {
    let cube = try CubeLUT(text: "\u{FEFF}" + cubeText(), fallbackTitle: "fallback")
    XCTAssertEqual(cube.dimension, 2)
    XCTAssertEqual(cube.title, "Synthetic test LUT")
  }
  func testTitlePreservesQuotedTextAndRejectsMisplacement() throws {
    let source = cubeText().replacingOccurrences(of: "TITLE \"Synthetic test LUT\"",
      with: "TITLE \"  Look #1  \" # inline comment")
    XCTAssertEqual(try CubeLUT(text: source).title, "  Look #1  ")
    XCTAssertThrowsError(try CubeLUT(text: cubeText().replacingOccurrences(of: "TITLE \"Synthetic test LUT\"",
      with: "TITLE unquoted")))
    XCTAssertThrowsError(try CubeLUT(text: cubeText() + "\nTITLE \"again\""))
  }
  func testRejectIncompleteOversizedAndNonFinite() {
    XCTAssertThrowsError(try CubeLUT(text: "LUT_3D_SIZE 2\n0 0 0"))
    XCTAssertThrowsError(try CubeLUT(text: "LUT_3D_SIZE 256"))
    XCTAssertThrowsError(try CubeLUT(text: cubeText().replacingOccurrences(of: "0.0 0.0 0.0", with: "nan 0 0")))
    XCTAssertThrowsError(try CubeLUT(text: cubeText().replacingOccurrences(of: "0.0 0.0 0.0", with: "1e38 0 0")))
    XCTAssertThrowsError(try CubeLUT(text: String(repeating: "#", count: 251)))
    XCTAssertThrowsError(try CubeLUT(text: cubeText() + "\n0 0 0"))
    XCTAssertThrowsError(try CubeLUT(text: "LUT_1D_SIZE 2\n0 0 0\n1 1 1"))
  }
  func testDomain() throws {
    let text = cubeText().replacingOccurrences(of: "LUT_3D_SIZE 2", with: "LUT_3D_SIZE 2\nDOMAIN_MIN -1 0 0\nDOMAIN_MAX 1 2 3")
    let cube = try CubeLUT(text: text)
    XCTAssertEqual(cube.domainMin, SIMD3(-1, 0, 0))
    XCTAssertEqual(cube.domainMax, SIMD3(1, 2, 3))
    XCTAssertThrowsError(try CubeLUT(text: cubeText().replacingOccurrences(of: "LUT_3D_SIZE 2", with: "LUT_3D_SIZE 2\nDOMAIN_MAX 0 1 1")))
    XCTAssertThrowsError(try CubeLUT(text: cubeText().replacingOccurrences(of: "LUT_3D_SIZE 2",
      with: "LUT_3D_SIZE 2\nDOMAIN_MIN -3e38 0 0\nDOMAIN_MAX 3e38 1 1")))
    XCTAssertThrowsError(try CubeLUT(text: cubeText().replacingOccurrences(of: "LUT_3D_SIZE 2",
      with: "LUT_3D_SIZE 2\nDOMAIN_MAX 1e-45 1 1")))
  }
  static let allTests = [
    ("ordering and whitespace", testOrderingAndWhitespace),
    ("UTF-8 BOM", testUTF8BOMIsIgnored),
    ("title parsing", testTitlePreservesQuotedTextAndRejectsMisplacement),
    ("invalid LUT rejection", testRejectIncompleteOversizedAndNonFinite),
    ("domain validation", testDomain),
  ]
}

@objcMembers final class PipelineTests: XCTestCase {
  func testTenBitPrecision() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let source = try syntheticRamp()
    let configuration = PipelineConfiguration(applyLUT: true, downscale: false,
      convertTo420: false, reduceFrameRate: false, inputFast: true)
    let output = try processor.process(source, configuration: configuration)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let pointer = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt16.self)
    let levels = Set((0..<3840).map { pointer[$0] >> 6 })
    XCTAssertGreaterThan(levels.count, 800, "10-bit gradient must not be reduced to 256 levels inside LUT processing")
    XCTAssertEqual(Double(pointer[0] >> 6), 64, accuracy: 2)
    XCTAssertEqual(Double(pointer[3839] >> 6), 940, accuracy: 2)
  }
  func testLUTAndLanczosThenNV12() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 })))
    let output = try processor.process(syntheticRamp(), configuration: PipelineConfiguration(applyLUT: true))
    XCTAssertEqual(CVPixelBufferGetWidth(output), 1920)
    XCTAssertEqual(CVPixelBufferGetHeight(output), 1080)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    XCTAssertEqual(CVPixelBufferGetHeightOfPlane(output, 1), 540)
    CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let pointer = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)
    // Mid-ramp log code 0.5 maps to 0.25 through this synthetic cube.
    // Video range output is 16 + 219 * 0.25, not a hidden gamma transform.
    XCTAssertEqual(Double(pointer[960]), 16 + 219 * 0.25, accuracy: 3)
  }
  func testUntouchedFrameIsSameBuffer() throws {
    let processor = try LUTProcessor()
    let source = try syntheticRamp()
    let configuration = PipelineConfiguration(applyLUT: false, downscale: false,
      convertTo420: false, reduceFrameRate: false, inputFast: true)
    let output = try processor.process(source, configuration: configuration)
    XCTAssertTrue(source === output)
  }
  func testIndependentSwitches() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let source = try syntheticRamp()
    for bits in 0..<8 {
      let config = PipelineConfiguration(applyLUT: bits & 1 != 0, downscale: bits & 2 != 0,
        convertTo420: bits & 4 != 0, reduceFrameRate: bits & 8 != 0, inputFast: true)
      XCTAssertEqual(config.width, bits & 2 != 0 ? 1920 : 3840)
      XCTAssertEqual(config.duration, bits & 8 != 0 ? VideoContract.slowDuration : VideoContract.fastDuration)
      XCTAssertEqual(config.pixelFormat, bits & 4 != 0 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
      let output = try processor.process(source, configuration: config)
      XCTAssertEqual(CVPixelBufferGetWidth(output), bits & 2 != 0 ? 1920 : 3840)
      XCTAssertEqual(CVPixelBufferGetHeight(output), bits & 2 != 0 ? 1080 : 2160)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), bits & 4 != 0 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    }
  }
  func testNonlinearLUTPrecedesLanczos() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 })))
    let source = try syntheticRamp()
    CVPixelBufferLockBaseAddress(source, [])
    let stride = CVPixelBufferGetBytesPerRowOfPlane(source, 0) / 2
    let pixels = CVPixelBufferGetBaseAddressOfPlane(source, 0)!.assumingMemoryBound(to: UInt16.self)
    for y in 0..<2160 {
      for x in 0..<3840 { pixels[y * stride + x] = UInt16(x % 2 == 0 ? 64 : 940) << 6 }
    }
    CVPixelBufferUnlockBaseAddress(source, [])
    let output = try processor.process(source, configuration: PipelineConfiguration(applyLUT: true))
    CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let result = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)
    // LUT-first preserves the black/white endpoints, which Lanczos averages to
    // 0.5. Applying the square LUT after scaling would give 0.25 instead.
    XCTAssertEqual(Double(result[960]), 16 + 219 * 0.5, accuracy: 3)
  }
  func testPackedV210Precision() throws {
    var input: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &input), kCVReturnSuccess)
    let source = try XCTUnwrap(input)
    CVPixelBufferLockBaseAddress(source, [])
    let stride = CVPixelBufferGetBytesPerRow(source) / 4
    let base = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt32.self)
    func luma(_ x: Int) -> UInt32 { UInt32(64 + x * 876 / 3839) }
    var row = [UInt32](repeating: 0, count: stride)
    for x in Swift.stride(from: 0, to: 3840, by: 6) {
      let offset = x / 6 * 4
      row[offset] = 512 | (luma(x) << 10) | (512 << 20)
      row[offset + 1] = luma(x + 1) | (512 << 10) | (luma(x + 2) << 20)
      row[offset + 2] = 512 | (luma(x + 3) << 10) | (512 << 20)
      row[offset + 3] = luma(x + 4) | (512 << 10) | (luma(x + 5) << 20)
    }
    row.withUnsafeBytes { bytes in
      for y in 0..<2160 { memcpy(base.advanced(by: y * stride), bytes.baseAddress!, bytes.count) }
    }
    CVPixelBufferUnlockBaseAddress(source, [])
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let output = try processor.process(source, configuration: PipelineConfiguration(
      applyLUT: true, downscale: false, convertTo420: false, reduceFrameRate: false, inputFast: true))
    CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let pixels = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt16.self)
    for x in 0..<3840 { XCTAssertEqual(Double(pixels[x] >> 6), Double(luma(x)), accuracy: 1) }
  }
  func testRationalFrameReductionDoesNotDrift() {
    var gate = FrameRateGate()
    var delivered = 0
    for frame in 0..<6000 {
      if gate.shouldDeliver(CMTime(value: Int64(frame) * 1001, timescale: 60_000), duration: VideoContract.slowDuration) { delivered += 1 }
    }
    XCTAssertEqual(delivered, 3000)
    XCTAssertFalse(gate.shouldDeliver(.invalid, duration: VideoContract.slowDuration))
    XCTAssertTrue(gate.shouldDeliver(.zero, duration: VideoContract.slowDuration), "Clock reset should restart cadence")

    gate.reset()
    XCTAssertTrue(gate.shouldDeliver(CMTime(value: 6_000, timescale: 60_000),
      duration: VideoContract.slowDuration))
    XCTAssertTrue(gate.shouldDeliver(CMTime(value: 3_000, timescale: 60_000),
      duration: VideoContract.slowDuration), "A backwards source clock must restart cadence")
    XCTAssertFalse(gate.shouldDeliver(CMTime(value: 4_001, timescale: 60_000),
      duration: VideoContract.slowDuration))
    XCTAssertFalse(gate.shouldDeliver(CMTime(value: 5_002, timescale: 60_000),
      duration: .invalid), "Invalid durations must never pass the gate")
    XCTAssertFalse(gate.shouldDeliver(CMTime(value: 5_002, timescale: 60_000, flags: .valid, epoch: 1),
      duration: VideoContract.slowDuration), "Foreign source epochs must be rejected")
  }
  static let allTests = [
    ("10-bit GPU precision", testTenBitPrecision),
    ("LUT then Lanczos then NV12", testLUTAndLanczosThenNV12),
    ("full-data passthrough", testUntouchedFrameIsSameBuffer),
    ("independent switches", testIndependentSwitches),
    ("exact frame-rate reduction", testRationalFrameReductionDoesNotDrift),
  ]
}

let suite = XCTestSuite(name: "Ultracam synthetic checks")
suite.addTest(XCTestSuite(forTestCaseClass: CubeTests.self))
suite.addTest(XCTestSuite(forTestCaseClass: PipelineTests.self))
suite.addTest(XCTestSuite(forTestCaseClass: GPUExtendedChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: SampleFactoryChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: GPURawCopyChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: EndToEndChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: CameraContractChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: CameraAuthorizationChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: DeckLinkChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: PreviewChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: MonitorLifecycleChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: MonitorCoordinatorChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: SettingsChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: RecordingModelChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: SourceRecordingAdapterChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: VirtualCameraRegistryChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: VirtualCameraRegistryPublishingChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: CameraRegistryRuntimeChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: CameraSinkRoutingChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: ProgramOutputRouteChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: AutomaticFeedChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: EmbeddedAudioRecordingChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: RecordingChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: RecordingTimecodeChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: RecordingOutputChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: RecordingStatisticsChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: ProResRecordingConfigurationChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: RecordingEndToEndChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: RouteDemandCoordinatorChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: NaturalTalkingHeadAutoSwitcherChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: ProgramTimestampMapperChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: SwitcherCoordinatorChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: ProcessedFrameChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: FeedRuntimeChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: AutoSwitcherBridgeChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: AutoSwitcherTimelineChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: InstallerChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: MulticamRuntimeChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: UIPresentationChecks.self))
#if CAPTURE_LIFECYCLE_TESTS
suite.addTest(XCTestSuite(forTestCaseClass: CaptureLifecycleChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: CaptureRecordingIsolationChecks.self))
#endif
suite.run()
guard let run = suite.testRun, run.executionCount > 0 else { exit(2) }
exit(run.hasSucceeded ? 0 : 1)
