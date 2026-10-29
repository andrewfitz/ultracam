import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Audio-only bridge: copies PCM bytes into converter storage and publishes a
/// fixed-grid interleaved Float32 CMSampleBuffer retaining the source layout.
struct ClockMappedPCMBridge {
  private var converter: ClockMappedPCMConverter
  private var outputDescription: CMAudioFormatDescription?
  let format: SourceAudioFormat
  let outputSampleRate: Double
  private(set) var convertedFrames: UInt64 = 0
  private(set) var discontinuities: UInt64 = 0
  private(set) var correctionRatio: Double = 1

  init(format: SourceAudioFormat, outputSampleRate: Double,
    maximumDriftPPM: Double = 2_000, maximumSlewPPM: Double = 100,
    maximumAVErrorSeconds: Double = 0.02, maximumWorkspaceBytes: Int = 64 * 1024 * 1024) throws {
    self.format = format; self.outputSampleRate = outputSampleRate
    converter = try ClockMappedPCMConverter(format: format, outputSampleRate: outputSampleRate,
      maximumDriftPPM: maximumDriftPPM, maximumSlewPPM: maximumSlewPPM,
      maximumAVErrorSeconds: maximumAVErrorSeconds, maximumWorkspaceBytes: maximumWorkspaceBytes)
  }

  mutating func convert(_ sample: CMSampleBuffer, mapping: AudioVideoClockMapping) throws -> CMSampleBuffer? {
    try convert(sample, mapping: .mapped(mapping))
  }
  mutating func resume(audioTime: CMTime, mapping: AudioVideoClockMapping) throws {
    try resume(audioTime: audioTime, mapping: .mapped(mapping))
  }

  mutating func convert(_ sample: CMSampleBuffer, mapping: PCMClockTransform) throws -> CMSampleBuffer? {
    do {
      let count = CMSampleBufferGetNumSamples(sample)
      guard count > 0, count <= Int(Int32.max) else { throw ClockMappedPCMError.invalidPacket }
      guard let description = CMSampleBufferGetFormatDescription(sample),
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
        asbd.mFormatID == kAudioFormatLinearPCM,
        asbd.mSampleRate == format.sampleRate, Int(asbd.mChannelsPerFrame) == format.channels,
        asbd.mBitsPerChannel == (format.sample == .int16 ? 16 : 32) ||
          (format.sample == .int24in32 && asbd.mBitsPerChannel == 24),
        (asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0) == (format.sample == .float32),
        (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0) == format.interleaved,
        asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
        asbd.mBytesPerFrame == UInt32((format.interleaved ? format.channels : 1) * format.sample.bytesPerSample) else {
        throw ClockMappedPCMError.invalidPacket
      }
      try converter.preflight(sampleFrameCount: count, mapping: mapping)
      let bufferCount = format.interleaved ? 1 : format.channels
      let listBytes = MemoryLayout<AudioBufferList>.size + (bufferCount - 1) * MemoryLayout<AudioBuffer>.stride
      let storage = UnsafeMutableRawPointer.allocate(byteCount: listBytes, alignment: MemoryLayout<AudioBufferList>.alignment)
      defer { storage.deallocate() }
      let list = storage.assumingMemoryBound(to: AudioBufferList.self)
      var retained: CMBlockBuffer?
      let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
        bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listBytes,
        blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0, blockBufferOut: &retained)
      guard status == noErr else { throw ClockMappedPCMError.invalidPacket }
      let planes = UnsafeMutableAudioBufferListPointer(list).map { audio -> Data in
        guard let data = audio.mData else { return Data() }
        return Data(bytes: data, count: Int(audio.mDataByteSize))
      }
      if outputDescription == nil { outputDescription = try makeDescription(source: description) }
      let chunk = try converter.convert(planes: planes, sampleFrameCount: count,
        audioTime: CMSampleBufferGetPresentationTimeStamp(sample), mapping: mapping)
      correctionRatio = chunk.correctionRatio
      convertedFrames += UInt64(chunk.sampleFrameCount)
      return try makeSample(chunk)
    } catch {
      discontinuities += 1
      throw error
    }
  }

  mutating func finish() throws -> CMSampleBuffer? {
    guard let chunk = converter.finish() else { return nil }
    convertedFrames += UInt64(chunk.sampleFrameCount)
    return try makeSample(chunk)
  }

  mutating func resume(audioTime: CMTime, mapping: PCMClockTransform) throws {
    try converter.resume(audioTime: audioTime, mapping: mapping)
  }

  private func makeDescription(source: CMAudioFormatDescription) throws -> CMAudioFormatDescription {
    var asbd = AudioStreamBasicDescription(mSampleRate: outputSampleRate,
      mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(format.channels * 4), mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(format.channels * 4), mChannelsPerFrame: UInt32(format.channels),
      mBitsPerChannel: 32, mReserved: 0)
    var layoutSize = 0
    let layout = CMAudioFormatDescriptionGetChannelLayout(source, sizeOut: &layoutSize)
    var description: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
      layoutSize: layoutSize, layout: layout, magicCookieSize: 0, magicCookie: nil,
      extensions: nil, formatDescriptionOut: &description)
    guard status == noErr, let description else { throw ClockMappedPCMError.invalidPacket }
    return description
  }

  private func makeSample(_ chunk: ClockMappedPCMChunk) throws -> CMSampleBuffer? {
    guard chunk.sampleFrameCount > 0 else { return nil }
    guard let outputDescription else { throw ClockMappedPCMError.invalidPacket }
    var block: CMBlockBuffer?
    let allocation = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
      memoryBlock: nil, blockLength: chunk.samples.count, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: chunk.samples.count,
      flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    guard allocation == noErr, let block else { throw ClockMappedPCMError.invalidPacket }
    let copy = chunk.samples.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
        offsetIntoDestination: 0, dataLength: raw.count)
    }
    guard copy == noErr else { throw ClockMappedPCMError.invalidPacket }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(outputSampleRate)),
      presentationTimeStamp: chunk.presentationTime, decodeTimeStamp: .invalid)
    var size = format.channels * 4
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
      formatDescription: outputDescription, sampleCount: chunk.sampleFrameCount,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
      sampleSizeArray: &size, sampleBufferOut: &sample)
    guard status == noErr, let sample else { throw ClockMappedPCMError.invalidPacket }
    return sample
  }
}
