import AVFoundation
import Metal
import VideoToolbox
import XCTest

@objcMembers final class RecordingNDIWriterChecks: XCTestCase {
  func testActualI420WriterMOVHasExpectedPixelsColourAndOriginalSourceIdentity() async throws {
    try await exercise(pixel: .i420, profile: .hevcMain)
  }
  func testActualPA16WriterMOVIgnoresAlphaAndKeepsOriginalSourceIdentity() async throws {
    try await exercise(pixel: .pa16, profile: .proRes422HQ)
  }
  func testActualP216WriterMOVHasExpectedQuantizedPixelsAndSourceIdentity() async throws {
    try await exercise(pixel: .p216, profile: .proRes422HQ)
  }

  private func exercise(pixel: PixelFormatID, profile: RecordingProfileMatrixProfile) async throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 required") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let movie = directory.appendingPathComponent("ndi.mov")
    let format = try SourceFormat(width: 320, height: 64, pixel: pixel, colour: .rec709Video,
      rate: .constant(RecordingFrameRate.fps2997.frameDuration))
    let source = try SourceAdmissionSnapshot(format: format, epochID: .init(sessionID: UUID(), epoch: 0),
      clockBindings: .init(video: .init(), audio: nil), stage: .recordingSource)
    let configuration = try SourceRecordingConfiguration(feedID: .init("ndi-writer"), outputURL: movie,
      width: 320, height: 64, videoCodec: profile.codec, videoProfile: .matrix(profile), frameRate: .fps2997,
      sourceFrameRate: format.rate, sourceAdmission: source, sidecarMovieURL: movie)
    let seen = NDIWriterEncoderInputs()
    let writer = try AVAssetSourceRecordingWriter(configuration: configuration, encodeFrame: { session, image, pts, duration in
      seen.lock.lock(); seen.formats.append(CVPixelBufferGetPixelFormatType(image)); seen.lock.unlock()
      var flags = VTEncodeInfoFlags()
      return VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts,
        duration: duration, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
    })
    let original = try fixture(pixel: pixel)
    let originalFourCC = CVPixelBufferGetPixelFormatType(original)
    try writer.start()
    try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
    XCTAssertEqual(try writer.appendVideoOutcome(sample(original)), .appended)
    try writer.finish()
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(original), originalFourCC)
    XCTAssertEqual(originalFourCC, pixel.rawValue)
    XCTAssertEqual(writer.telemetry.encodedVideo, 1)
    XCTAssertEqual(writer.telemetry.gpuConvertedFrames, 1)
    XCTAssertEqual(writer.telemetry.systemCompatibilityFrames, 0)
    let encoderFormats = seen.lock.withLock { seen.formats }
    XCTAssertEqual(encoderFormats, [profile.encoderPixelFormat])
    let sidecar = try RecordingTakeSidecar.readSnapshot(for: movie).metadata
    XCTAssertEqual(sidecar.sourceFormat, format)
    XCTAssertEqual(sidecar.sourceSignature, format.signature)
    XCTAssertEqual(sidecar.sourceFormat?.pixel, pixel)
    XCTAssertEqual(sidecar.outputContract?.outputColour.range, .video)
    XCTAssertEqual(sidecar.outputContract?.outputColour.primaries, .rec709)
    XCTAssertEqual(sidecar.outputContract?.outputColour.transfer, .rec709)
    XCTAssertEqual(sidecar.outputContract?.outputColour.matrix, .rec709)
    if pixel == .pa16 { XCTAssertTrue(sidecar.conversionNotes.contains { $0.lowercased().contains("alpha") }) }

    let asset = AVURLAsset(url: movie)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let descriptions = try await track.load(.formatDescriptions)
    let description = try XCTUnwrap(descriptions.first)
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), profile.codec)
    XCTAssertEqual(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
      kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
    XCTAssertEqual(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
      kCVImageBufferTransferFunction_ITU_R_709_2 as String)
    XCTAssertEqual(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    XCTAssertNotEqual(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool, true)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    XCTAssertTrue(reader.canAdd(output)); reader.add(output)
    XCTAssertTrue(reader.startReading())
    let decodedSample = try XCTUnwrap(output.copyNextSampleBuffer())
    let decoded = try XCTUnwrap(CMSampleBufferGetImageBuffer(decodedSample))
    CVPixelBufferLockBaseAddress(decoded, .readOnly)
    let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(decoded)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(decoded)
    for (block, expected) in [0, 56, 128, 205, 255].enumerated() {
      let offset = 32 * stride + (block * 64 + 32) * 4
      for component in 0..<3 { XCTAssertEqual(Int(bytes[offset + component]), expected, accuracy: 3, "\(pixel.rawValue) MOV block \(block) RGB component \(component)") }
    }
    CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
    XCTAssertNil(output.copyNextSampleBuffer())
    XCTAssertEqual(reader.status, .completed)
  }

  private func fixture(pixel: PixelFormatID) throws -> CVPixelBuffer {
    try CPUMemoryPixelFormatRegistration.ensure(pixel.rawValue)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 320, 64, pixel.rawValue,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
       kCVPixelBufferBytesPerRowAlignmentKey: 256] as CFDictionary, &image), kCVReturnSuccess)
    let buffer = try XCTUnwrap(image)
    XCTAssertEqual(CVPixelBufferGetPlaneCount(buffer), pixel == .p216 ? 2 : 3)
    try VideoBufferLayout.validate(buffer)
    CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane), rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
      memset(base, 0xA5, stride * rows)
      let components = pixel == .i420 || plane != 1 ? 1 : 2
      let width = CVPixelBufferGetWidthOfPlane(buffer, plane) * components
      for row in 0..<rows { for x in 0..<width {
        let value: UInt16 = plane == 0 ? [16, 64, 126, 192, 235][x / 64] : 128
        if pixel == .i420 { base.storeBytes(of: UInt8(value), toByteOffset: row * stride + x, as: UInt8.self) }
        else { base.storeBytes(of: plane == 2 ? (x.isMultiple(of: 2) ? UInt16(0) : UInt16.max) : value * 256,
          toByteOffset: row * stride + x * 2, as: UInt16.self) }
      } }
    }
    return buffer
  }
  private func sample(_ image: CVPixelBuffer) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: RecordingFrameRate.fps2997.frameDuration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let description = try XCTUnwrap(format)
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: description,
      sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }
}

private final class NDIWriterEncoderInputs: @unchecked Sendable {
  let lock = NSLock()
  var formats: [OSType] = []
}
