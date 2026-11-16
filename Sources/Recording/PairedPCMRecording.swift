import AudioToolbox
import CoreMedia
import Foundation

/// The paired embedded path preserves high-24-bit Int32 PCM exactly for every
/// declared channel. It needs no fabricated clock mapping or Float conversion.
func makePaired24BitSample(sourcePCM32: Data, sampleFrameCount: Int,
  format: SourceAudioFormat, presentationTime: CMTime) throws -> CMSampleBuffer {
  guard format.clock == .pairedWithFrames, format.sample == .int32,
    format.interleaved, format.sampleRate == 48000, sampleFrameCount > 0,
    presentationTime.isNumeric, presentationTime.epoch == 0 else { throw ClockMappedPCMError.invalidPacket }
  let (sampleCount, overflow) = sampleFrameCount.multipliedReportingOverflow(by: format.channels)
  let (byteCount, byteOverflow) = sampleCount.multipliedReportingOverflow(by: 4)
  guard !overflow, !byteOverflow, sourcePCM32.count == byteCount else { throw ClockMappedPCMError.invalidPacket }
  let (packedBytes, packedOverflow) = sampleCount.multipliedReportingOverflow(by: 3)
  guard !packedOverflow else { throw ClockMappedPCMError.invalidPacket }
  var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    mBytesPerPacket: UInt32(format.channels * 3), mFramesPerPacket: 1,
    mBytesPerFrame: UInt32(format.channels * 3), mChannelsPerFrame: UInt32(format.channels),
    mBitsPerChannel: 24, mReserved: 0)
  let layout = try sourceAudioChannelLayoutData(format)
  var description: CMAudioFormatDescription?
  let status = layout.withUnsafeBytes { raw in
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
      layoutSize: raw.count, layout: raw.baseAddress?.assumingMemoryBound(to: AudioChannelLayout.self),
      magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
  }
  guard status == noErr, let description else { throw ClockMappedPCMError.invalidPacket }
  var block: CMBlockBuffer?
  guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
    blockLength: packedBytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
    offsetToData: 0, dataLength: packedBytes, flags: kCMBlockBufferAssureMemoryNowFlag,
    blockBufferOut: &block) == noErr, let block else { throw ClockMappedPCMError.invalidPacket }
  var length = 0
  var totalLength = 0
  var destination: UnsafeMutablePointer<CChar>?
  let pointerStatus = CMBlockBufferGetDataPointer(block, atOffset: 0,
    lengthAtOffsetOut: &length, totalLengthOut: &totalLength, dataPointerOut: &destination)
  guard pointerStatus == noErr, let destination,
    length >= packedBytes, totalLength >= packedBytes else { throw ClockMappedPCMError.invalidPacket }
  sourcePCM32.withUnsafeBytes { raw in
    EmbeddedAudioConverter.packSignificant24Bits(from: raw.baseAddress!,
      to: UnsafeMutableRawPointer(destination), sampleCount: sampleCount)
  }
  var sample: CMSampleBuffer?
  let creation = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
    dataBuffer: block, formatDescription: description, sampleCount: sampleFrameCount,
    presentationTimeStamp: presentationTime, packetDescriptions: nil, sampleBufferOut: &sample)
  guard creation == noErr, let sample else { throw ClockMappedPCMError.invalidPacket }
  return sample
}
