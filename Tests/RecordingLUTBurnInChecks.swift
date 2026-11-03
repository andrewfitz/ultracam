import AVFoundation
import CoreVideo
import VideoToolbox
import XCTest

/// Burn LUT into recordings: the LUT runs on the GPU in the direct capture →
/// encoder path, the buffer VideoToolbox receives carries the graded pixels and
/// the LUT output's colour tags, and the sidecar names the LUT.
@objcMembers final class RecordingLUTBurnInChecks: XCTestCase {
  private static let width = 320, height = 64
  private static let neutralLuma: UInt32 = 283

  // MARK: GPU record path

  func testBurnInChangesKnownPixelAndOffLeavesItUnchanged() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("Metal 4 required") }
    let source = try declaration()
    // Off: the clean repack, bit for bit.
    let clean = try record(source: source, burnIn: nil)
    XCTAssertEqual(clean.luma, Int(Self.neutralLuma), "With the setting off the recorded pixel is the camera's")
    XCTAssertEqual(clean.chroma, [512, 512])
    XCTAssertEqual(clean.chromaLocation, kCVImageBufferChromaLocation_Left as String, "The clean take keeps the source's siting")
    XCTAssertNil(clean.sidecar.metadata.burnedInLUT)
    XCTAssertFalse(clean.sidecar.metadata.conversionNotes.contains { $0.contains("LUT") })

    // On: 1 − x inverts neutral grey 283 to 721, as Program's burn-in does (EndToEndChecks).
    let renderer = try RecordingLUTRenderer(snapshot: snapshot(cube: cubeText(transform: { 1 - $0 }), colour: .rec709Video))
    let burned = try record(source: source, burnIn: renderer)
    XCTAssertEqual(Double(burned.luma), 721, accuracy: 1, "The LUT ran on the frame handed to the encoder")
    XCTAssertEqual(Double(burned.chroma[0]), 512, accuracy: 1)
    XCTAssertEqual(Double(burned.chroma[1]), 512, accuracy: 1)
    XCTAssertEqual(burned.format, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, "The encoder's own layout and pool")
    XCTAssertEqual(burned.size, [Self.width, Self.height], "Same size as the source")
    XCTAssertEqual(burned.chromaLocation, kCVImageBufferChromaLocation_Center as String, "The LUT pass writes centred chroma")
    XCTAssertEqual(burned.gpuFrames, 1)
    XCTAssertEqual(burned.compatibilityFrames, 0)
    XCTAssertEqual(burned.passThroughFrames, 0)
    XCTAssertEqual(burned.encoded, 1)
    let lut = try XCTUnwrap(burned.sidecar.metadata.burnedInLUT)
    XCTAssertEqual(lut.name, "Synthetic test LUT")
    XCTAssertEqual(lut.recordedColour, renderer.outputColour)
    XCTAssertEqual(burned.sidecar.metadata.outputContract?.outputColour, renderer.outputColour)
    XCTAssertEqual(burned.sidecar.metadata.sourceFormat?.colour, source.format.colour, "The camera's own colour stays on record")
    XCTAssertTrue(burned.sidecar.metadata.conversionNotes.contains { $0.contains("Synthetic test LUT") && $0.contains("burned in") })
    XCTAssertNotEqual(burned.sidecar.metadata.outputSignature, clean.sidecar.metadata.outputSignature,
      "A graded take is a different output from the clean one")
  }

  /// A LUT from an HDR/log camera space to Rec.709: the file says Rec.709,
  /// as Program and the virtual camera tag their burned-in frames.
  func testBurnedInTakeIsTaggedWithTheLUTOutputColour() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("Metal 4 required") }
    let hlg = Colorimetry(primaries: .rec2020, transfer: .hlg, matrix: .rec2020, range: .video,
      horizontalChromaSiting: .left, verticalChromaSiting: .center)
    let source = try declaration(colour: hlg)
    let renderer = try RecordingLUTRenderer(snapshot: snapshot(cube: cubeText(), colour: hlg, output: .rec709Video))
    XCTAssertEqual(renderer.outputColour, Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709,
      range: .video, horizontalChromaSiting: .center, verticalChromaSiting: .center))
    let burned = try record(source: source, burnIn: renderer)
    XCTAssertEqual(burned.primaries, kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
    XCTAssertEqual(burned.transfer, kCVImageBufferTransferFunction_ITU_R_709_2 as String)
    XCTAssertEqual(burned.matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    XCTAssertEqual(burned.sidecar.metadata.outputContract?.outputColour.transfer, .rec709)
    XCTAssertEqual(burned.sidecar.metadata.sourceFormat?.colour.transfer, .hlg)
    let lut = try XCTUnwrap(burned.sidecar.metadata.burnedInLUT)
    XCTAssertEqual(lut.inputColour, hlg)
    XCTAssertEqual(lut.outputColour, .rec709Video)
    let clean = try record(source: source, burnIn: nil)
    XCTAssertEqual(clean.transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG as String, "Off keeps the camera's tags")
  }

  /// The colour Program's virtual camera advertises for the same LUT.
  func testRecordedColourMatchesTheVirtualCameraRule() throws {
    let output = Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020, range: .video,
      horizontalChromaSiting: .left, verticalChromaSiting: .center)
    let lutSnapshot = try snapshot(cube: cubeText(), colour: .rec709Video, output: output, declaredOutput: output)
    var configuration = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false)
    configuration.lutOutputColorimetry = output
    XCTAssertEqual(RecordingLUTRenderer.recordedColour(lutSnapshot),
      try CameraSink.resolvedOutputColour(configuration: configuration, sourceFormat: nil))
  }

  // MARK: Refusals, never a silent clean take

  func testFormatsTheLUTPassCannotWriteRefuseAtTakeStart() throws {
    let renderer = try RecordingLUTRenderer(snapshot: snapshot(cube: cubeText(), colour: .rec709Video))
    let movie = URL(fileURLWithPath: "/tmp/burn-in-refusal.mov")
    let rgb = try declaration(pixel: .r210, colour: Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .identity,
      range: .video, horizontalChromaSiting: .unspecified, verticalChromaSiting: .unspecified))
    XCTAssertThrowsError(try configuration(source: rgb, movie: movie, profile: .proRes4444, burnIn: renderer)) { error in
      guard case RecordingLUTBurnInError.unsupported(let reason)? = error as? RecordingLUTBurnInError else {
        return XCTFail("Expected a burn-in refusal, got \(error)")
      }
      XCTAssertTrue(reason.contains("ProRes 4444"), reason)
      XCTAssertTrue(error.localizedDescription.contains("Turn the setting off"), error.localizedDescription)
    }
    XCTAssertNoThrow(try configuration(source: rgb, movie: movie, profile: .proRes4444, burnIn: nil),
      "Without the LUT the same take records as before")
    let uyva = try declaration(pixel: .uyva)
    XCTAssertThrowsError(try configuration(source: uyva, movie: movie, profile: .proRes422HQ, burnIn: renderer)) { error in
      guard case RecordingLUTBurnInError.unsupported(let reason)? = error as? RecordingLUTBurnInError else {
        return XCTFail("Expected a burn-in refusal, got \(error)")
      }
      XCTAssertTrue(reason.contains("UYVA"), reason)
    }
    for profile in [RecordingProfileMatrixProfile.proResLT, .proRes422, .proRes422HQ, .hevcMain10_422] {
      XCTAssertNil(renderer.refusal(sourcePixelFormat: kCVPixelFormatType_422YpCbCr10, encoderPixelFormat: profile.encoderPixelFormat),
        "\(profile.displayName) burns in from v210")
    }
    XCTAssertNil(renderer.refusal(sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      encoderPixelFormat: RecordingProfileMatrixProfile.hevcMain.encoderPixelFormat))
    XCTAssertNil(renderer.refusal(sourcePixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      encoderPixelFormat: RecordingProfileMatrixProfile.hevcMain10.encoderPixelFormat))
    XCTAssertNotNil(renderer.refusal(sourcePixelFormat: kCVPixelFormatType_422YpCbCr10,
      encoderPixelFormat: kCVPixelFormatType_64RGBALE))
  }

  /// A frame whose GPU burn-in fails ends the take; it never goes to the
  /// encoder clean, even with CPU compatibility allowed.
  func testFailedBurnInStopsTheTakeInsteadOfRecordingCleanFrames() throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let source = try declaration()
    let movie = folder.appendingPathComponent("failed.mov")
    let failing = FailingBurnIn()
    let config = try configuration(source: source, movie: movie, profile: .proRes422HQ, burnIn: failing,
      policy: RecordingCompatibilityPolicy(allowCPUConversion: true))
    let handed = Handed()
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { session, image, pts, duration in
      handed.lock.withLock { handed.count += 1 }
      var flags = VTEncodeInfoFlags()
      return VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: duration,
        frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
    })
    try writer.start()
    try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
    XCTAssertThrowsError(try writer.appendVideoOutcome(sample(try v210Frame()))) { error in
      guard case RecordingLUTBurnInError.renderFailed? = error as? RecordingLUTBurnInError else {
        return XCTFail("Expected a burn-in failure, got \(error)")
      }
    }
    XCTAssertEqual(handed.lock.withLock { handed.count }, 0, "No clean frame reached the encoder")
    XCTAssertEqual(writer.telemetry.systemCompatibilityFrames, 0)
    XCTAssertEqual(writer.telemetry.gpuConversionFailures, 1)
    try? writer.finish()
  }

  // MARK: Sidecar

  func testSidecarRecordsTheLUTAndReadsOlderTakes() throws {
    var metadata = RecordingTakeSidecar.Metadata(sourceSignature: "s", outputSignature: "o")
    XCTAssertNil(metadata.burnedInLUT)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
    XCTAssertNil(json["burnedInLUT"], "A clean take has no LUT record")
    let record = RecordingTakeSidecar.BurnedInLUT(name: "Slog3 to 709", fileName: "Slog3-709.cube",
      inputColour: .rec709Video, outputColour: .rec709Video,
      recordedColour: Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709, range: .video,
        horizontalChromaSiting: .center, verticalChromaSiting: .center))
    metadata.burnedInLUT = record
    let data = try JSONEncoder().encode(metadata)
    json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let lut = try XCTUnwrap(json["burnedInLUT"] as? [String: Any])
    XCTAssertEqual(lut["name"] as? String, "Slog3 to 709")
    XCTAssertEqual(lut["fileName"] as? String, "Slog3-709.cube")
    XCTAssertEqual(try JSONDecoder().decode(RecordingTakeSidecar.Metadata.self, from: data).burnedInLUT, record)
    // A sidecar from before the setting, and one with a malformed record, still read.
    let old = try JSONDecoder().decode(RecordingTakeSidecar.Metadata.self,
      from: Data(#"{"sourceSignature":"s","outputSignature":"o"}"#.utf8))
    XCTAssertNil(old.burnedInLUT)
    let malformed = try JSONDecoder().decode(RecordingTakeSidecar.Metadata.self,
      from: Data(#"{"sourceSignature":"s","outputSignature":"o","burnedInLUT":{"name":3}}"#.utf8))
    XCTAssertNil(malformed.burnedInLUT)
    XCTAssertEqual(malformed.sourceSignature, "s")
  }

  func testRequestedWithoutACameraLUTRecordsCleanAndSaysSo() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("Metal 4 required") }
    let source = try declaration()
    let clean = try record(source: source, burnIn: nil, requested: true)
    XCTAssertEqual(clean.luma, Int(Self.neutralLuma))
    XCTAssertNil(clean.sidecar.metadata.burnedInLUT)
    XCTAssertTrue(clean.sidecar.metadata.conversionNotes.contains { $0.contains("no LUT") && $0.contains("clean") },
      "\(clean.sidecar.metadata.conversionNotes)")
  }

  // MARK: A take's frames and its processor

  /// A take of many frames: every frame is burned in and encoded, the LUT pass
  /// writes into the encoder pool's recycled buffers (never more than the
  /// pool's bound), and the take's own LUT processor goes away with the take.
  func testEveryFrameRecyclesTheEncoderPoolAndTheProcessorEndsWithTheTake() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("Metal 4 required") }
    let source = try declaration()
    weak var weakRenderer: RecordingLUTRenderer?
    var surfaces = Set<IOSurfaceID>()
    var appended = 0
    try autoreleasepool {
      let renderer = try RecordingLUTRenderer(snapshot: snapshot(cube: cubeText(transform: { 1 - $0 }), colour: .rec709Video))
      weakRenderer = renderer
      let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
      let movie = folder.appendingPathComponent("many.mov")
      let config = try configuration(source: source, movie: movie, profile: .proRes422HQ, burnIn: renderer)
      let ids = Inspected()
      var seen = Set<IOSurfaceID>()
      let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { session, image, pts, duration in
        if let s = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() { ids.lock.withLock { _ = seen.insert(IOSurfaceGetID(s)) } }
        var flags = VTEncodeInfoFlags()
        return VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: duration,
          frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
      })
      try writer.start()
      try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
      let frame = try v210Frame()
      for index in 0..<120 {
        let outcome = try writer.appendVideoOutcome(sample(frame, index: index))
        if outcome == .appended { appended += 1 }
      }
      try writer.finish()
      surfaces = ids.lock.withLock { seen }
      XCTAssertEqual(writer.telemetry.gpuConvertedFrames, 120)
      XCTAssertEqual(writer.telemetry.encodedVideo, 120)
      XCTAssertEqual(writer.telemetry.passThroughFrames, 0)
    }
    XCTAssertEqual(appended, 120, "Every frame, none dropped")
    XCTAssertLessThanOrEqual(surfaces.count, AVAssetSourceRecordingWriter.encoderPoolThreshold,
      "The LUT pass writes into the encoder pool's own recycled buffers")
    XCTAssertNil(weakRenderer, "The take's LUTProcessor is released when the take's writer is")
  }

  /// HEVC Main: an 8-bit 4:2:0 camera through the LUT straight into the
  /// encoder's 420v pool (8-bit encode, 2×2 chroma blocks).
  func testBurnInIntoHEVCMain420() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("Metal 4 required") }
    let source = try declaration(pixel: .video420)
    let renderer = try RecordingLUTRenderer(snapshot: snapshot(cube: cubeText(transform: { 1 - $0 }), colour: .rec709Video))
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appendingPathComponent("hevc.mov")
    let config = try configuration(source: source, movie: movie, profile: .hevcMain, burnIn: renderer)
    let inspected = Inspected()
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { session, image, pts, duration in
      CVPixelBufferLockBaseAddress(image, .readOnly)
      let y = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
      let uv = CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt8.self)
      let middle = Self.height / 2 * CVPixelBufferGetBytesPerRowOfPlane(image, 0) + Self.width / 2
      let chromaMiddle = Self.height / 4 * CVPixelBufferGetBytesPerRowOfPlane(image, 1) + Self.width / 2
      var value = Recorded()
      value.luma = Int(y[middle])
      value.chroma = [Int(uv[chromaMiddle]), Int(uv[chromaMiddle + 1])]
      CVPixelBufferUnlockBaseAddress(image, .readOnly)
      value.format = CVPixelBufferGetPixelFormatType(image)
      inspected.lock.withLock { inspected.value = value }
      var flags = VTEncodeInfoFlags()
      return VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: duration,
        frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
    })
    try writer.start()
    try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
    XCTAssertEqual(try writer.appendVideoOutcome(sample(nv12Frame(luma: 71))), .appended)
    try writer.finish()
    let burned = inspected.lock.withLock { inspected.value }
    XCTAssertEqual(burned.format, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    // 8-bit video range: 71 is (71 − 16) / 219, so 1 − x encodes as 180.
    XCTAssertEqual(Double(burned.luma), 180, accuracy: 1)
    XCTAssertEqual(Double(burned.chroma[0]), 128, accuracy: 1)
    XCTAssertEqual(Double(burned.chroma[1]), 128, accuracy: 1)
    XCTAssertEqual(writer.telemetry.gpuConvertedFrames, 1)
    XCTAssertEqual(writer.telemetry.encodedVideo, 1)
  }

  /// Neutral grey 420v: every luma `luma`, every chroma 128.
  private func nv12Frame(luma: UInt8) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, Self.width, Self.height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(image, [])
    for plane in 0..<2 {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane)).assumingMemoryBound(to: UInt8.self)
      let bytes = CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane)
      base.update(repeating: plane == 0 ? luma : 128, count: bytes)
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    return image
  }

  // MARK: Take start snapshot

  /// What a take starting now burns in: the camera's burn-in LUT with its
  /// contract and colour settings while Apply LUT and processing are on, nil
  /// otherwise; a snapshot already taken keeps its LUT when the camera's changes.
  func testSnapshotFollowsTheCamerasBurnInAndKeepsItsLUT() throws {
    let services = CaptureServices(start: { _, _, _, _ in }, stop: {}, connect: { _, _ in }, disconnect: {},
      send: { _ in true })
    let controller = CaptureController(services: services)
    defer { controller.onUpdate = nil; controller.stop() }
    let started = expectation(description: "Capture start completed")
    started.assertForOverFulfill = false
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { started.fulfill() } }
    var off = PipelineConfiguration(applyLUT: false, downscale: false, convertTo420: false)
    off.sourceDuration = VideoContract.fastDuration
    let hlg = Colorimetry(primaries: .rec2020, transfer: .hlg, matrix: .rec2020, range: .video,
      horizontalChromaSiting: .left, verticalChromaSiting: .center)
    off.sourceColorimetryOverride = hlg
    off.lutOutputColorimetry = .rec709Video
    var on = off
    on.applyLUT = true
    controller.start(feedID: FeedID(rawValue: "snapshot"), deviceID: "synthetic", configuration: off)
    wait(for: [started], timeout: 5)
    XCTAssertNil(controller.recordingLUTSnapshot, "Nothing loaded: the take records clean")
    let first = try LUTProcessor.makeLUT(CubeLUT(text: cubeText(transform: { 1 - $0 })))
    let contract = LUTColorSpaceContract(input: hlg, output: .rec709Video)
    func load(_ lut: MonitorLUT) {
      let loaded = expectation(description: "LUT loaded")
      controller.load(lut, colorSpace: contract) { result in
        if case .failure(let error) = result { XCTFail(error.localizedDescription) }
        loaded.fulfill()
      }
      wait(for: [loaded], timeout: 5)
    }
    func settle(_ label: String, _ condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(5)
      while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
      XCTAssertTrue(condition(), label)
    }
    load(first)
    XCTAssertNil(controller.recordingLUTSnapshot, "Loaded with Apply LUT off: the take records clean")
    controller.reconfigure(configuration: on, pipelineEnabled: true)
    settle("Apply LUT on: the take burns the loaded LUT in") { controller.recordingLUTSnapshot != nil }
    let snapshot = try XCTUnwrap(controller.recordingLUTSnapshot)
    XCTAssertTrue(snapshot.lut === first)
    XCTAssertEqual(snapshot.colorSpace, contract)
    XCTAssertEqual(snapshot.sourceColorimetryOverride, hlg)
    XCTAssertEqual(snapshot.lutOutputColorimetry, .rec709Video)
    controller.reconfigure(configuration: off, pipelineEnabled: true)
    settle("Apply LUT off: a new take records clean") { controller.recordingLUTSnapshot == nil }
    controller.reconfigure(configuration: on, pipelineEnabled: false)
    settle("Complete bypass: a new take records clean") { controller.recordingLUTSnapshot == nil }
    controller.reconfigure(configuration: on, pipelineEnabled: true)
    settle("Back on") { controller.recordingLUTSnapshot?.lut === first }
    load(try LUTProcessor.makeLUT(CubeLUT(text: cubeText())))
    XCTAssertFalse(controller.recordingLUTSnapshot?.lut === first, "The next take gets the new LUT")
    XCTAssertTrue(snapshot.lut === first, "The rolling take keeps the LUT it started with")
  }

  /// The camera's own colour interpretation (colour space, ICC, gamma, log
  /// curve, HDR metadata, the app's colour label) never reaches the encoder on
  /// a graded frame, where it would contradict the LUT output's tags. The
  /// clean take keeps it, as before.
  func testBurnedInFrameDropsTheCamerasColourInterpretation() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("Metal 4 required") }
    let source = try declaration()
    let interpretation: [CFString] = [kCVImageBufferGammaLevelKey, kCVImageBufferLogTransferFunctionKey,
      kCVImageBufferICCProfileKey, kCVImageBufferAmbientViewingEnvironmentKey,
      LUTProcessor.declaredColorimetryAttachmentKey]
    func tagged() throws -> CVPixelBuffer {
      let frame = try v210Frame()
      LUTProcessor.stampDeclaredColorimetry(.rec709Video, on: frame)
      CVBufferSetAttachment(frame, kCVImageBufferGammaLevelKey, NSNumber(value: 2.4), .shouldPropagate)
      CVBufferSetAttachment(frame, kCVImageBufferLogTransferFunctionKey, kCVImageBufferLogTransferFunction_AppleLog, .shouldPropagate)
      CVBufferSetAttachment(frame, kCVImageBufferICCProfileKey, Data([0, 1, 2, 3]) as CFData, .shouldPropagate)
      CVBufferSetAttachment(frame, kCVImageBufferAmbientViewingEnvironmentKey, Data(repeating: 1, count: 8) as CFData, .shouldPropagate)
      for key in interpretation { XCTAssertNotNil(CVBufferCopyAttachment(frame, key, nil), "\(key)") }
      return frame
    }
    func handed(_ burnIn: (any RecordingLUTBurnIn)?) throws -> Set<String> {
      let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
      let movie = folder.appendingPathComponent("tags.mov")
      let config = try configuration(source: source, movie: movie, profile: .proRes422HQ, burnIn: burnIn)
      let seen = Handed()
      var keys = Set<String>()
      let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { session, image, pts, duration in
        let present = interpretation.filter { CVBufferCopyAttachment(image, $0, nil) != nil }.map { $0 as String }
        seen.lock.withLock { keys = Set(present) }
        var flags = VTEncodeInfoFlags()
        return VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: duration,
          frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
      })
      try writer.start()
      try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
      XCTAssertEqual(try writer.appendVideoOutcome(sample(tagged())), .appended)
      try writer.finish()
      return seen.lock.withLock { keys }
    }
    let renderer = try RecordingLUTRenderer(snapshot: snapshot(cube: cubeText(transform: { 1 - $0 }), colour: .rec709Video))
    XCTAssertEqual(try handed(renderer), [], "Only the LUT output's tags describe the graded frame")
    XCTAssertTrue(try handed(nil).isSuperset(of: [kCVImageBufferGammaLevelKey as String,
      kCVImageBufferLogTransferFunctionKey as String]), "The clean take keeps the camera's tags")
  }

  /// Through the recorder: the first frame that fails to burn in fails the
  /// take, and the frames after it are not handed to the encoder clean.
  func testFailedBurnInFailsTheTakeInTheRecorder() throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let source = try declaration()
    let movie = folder.appendingPathComponent("failed-recorder.mov")
    let config = try configuration(source: source, movie: movie, profile: .proRes422HQ, burnIn: FailingBurnIn(),
      policy: RecordingCompatibilityPolicy(allowCPUConversion: true))
    let handed = Handed()
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { session, image, pts, duration in
      handed.lock.withLock { handed.count += 1 }
      var flags = VTEncodeInfoFlags()
      return VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: duration,
        frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
    })
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    try recorder.start()
    try recorder.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
    let frame = try v210Frame()
    for index in 0..<3 { _ = recorder.appendVideo(try sample(frame, index: index)) }
    try? recorder.stop()
    XCTAssertEqual(recorder.state, .failed)
    XCTAssertEqual(recorder.telemetry.appendedVideo, 0)
    XCTAssertEqual(handed.lock.withLock { handed.count }, 0, "No clean frame reached the encoder")
    XCTAssertTrue(recorder.telemetry.lastError?.contains("burning the LUT") == true, recorder.telemetry.lastError ?? "")
  }

  // MARK: Fixtures

  private struct Recorded {
    var luma = 0
    var chroma: [Int] = []
    var format: OSType = 0
    var size: [Int] = []
    var chromaLocation: String?
    var primaries: String?
    var transfer: String?
    var matrix: String?
    var gpuFrames: UInt64 = 0
    var passThroughFrames: UInt64 = 0
    var compatibilityFrames: UInt64 = 0
    var encoded: UInt64 = 0
    var sidecar: RecordingTakeSidecar.Snapshot!
  }

  private final class Inspected: @unchecked Sendable {
    let lock = NSLock()
    var value = Recorded()
  }

  private final class Handed: @unchecked Sendable {
    let lock = NSLock()
    var count = 0
  }

  private final class FailingBurnIn: RecordingLUTBurnIn, @unchecked Sendable {
    let lutName = "Failing"
    let lutFileName: String? = nil
    let lutInputColour = Colorimetry.rec709Video
    let lutOutputColour = Colorimetry.rec709Video
    let outputColour = Colorimetry.rec709Video
    func refusal(sourcePixelFormat: OSType, encoderPixelFormat: OSType) -> String? { nil }
    func render(_ source: CVPixelBuffer, sourceColour: Colorimetry?, into destination: CVPixelBuffer) throws -> Double {
      throw VideoError.message("synthetic GPU failure")
    }
  }

  /// One v210 frame of neutral grey through the real writer and hardware ProRes
  /// encoder; reads back the buffer VideoToolbox was handed.
  private func record(source: SourceAdmissionSnapshot, burnIn: (any RecordingLUTBurnIn)?, requested: Bool? = nil) throws -> Recorded {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appendingPathComponent("burn-in.mov")
    let config = try configuration(source: source, movie: movie, profile: .proRes422HQ, burnIn: burnIn, requested: requested)
    let inspected = Inspected()
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { session, image, pts, duration in
      CVPixelBufferLockBaseAddress(image, .readOnly)
      let y = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt16.self)
      let uv = CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt16.self)
      let middle = Self.height / 2 * CVPixelBufferGetBytesPerRowOfPlane(image, 0) / 2 + Self.width / 2
      let chromaMiddle = Self.height / 2 * CVPixelBufferGetBytesPerRowOfPlane(image, 1) / 2 + Self.width / 2
      var value = Recorded()
      value.luma = Int(y[middle] >> 6)
      value.chroma = [Int(uv[chromaMiddle] >> 6), Int(uv[chromaMiddle + 1] >> 6)]
      CVPixelBufferUnlockBaseAddress(image, .readOnly)
      value.format = CVPixelBufferGetPixelFormatType(image)
      value.size = [CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)]
      func tag(_ key: CFString) -> String? { CVBufferCopyAttachment(image, key, nil) as? String }
      value.chromaLocation = tag(kCVImageBufferChromaLocationTopFieldKey)
      value.primaries = tag(kCVImageBufferColorPrimariesKey)
      value.transfer = tag(kCVImageBufferTransferFunctionKey)
      value.matrix = tag(kCVImageBufferYCbCrMatrixKey)
      inspected.lock.withLock { inspected.value = value }
      var flags = VTEncodeInfoFlags()
      return VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: duration,
        frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
    })
    try writer.start()
    try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
    XCTAssertEqual(try writer.appendVideoOutcome(sample(v210Frame())), .appended)
    try writer.finish()
    var result = inspected.lock.withLock { inspected.value }
    let telemetry = writer.telemetry
    result.gpuFrames = telemetry.gpuConvertedFrames
    result.passThroughFrames = telemetry.passThroughFrames
    result.compatibilityFrames = telemetry.systemCompatibilityFrames
    result.encoded = telemetry.encodedVideo
    result.sidecar = try RecordingTakeSidecar.readSnapshot(for: movie)
    XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
    return result
  }

  private func snapshot(cube: String, colour: Colorimetry, output: Colorimetry? = nil,
    declaredOutput: Colorimetry? = nil) throws -> RecordingLUTSnapshot {
    RecordingLUTSnapshot(lut: try LUTProcessor.makeLUT(CubeLUT(text: cube)),
      colorSpace: LUTColorSpaceContract(input: colour, output: output ?? colour),
      sourceColorimetryOverride: nil, lutOutputColorimetry: declaredOutput)
  }

  private func declaration(pixel: PixelFormatID = .v210, colour: Colorimetry = .rec709Video) throws -> SourceAdmissionSnapshot {
    try SourceAdmissionSnapshot(format: SourceFormat(width: Self.width, height: Self.height, pixel: pixel, colour: colour,
      rate: .constant(RecordingFrameRate.fps2997.frameDuration)), epochID: .init(sessionID: UUID(), epoch: 0),
      clockBindings: .init(video: .init(), audio: nil), stage: .recordingSource)
  }

  private func configuration(source: SourceAdmissionSnapshot, movie: URL, profile: RecordingProfileMatrixProfile,
    burnIn: (any RecordingLUTBurnIn)?, requested: Bool? = nil,
    policy: RecordingCompatibilityPolicy = .init()) throws -> SourceRecordingConfiguration {
    try SourceRecordingConfiguration(feedID: .init("burn-in"), outputURL: movie, width: Self.width, height: Self.height,
      videoCodec: profile.codec, videoProfile: .matrix(profile), frameRate: .fps2997,
      sourceFrameRate: source.format.rate, sourceAdmission: source, compatibilityPolicy: policy, sidecarMovieURL: movie,
      lutBurnIn: burnIn, lutBurnInRequested: requested)
  }

  /// Neutral grey: every luma 283, every chroma 512, packed as v210.
  private func v210Frame() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, Self.width, Self.height, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(image, [])
    let y = Self.neutralLuma, c: UInt32 = 512
    let group: [UInt32] = [c | y << 10 | c << 20, y | c << 10 | y << 20, c | y << 10 | c << 20, y | c << 10 | y << 20]
    let stride = CVPixelBufferGetBytesPerRow(image) / 4
    let words = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt32.self)
    for row in 0..<Self.height { for index in 0..<stride { words[row * stride + index] = group[index % 4] } }
    CVPixelBufferUnlockBaseAddress(image, [])
    return image
  }

  private func sample(_ image: CVPixelBuffer, index: Int = 0) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format), noErr)
    let duration = RecordingFrameRate.fps2997.frameDuration
    var timing = CMSampleTimingInfo(duration: duration,
      presentationTimeStamp: CMTimeMultiply(duration, multiplier: Int32(index)), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }

  private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
}

/// The setting: off by default, kept between launches, sampled per take.
@MainActor @objcMembers final class RecordingLUTBurnInSettingsChecks: XCTestCase {
  func testSettingDefaultsOffPersistsAndResets() throws {
    let name = "org.ultracam.tests.burn-in-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppSettingsStore(defaults: defaults)
    XCTAssertFalse(store.recordingBurnInLUT, "Off when never saved")
    store.recordingBurnInLUT = true
    XCTAssertTrue(AppSettingsStore(defaults: defaults).recordingBurnInLUT)
    store.recordingBurnInLUT = false
    XCTAssertFalse(AppSettingsStore(defaults: defaults).recordingBurnInLUT)
    store.recordingBurnInLUT = true
    store.resetAll()
    XCTAssertNil(defaults.object(forKey: AppSettingsStore.recordingBurnInLUTKey))
    XCTAssertFalse(AppSettingsStore(defaults: defaults).recordingBurnInLUT)
  }

  func testModelSavesTheChoiceAndEachTakeSamplesIt() {
    let model = RecordingModel()
    XCTAssertFalse(model.burnInLUT)
    XCTAssertFalse(model.configuration.burnInLUT)
    XCTAssertFalse(RecordingConfiguration().burnInLUT)
    var saves = 0
    model.onRecordingChoicesChanged = { saves += 1 }
    model.burnInLUT = true
    model.burnInLUT = true
    XCTAssertEqual(saves, 1, "A change is saved once")
    XCTAssertTrue(model.configuration.burnInLUT)
  }

  func testHelpSaysNextTakeAndCleanWithoutALUT() {
    let help = UISettingsRecordingPane.burnInLUTHelp
    XCTAssertTrue(help.contains("next take"), help)
    XCTAssertTrue(help.contains("A camera with no LUT records unchanged"), help)
  }
}
