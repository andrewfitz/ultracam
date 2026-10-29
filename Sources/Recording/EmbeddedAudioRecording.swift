import Accelerate
import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Errors raised while validating an embedded source audio packet.
public enum EmbeddedAudioError: Error, Equatable {
  case invalidChannelCount
  case invalidSampleFrameCount
  case sizeOverflow
  case byteCountMismatch(expected: Int, actual: Int)
  case invalidPresentationTime
  case formatDescriptionCreationFailed(OSStatus)
  case blockBufferCreationFailed(OSStatus)
  case sampleBufferCreationFailed(OSStatus)
}

/// The current embedded-audio capture contract.
///
/// The source's 32-bit integer input is interleaved, signed, little-endian
/// PCM. The recorder stores the 24 significant high bits in packed little
/// endian samples. This preserves the source's 24-bit signal while avoiding a
/// lossy float conversion.
public enum EmbeddedAudioFormat {
  public static let sampleRate: Double = 48_000
  public static let sampleRateTimescale: Int32 = 48_000
  public static let channelCount = 2
  public static let sourceBitDepth = 32
  public static let recordingBitDepth = 24
  public static let sourceBytesPerSample = sourceBitDepth / 8
  public static let recordingBytesPerSample = recordingBitDepth / 8
  public static let recordingBytesPerFrame = channelCount * recordingBytesPerSample

  /// Settings for an AVAssetWriter audio input. The PCM input is interleaved,
  /// signed, native-endian and packed at 24 bits per channel.
  public static var assetWriterSettings: [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channelCount,
      AVLinearPCMBitDepthKey: recordingBitDepth,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }
}

/// Converts The source's interleaved signed 32-bit PCM to packed signed
/// little-endian 24-bit PCM without going through floating point.
public enum EmbeddedAudioConverter {
  /// Converts bytes containing interleaved little-endian Int32 samples.
  ///
  /// The low eight bits are discarded with an arithmetic shift. This is the
  /// exact representation conversion for a source whose 24 signal bits are
  /// left aligned in a 32-bit sample. The result has three bytes per sample,
  /// in little-endian order, and remains interleaved by channel.
  public static func convert32BitIntegerPCMTo24BitPacked(
    _ source: Data,
    channelCount: Int = EmbeddedAudioFormat.channelCount
  ) throws -> Data {
    guard channelCount > 0,
          channelCount <= Int.max / EmbeddedAudioFormat.sourceBytesPerSample else {
      throw EmbeddedAudioError.invalidChannelCount
    }
    let (bytesPerFrame, frameOverflow) = channelCount.multipliedReportingOverflow(
      by: EmbeddedAudioFormat.sourceBytesPerSample)
    guard !frameOverflow, bytesPerFrame > 0 else {
      throw EmbeddedAudioError.sizeOverflow
    }
    guard source.count % bytesPerFrame == 0 else {
      throw EmbeddedAudioError.byteCountMismatch(
        expected: source.count / bytesPerFrame * bytesPerFrame + bytesPerFrame,
        actual: source.count
      )
    }

    let sampleCount = source.count / EmbeddedAudioFormat.sourceBytesPerSample
    let (resultCount, resultOverflow) = sampleCount.multipliedReportingOverflow(
      by: EmbeddedAudioFormat.recordingBytesPerSample)
    guard !resultOverflow else { throw EmbeddedAudioError.sizeOverflow }
    var result = Data(count: resultCount)
    source.withUnsafeBytes { sourceBytes in
      result.withUnsafeMutableBytes { outputBytes in
        guard let sourceBase = sourceBytes.baseAddress,
              let outputBase = outputBytes.baseAddress else { return }
        packSignificant24Bits(from: sourceBase, to: outputBase, sampleCount: sampleCount)
      }
    }
    return result
  }

  /// Keeps the top 24 bits of each little-endian Int32: `sample >> 8`, stored
  /// as three little-endian bytes. That is exactly bytes 1...3 of each source
  /// word, so vImage's vectorized 4-to-3 byte channel drop (ARGB8888 to
  /// RGB888 drops byte 0) produces the identical bytes. The host is
  /// little-endian on every supported Mac.
  static func packSignificant24Bits(from source: UnsafeRawPointer, to destination: UnsafeMutableRawPointer,
    sampleCount: Int) {
    guard sampleCount > 0 else { return }
    var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1,
      width: vImagePixelCount(sampleCount), rowBytes: sampleCount * EmbeddedAudioFormat.sourceBytesPerSample)
    var output = vImage_Buffer(data: destination, height: 1, width: vImagePixelCount(sampleCount),
      rowBytes: sampleCount * EmbeddedAudioFormat.recordingBytesPerSample)
    let status = vImageConvert_ARGB8888toRGB888(&input, &output, vImage_Flags(kvImageDoNotTile))
    guard status == kvImageNoError else {
      // vImage only fails on malformed buffers; keep the exact scalar path.
      for index in 0..<sampleCount {
        let raw = source.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
        let packed = UInt32(bitPattern: Int32(bitPattern: UInt32(littleEndian: raw)) >> 8)
        destination.storeBytes(of: UInt8(truncatingIfNeeded: packed), toByteOffset: index * 3, as: UInt8.self)
        destination.storeBytes(of: UInt8(truncatingIfNeeded: packed >> 8), toByteOffset: index * 3 + 1, as: UInt8.self)
        destination.storeBytes(of: UInt8(truncatingIfNeeded: packed >> 16), toByteOffset: index * 3 + 2, as: UInt8.self)
      }
      return
    }
  }

  /// Converts an array of host-endian Int32 samples. The host is expected to
  /// be little-endian on supported macOS targets; this overload is intended
  /// for tests and code that already decoded the source packet.
  public static func convert32BitIntegerSamplesTo24BitPacked(
    _ source: [Int32]
  ) -> Data {
    var result = Data(count: source.count * EmbeddedAudioFormat.recordingBytesPerSample)
    source.withUnsafeBytes { sourceBytes in
      result.withUnsafeMutableBytes { outputBytes in
        guard let sourceBase = sourceBytes.baseAddress,
          let outputBase = outputBytes.baseAddress else { return }
        packSignificant24Bits(from: sourceBase, to: outputBase, sampleCount: source.count)
      }
    }
    return result
  }
}

/// A packet ready for an AVAssetWriter input.
public struct EmbeddedAudioPacket {
  public let pcm24: Data
  public let sampleFrameCount: Int
  public let presentationTime: CMTime

  public init(
    sourcePCM32: Data,
    sampleFrameCount: Int,
    presentationTime: CMTime,
    channelCount: Int = EmbeddedAudioFormat.channelCount
  ) throws {
    guard sampleFrameCount > 0 else { throw EmbeddedAudioError.invalidSampleFrameCount }
    guard channelCount == EmbeddedAudioFormat.channelCount else {
      throw EmbeddedAudioError.invalidChannelCount
    }
    guard presentationTime.isNumeric,
          presentationTime.timescale == EmbeddedAudioFormat.sampleRateTimescale,
          presentationTime.epoch == 0,
          presentationTime.value >= 0 else {
      throw EmbeddedAudioError.invalidPresentationTime
    }
    let (channelBytes, channelOverflow) = sampleFrameCount.multipliedReportingOverflow(by: channelCount)
    guard !channelOverflow else { throw EmbeddedAudioError.sizeOverflow }
    let (expectedBytes, byteOverflow) = channelBytes.multipliedReportingOverflow(
      by: EmbeddedAudioFormat.sourceBytesPerSample)
    guard !byteOverflow else { throw EmbeddedAudioError.sizeOverflow }
    guard sourcePCM32.count == expectedBytes else {
      throw EmbeddedAudioError.byteCountMismatch(expected: expectedBytes, actual: sourcePCM32.count)
    }
    self.pcm24 = try EmbeddedAudioConverter.convert32BitIntegerPCMTo24BitPacked(
      sourcePCM32, channelCount: channelCount)
    self.sampleFrameCount = sampleFrameCount
    self.presentationTime = presentationTime
  }

  public var duration: CMTime {
    CMTime(value: Int64(sampleFrameCount), timescale: EmbeddedAudioFormat.sampleRateTimescale)
  }
}

/// Generates exact sample-frame presentation times. Keeping the running
/// position as an integer at 48 kHz prevents the cumulative rounding drift
/// that results from repeatedly adding Double durations.
public struct EmbeddedAudioTimeline {
  public private(set) var emittedSampleFrames: Int64 = 0

  public init() {}

  public mutating func reset() {
    emittedSampleFrames = 0
  }

  public mutating func nextPacketTiming(sampleFrameCount: Int) throws -> (presentationTime: CMTime, duration: CMTime) {
    guard sampleFrameCount > 0 else { throw EmbeddedAudioError.invalidSampleFrameCount }
    let presentationTime = CMTime(value: emittedSampleFrames,
      timescale: EmbeddedAudioFormat.sampleRateTimescale)
    let duration = CMTime(value: Int64(sampleFrameCount),
      timescale: EmbeddedAudioFormat.sampleRateTimescale)
    let (nextOffset, overflow) = emittedSampleFrames.addingReportingOverflow(Int64(sampleFrameCount))
    guard !overflow else { throw EmbeddedAudioError.sizeOverflow }
    emittedSampleFrames = nextOffset
    return (presentationTime, duration)
  }

  public static func time(forSampleFrameOffset offset: Int64) -> CMTime {
    CMTime(value: offset, timescale: EmbeddedAudioFormat.sampleRateTimescale)
  }
}

/// AVFoundation glue for direct embedded audio recording.
public enum EmbeddedAudioRecording {
  public static func makeWriterInput() -> AVAssetWriterInput {
    AVAssetWriterInput(mediaType: .audio, outputSettings: EmbeddedAudioFormat.assetWriterSettings)
  }

  /// Builds a ready CMSampleBuffer from a converted packet. The sample buffer
  /// retains the packet's exact PTS and uses one 48 kHz duration per frame.
  public static func makeSampleBuffer(for packet: EmbeddedAudioPacket) throws -> CMSampleBuffer {
    try makeSampleBuffer(sampleFrameCount: packet.sampleFrameCount,
      presentationTime: packet.presentationTime) { destination in
      packet.pcm24.withUnsafeBytes { source in
        guard let source = source.baseAddress else { return }
        destination.copyMemory(from: source, byteCount: packet.pcm24.count)
      }
    }
  }

  /// Builds a sample buffer directly from The source's 32-bit integer PCM.
  ///
  /// The SDK packet has already been copied into `sourcePCM32` by the native
  /// callback boundary.  Convert the significant 24 bits straight into the
  /// Core Media block buffer so the normal recording path does not allocate a
  /// temporary packed-24 `Data` object and then copy it a second time.  This
  /// preserves the exact integer conversion used by ``EmbeddedAudioPacket``
  /// while reducing peak packet memory and callback work.
  public static func makeSampleBuffer(sourcePCM32: Data, sampleFrameCount: Int,
    presentationTime: CMTime,
    channelCount: Int = EmbeddedAudioFormat.channelCount) throws -> CMSampleBuffer {
    guard sampleFrameCount > 0 else { throw EmbeddedAudioError.invalidSampleFrameCount }
    guard channelCount == EmbeddedAudioFormat.channelCount else {
      throw EmbeddedAudioError.invalidChannelCount
    }
    guard presentationTime.isNumeric,
      presentationTime.timescale == EmbeddedAudioFormat.sampleRateTimescale,
      presentationTime.epoch == 0,
      presentationTime.value >= 0 else {
      throw EmbeddedAudioError.invalidPresentationTime
    }
    let sourceBytesPerFrame = channelCount * EmbeddedAudioFormat.sourceBytesPerSample
    let recordingBytesPerFrame = channelCount * EmbeddedAudioFormat.recordingBytesPerSample
    guard sampleFrameCount <= Int.max / sourceBytesPerFrame,
      sampleFrameCount <= Int.max / recordingBytesPerFrame else {
      throw EmbeddedAudioError.invalidSampleFrameCount
    }
    let expectedBytes = sampleFrameCount * sourceBytesPerFrame
    guard sourcePCM32.count == expectedBytes else {
      throw EmbeddedAudioError.byteCountMismatch(expected: expectedBytes, actual: sourcePCM32.count)
    }
    return try makeSampleBuffer(sampleFrameCount: sampleFrameCount,
      presentationTime: presentationTime) { destination in
      sourcePCM32.withUnsafeBytes { sourceBytes in
        guard let sourceBase = sourceBytes.baseAddress else { return }
        EmbeddedAudioConverter.packSignificant24Bits(from: sourceBase, to: destination,
          sampleCount: sampleFrameCount * channelCount)
      }
    }
  }

  /// Builds a sample buffer from the frames of a source packet after its
  /// first `skippingFrames`, which overlapped audio already recorded. With a
  /// `continuation` (the interleaved 32-bit frames the recorded audio would
  /// have continued with), the first kept frames are crossfaded in from it,
  /// sample by sample, so the cut has no step. The conversion writes straight
  /// into the Core Media block; nothing is copied beyond it.
  static func makeSampleBuffer(sourcePCM32: Data, skippingFrames: Int, sampleFrameCount: Int,
    presentationTime: CMTime, channelCount: Int = EmbeddedAudioFormat.channelCount,
    crossfadingFrom continuation: UnsafeBufferPointer<Int32>?) throws -> CMSampleBuffer {
    guard sampleFrameCount > 0, skippingFrames >= 0 else { throw EmbeddedAudioError.invalidSampleFrameCount }
    guard channelCount == EmbeddedAudioFormat.channelCount else {
      throw EmbeddedAudioError.invalidChannelCount
    }
    guard presentationTime.isNumeric,
      presentationTime.timescale == EmbeddedAudioFormat.sampleRateTimescale,
      presentationTime.epoch == 0,
      presentationTime.value >= 0 else {
      throw EmbeddedAudioError.invalidPresentationTime
    }
    let sourceBytesPerFrame = channelCount * EmbeddedAudioFormat.sourceBytesPerSample
    let (frames, overflow) = skippingFrames.addingReportingOverflow(sampleFrameCount)
    guard !overflow, frames <= Int.max / sourceBytesPerFrame else {
      throw EmbeddedAudioError.invalidSampleFrameCount
    }
    guard sourcePCM32.count == frames * sourceBytesPerFrame else {
      throw EmbeddedAudioError.byteCountMismatch(expected: frames * sourceBytesPerFrame, actual: sourcePCM32.count)
    }
    return try makeSampleBuffer(sampleFrameCount: sampleFrameCount,
      presentationTime: presentationTime) { destination in
      sourcePCM32.withUnsafeBytes { sourceBytes in
        guard let base = sourceBytes.baseAddress else { return }
        let kept = base + skippingFrames * sourceBytesPerFrame
        EmbeddedAudioConverter.packSignificant24Bits(from: kept, to: destination,
          sampleCount: sampleFrameCount * channelCount)
        guard let continuation, !continuation.isEmpty else { return }
        let fadeFrames = min(continuation.count / channelCount, sampleFrameCount)
        for frame in 0..<fadeFrames {
          // Rises from just above 0 to just below 1: the first frame is
          // almost all continuation, the frame after the fade all kept audio.
          let weight = Double(frame + 1) / Double(fadeFrames + 1)
          for channel in 0..<channelCount {
            let index = frame * channelCount + channel
            let from = Double(continuation[index])
            let to = Double(kept.loadUnaligned(fromByteOffset: index * 4, as: Int32.self))
            let mixed = Int32(clamping: Int64((from + (to - from) * weight).rounded()))
            let packed = UInt32(bitPattern: mixed >> 8)
            destination.storeBytes(of: UInt8(truncatingIfNeeded: packed), toByteOffset: index * 3, as: UInt8.self)
            destination.storeBytes(of: UInt8(truncatingIfNeeded: packed >> 8), toByteOffset: index * 3 + 1, as: UInt8.self)
            destination.storeBytes(of: UInt8(truncatingIfNeeded: packed >> 16), toByteOffset: index * 3 + 2, as: UInt8.self)
          }
        }
      }
    }
  }

  /// Digital silence on the embedded-audio contract: fills a hole in a take's
  /// audio so the audio after it stays on its frames.
  static func makeSilenceSampleBuffer(sampleFrameCount: Int, presentationTime: CMTime) throws -> CMSampleBuffer {
    guard sampleFrameCount > 0 else { throw EmbeddedAudioError.invalidSampleFrameCount }
    guard presentationTime.isNumeric,
      presentationTime.timescale == EmbeddedAudioFormat.sampleRateTimescale,
      presentationTime.epoch == 0,
      presentationTime.value >= 0 else {
      throw EmbeddedAudioError.invalidPresentationTime
    }
    return try makeSampleBuffer(sampleFrameCount: sampleFrameCount, presentationTime: presentationTime) {
      $0.initializeMemory(as: UInt8.self, repeating: 0,
        count: sampleFrameCount * EmbeddedAudioFormat.recordingBytesPerFrame)
    }
  }

  /// Builds the shared format description now, so the first packet on the
  /// capture thread does not pay for Core Audio's first-use setup.
  public static func prepareFormat() { _ = cachedFormat }

  private struct CachedFormat: @unchecked Sendable {
    let result: Result<CMAudioFormatDescription, EmbeddedAudioError>
  }

  /// The embedded-audio format never changes, so one description serves
  /// every packet. CMFormatDescription is immutable and thread-safe.
  private static let cachedFormat: CachedFormat = {
    var streamDescription = AudioStreamBasicDescription(
      mSampleRate: EmbeddedAudioFormat.sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(EmbeddedAudioFormat.recordingBytesPerFrame),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(EmbeddedAudioFormat.recordingBytesPerFrame),
      mChannelsPerFrame: UInt32(EmbeddedAudioFormat.channelCount),
      mBitsPerChannel: UInt32(EmbeddedAudioFormat.recordingBitDepth),
      mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &streamDescription,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
      return CachedFormat(result: .failure(.formatDescriptionCreationFailed(status)))
    }
    return CachedFormat(result: .success(formatDescription))
  }()

  private static func makeSampleBuffer(sampleFrameCount: Int,
    presentationTime: CMTime,
    fill: (UnsafeMutableRawPointer) -> Void) throws -> CMSampleBuffer {
    let formatDescription = try cachedFormat.result.get()
    var status: OSStatus
    var blockBuffer: CMBlockBuffer?
    // Allocate storage owned by CoreMedia. Passing Data's pointer directly
    // would leave a sample buffer referring to storage that can be released as
    // soon as this method returns.
    let outputBytes = sampleFrameCount * EmbeddedAudioFormat.recordingBytesPerFrame
    status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: outputBytes,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: outputBytes,
      // Force the block allocator to materialize backing storage now. With
      // flags == 0 Core Media may leave the block unallocated until a later
      // replace/copy operation, and CMBlockBufferGetDataPointer then returns
      // kCMBlockBufferUnallocatedBlockErr (-12707).
      flags: kCMBlockBufferAssureMemoryNowFlag,
      blockBufferOut: &blockBuffer
    )
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
      throw EmbeddedAudioError.blockBufferCreationFailed(status)
    }
    var lengthAtOffset = 0
    var totalLength = 0
    var destination: UnsafeMutablePointer<CChar>?
    status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
      lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength,
      dataPointerOut: &destination)
    guard status == kCMBlockBufferNoErr, let destination,
      lengthAtOffset >= outputBytes, totalLength >= outputBytes else {
      throw EmbeddedAudioError.blockBufferCreationFailed(status)
    }
    fill(UnsafeMutableRawPointer(destination))

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: EmbeddedAudioFormat.sampleRateTimescale),
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid
    )
    var sampleSize = EmbeddedAudioFormat.recordingBytesPerFrame
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: sampleFrameCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
      throw EmbeddedAudioError.sampleBufferCreationFailed(status)
    }
    return sampleBuffer
  }
}
