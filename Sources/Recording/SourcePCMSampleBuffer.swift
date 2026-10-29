import AudioToolbox
import CoreMedia
import Foundation

/// Wraps immutable source PCM without changing its rate, representation,
/// channel order, or clock. Core Media owns the copied bytes.
func makeSourceSample(planes: [Data], sampleFrameCount: Int, format: SourceAudioFormat,
  presentationTime: CMTime) throws -> CMSampleBuffer {
  let channelsPerPlane = format.interleaved ? format.channels : 1
  let (samples, sampleOverflow) = sampleFrameCount.multipliedReportingOverflow(by: channelsPerPlane)
  let (planeBytes, byteOverflow) = samples.multipliedReportingOverflow(by: format.sample.bytesPerSample)
  guard sampleFrameCount > 0, !sampleOverflow, !byteOverflow,
    planes.count == (format.interleaved ? 1 : format.channels),
    planes.allSatisfy({ $0.count == planeBytes }), presentationTime.isNumeric,
    presentationTime.epoch == 0, presentationTime >= .zero else { throw ClockMappedPCMError.invalidPacket }
  var flags = kAudioFormatFlagIsPacked
  if format.sample == .float32 { flags |= kAudioFormatFlagIsFloat }
  else { flags |= kAudioFormatFlagIsSignedInteger }
  if !format.interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
  var asbd = AudioStreamBasicDescription(mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: flags, mBytesPerPacket: UInt32(channelsPerPlane * format.sample.bytesPerSample),
    mFramesPerPacket: 1, mBytesPerFrame: UInt32(channelsPerPlane * format.sample.bytesPerSample),
    mChannelsPerFrame: UInt32(format.channels), mBitsPerChannel: UInt32(format.sample.bytesPerSample * 8), mReserved: 0)
  // The channel descriptions array is variable length; serialize all labels.
  let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!
  let labelCount = format.layout.labels.count
  let layoutBytes = max(MemoryLayout<AudioChannelLayout>.size,
    offset + labelCount * MemoryLayout<AudioChannelDescription>.stride)
  let layout = UnsafeMutableRawPointer.allocate(byteCount: layoutBytes, alignment: MemoryLayout<AudioChannelLayout>.alignment)
  defer { layout.deallocate() }
  layout.initializeMemory(as: UInt8.self, repeating: 0, count: layoutBytes)
  let header = layout.assumingMemoryBound(to: AudioChannelLayout.self)
  header.pointee.mChannelLayoutTag = labelCount > 0 ? kAudioChannelLayoutTag_UseChannelDescriptions : format.layout.layoutTag
  header.pointee.mNumberChannelDescriptions = UInt32(labelCount)
  let descriptions = layout.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
  for (index, label) in format.layout.labels.enumerated() { descriptions[index].mChannelLabel = label }
  var description: CMAudioFormatDescription?
  let hasLayout = labelCount > 0 || format.layout.layoutTag != 0
  let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
    layoutSize: hasLayout ? layoutBytes : 0, layout: hasLayout ? UnsafePointer(header) : nil,
    magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
  guard status == noErr, let description else { throw ClockMappedPCMError.invalidPacket }
  let (totalBytes, totalOverflow) = planeBytes.multipliedReportingOverflow(by: planes.count)
  guard !totalOverflow else { throw ClockMappedPCMError.invalidPacket }
  var block: CMBlockBuffer?
  guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
    blockLength: totalBytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
    offsetToData: 0, dataLength: totalBytes, flags: kCMBlockBufferAssureMemoryNowFlag,
    blockBufferOut: &block) == noErr, let block else { throw ClockMappedPCMError.invalidPacket }
  for (index, plane) in planes.enumerated() {
    let copy = plane.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
      offsetIntoDestination: index * planeBytes, dataLength: planeBytes) }
    guard copy == noErr else { throw ClockMappedPCMError.invalidPacket }
  }
  var sample: CMSampleBuffer?
  let creation = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
    dataBuffer: block, formatDescription: description, sampleCount: sampleFrameCount,
    presentationTimeStamp: presentationTime, packetDescriptions: nil, sampleBufferOut: &sample)
  guard creation == noErr, let sample else { throw ClockMappedPCMError.invalidPacket }
  return sample
}
