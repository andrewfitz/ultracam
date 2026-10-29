import AVFoundation
import VideoToolbox
import Metal
import XCTest

@objcMembers final class RecordingPackedWriterChecks: XCTestCase {
  func testOutputContractDescribesDerivedColourAndSeparatesSourceProvenance() throws {
    let sourceColour = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .identity,
      range: .video, horizontalChromaSiting: .unspecified, verticalChromaSiting: .unspecified)
    let rgb = try SourceFormat(width: 320, height: 64, pixel: .r210, colour: sourceColour,
      rate: .constant(RecordingFrameRate.fps2997.frameDuration))
    let output = RecordingOutputContract(sourceFormat: rgb, encoderInputPixelFormat: kCVPixelFormatType_64RGBALE,
      codec: kCMVideoCodecType_AppleProRes4444)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any])
    let colour = json["outputColour"] as? [String: Any]
    XCTAssertEqual(colour?["range"] as? String, "full")
    XCTAssertEqual(colour?["matrix"] as? String, "identity")
    let a = try SourceFormat(width: 320, height: 64, pixel: .twoVuy, rate: .constant(RecordingFrameRate.fps2997.frameDuration))
    let b = try SourceFormat(width: 320, height: 64, pixel: .yuvs, rate: .constant(RecordingFrameRate.fps2997.frameDuration))
    XCTAssertNotEqual(a.signature, b.signature)
    XCTAssertEqual(RecordingOutputContract(sourceFormat: a, encoderInputPixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, codec: kCMVideoCodecType_AppleProRes422HQ).signature,
      RecordingOutputContract(sourceFormat: b, encoderInputPixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, codec: kCMVideoCodecType_AppleProRes422HQ).signature)
  }

  func testActualWriterEncodesBothPackedOrdersOnGPU() throws {
    for pixel in [PixelFormatID.twoVuy, .yuvs] {
      let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
      let source = try source(pixel: pixel)
      let movie = folder.appendingPathComponent("packed.mov")
      let config = try configuration(source: source, movie: movie)
      let seen = PackedWriterInputs()
      let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { session, image, pts, duration in
        seen.lock.lock(); seen.formats.append(CVPixelBufferGetPixelFormatType(image)); seen.lock.unlock()
        var flags = VTEncodeInfoFlags()
        return VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: duration,
          frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
      })
      try writer.start()
      try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
      XCTAssertEqual(try writer.appendVideoOutcome(sample(pixel: pixel)), .appended)
      try writer.finish()
      seen.lock.lock(); let formats = seen.formats; seen.lock.unlock()
      XCTAssertEqual(formats, [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange])
      XCTAssertEqual(writer.telemetry.gpuConvertedFrames, 1)
      XCTAssertEqual(writer.telemetry.systemCompatibilityFrames, 0)
      XCTAssertEqual(writer.telemetry.encodedVideo, 1)
      XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
    }
  }

  func testActualWriterEncodesRawUYVAAndRetainsSourceDescription() throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let declaration = try source(pixel: .uyva)
    let movie = folder.appendingPathComponent("uyva.mov")
    let writer = try AVAssetSourceRecordingWriter(configuration: configuration(source: declaration, movie: movie))
    try writer.start()
    try writer.bindTakeContext(.init(sourceAdmission: declaration, audioDeclaration: .absent))
    let rowBytes = 320 * 2 + 32, alphaRowBytes = 320 + 16
    var bytes = [UInt8](repeating: 255, count: (rowBytes + alphaRowBytes) * 64)
    for row in 0..<64 { for pair in 0..<160 {
      let offset = row * rowBytes + pair * 4
      for (c, value) in [UInt8(128), 64, 128, 235].enumerated() { bytes[offset + c] = value }
    } }
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let input = try XCTUnwrap(device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared))
    XCTAssertEqual(try writer.appendUYVAVideo(input, owner: input, width: 320, height: 64, rowBytes: rowBytes,
      alphaRowBytes: alphaRowBytes, presentationTime: .zero, duration: RecordingFrameRate.fps2997.frameDuration), .appended)
    try writer.finish()
    XCTAssertEqual(writer.telemetry.encodedVideo, 1)
    XCTAssertEqual(writer.telemetry.gpuConvertedFrames, 1)
    XCTAssertEqual(writer.telemetry.systemCompatibilityFrames, 0)
    let metadata = try RecordingTakeSidecar.readSnapshot(for: movie)
    XCTAssertEqual(metadata.metadata.sourceFormat?.pixel, .uyva)
    XCTAssertEqual(metadata.metadata.outputContract?.outputColour.range, .video)
    XCTAssertTrue(metadata.metadata.conversionNotes.contains { $0.contains("alpha") })
    XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
  }

  func testActualRangeConvertedWritersRecordOutputColourAndKeepSourceColour() throws {
    for rgb in [true, false] {
      let sourceColour = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: rgb ? .identity : .rec709,
        range: rgb ? .video : .full, horizontalChromaSiting: rgb ? .unspecified : .left,
        verticalChromaSiting: rgb ? .unspecified : .center)
      let declaration = try source(pixel: rgb ? .r210 : .full420, colour: sourceColour)
      let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
      let movie = folder.appendingPathComponent("range.mov")
      let profile: RecordingProfileMatrixProfile = rgb ? .proRes4444 : .hevcMain
      let seen = PackedWriterInputs()
      let writer = try AVAssetSourceRecordingWriter(configuration: configuration(source: declaration, movie: movie, profile: profile),
        encodeFrame: { session, image, pts, duration in
          let full = (CVBufferCopyAttachment(image, kCMFormatDescriptionExtension_FullRangeVideo, nil) as? NSNumber)?.boolValue
          seen.lock.lock(); seen.fullRanges.append(full); seen.lock.unlock()
          var flags = VTEncodeInfoFlags()
          return VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: duration,
            frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
        })
      try writer.start()
      try writer.bindTakeContext(.init(sourceAdmission: declaration, audioDeclaration: .absent))
      XCTAssertEqual(try writer.appendVideoOutcome(sample(pixel: declaration.format.pixel)), .appended)
      try writer.finish()
      let metadata = try RecordingTakeSidecar.readSnapshot(for: movie)
      XCTAssertEqual(metadata.metadata.sourceFormat?.colour, sourceColour)
      XCTAssertEqual(metadata.metadata.sourceSignature, declaration.formatSignature)
      XCTAssertEqual(metadata.metadata.outputContract?.outputColour.range, rgb ? .full : .video)
      XCTAssertEqual(metadata.metadata.outputContract?.outputColour.primaries, .rec709)
      seen.lock.lock(); let ranges = seen.fullRanges; seen.lock.unlock()
      XCTAssertEqual(ranges, [rgb])
      XCTAssertEqual(writer.telemetry.encodedVideo, 1)
      XCTAssertEqual(writer.telemetry.systemCompatibilityFrames, 0)
    }
  }

  private func source(pixel: PixelFormatID, colour: Colorimetry = .rec709Video) throws -> SourceAdmissionSnapshot {
    try SourceAdmissionSnapshot(format: SourceFormat(width: 320, height: 64, pixel: pixel, colour: colour,
      rate: .constant(RecordingFrameRate.fps2997.frameDuration)), epochID: .init(sessionID: UUID(), epoch: 0),
      clockBindings: .init(video: .init(), audio: nil), stage: .recordingSource)
  }
  private func configuration(source: SourceAdmissionSnapshot, movie: URL, profile: RecordingProfileMatrixProfile = .proRes422HQ) throws -> SourceRecordingConfiguration {
    try SourceRecordingConfiguration(feedID: .init("packed-writer"), outputURL: movie, width: 320, height: 64,
      videoCodec: profile.codec, videoProfile: .matrix(profile), frameRate: .fps2997,
      sourceFrameRate: source.format.rate, sourceAdmission: source, sidecarMovieURL: movie)
  }
  private func sample(pixel: PixelFormatID) throws -> CMSampleBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 320, 64, pixel.rawValue, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(image, [])
    if CVPixelBufferIsPlanar(image) {
      for plane in 0..<CVPixelBufferGetPlaneCount(image) {
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
        for row in 0..<CVPixelBufferGetHeightOfPlane(image, plane) {
          for byte in 0..<stride { base[row * stride + byte] = plane == 0 ? UInt8(byte % 256) : 128 }
        }
      }
    } else {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(image)
      if pixel == .r210 {
        for row in 0..<64 { for x in 0..<320 {
          let code: UInt32 = x < 160 ? 64 : 940
          let word = code << 20 | code << 10 | code
          for c in 0..<4 { base[row * stride + x * 4 + c] = UInt8(truncatingIfNeeded: word >> (24 - c * 8)) }
        } }
      } else {
        for row in 0..<64 { for pair in 0..<160 {
          let offset = row * stride + pair * 4
          let codes: [UInt8] = pixel == .twoVuy ? [128, 64, 128, 235] : [64, 128, 235, 128]
          for c in 0..<4 { base[offset + c] = codes[c] }
        } }
      }
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: RecordingFrameRate.fps2997.frameDuration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }
  private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder
  }
}
private final class PackedWriterInputs: @unchecked Sendable {
  let lock = NSLock()
  var formats: [OSType] = []
  var fullRanges: [Bool?] = []
}
