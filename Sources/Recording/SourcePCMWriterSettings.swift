import AVFoundation
import AudioToolbox
import Foundation

extension EmbeddedAudioFormat {
  /// Fixed-track PCM settings. Integer int32 retains the existing lossless
  /// high-24-bit recording convention for paired embedded audio at any channel
  /// count. For mapped Float32 output, pass its Float32 source declaration.
  static func assetWriterSettings(format: SourceAudioFormat, outputSampleRate: Double) throws -> [String: Any] {
    guard outputSampleRate.isFinite, outputSampleRate > 0,
      format.channels <= Int(UInt32.max) else { throw ClockMappedPCMError.invalidPacket }
    let bits = format.sample == .int16 ? 16 : (format.sample == .float32 ? 32 : 24)
    var settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: outputSampleRate,
      AVNumberOfChannelsKey: format.channels, AVLinearPCMBitDepthKey: bits,
      AVLinearPCMIsFloatKey: format.sample == .float32,
      AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ]
    let layout = try sourceAudioChannelLayoutData(format)
    if !layout.isEmpty { settings[AVChannelLayoutKey] = layout }
    return settings
  }
}

/// An AudioChannelLayout value with all declared channel descriptions retained.
func sourceAudioChannelLayoutData(_ format: SourceAudioFormat) throws -> Data {
  guard format.layout.labels.isEmpty || format.layout.labels.count == format.channels else {
    throw ClockMappedPCMError.invalidPacket
  }
  let layoutTag = format.layout.layoutTag == 0 && format.channels > 2
    ? kAudioChannelLayoutTag_DiscreteInOrder | UInt32(format.channels) : format.layout.layoutTag
  guard !format.layout.labels.isEmpty || layoutTag != 0 else { return Data() }
  if format.layout.labels.isEmpty {
    let taggedChannels = Int(layoutTag & 0xffff)
    guard taggedChannels == format.channels else { throw ClockMappedPCMError.invalidPacket }
  }
  let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!
  let count = format.layout.labels.count
  let length = max(MemoryLayout<AudioChannelLayout>.size,
    offset + count * MemoryLayout<AudioChannelDescription>.stride)
  let storage = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: MemoryLayout<AudioChannelLayout>.alignment)
  defer { storage.deallocate() }
  storage.initializeMemory(as: UInt8.self, repeating: 0, count: length)
  let header = storage.assumingMemoryBound(to: AudioChannelLayout.self)
  header.pointee.mChannelLayoutTag = count > 0 ? kAudioChannelLayoutTag_UseChannelDescriptions : layoutTag
  header.pointee.mNumberChannelDescriptions = UInt32(count)
  let descriptions = storage.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
  for (index, label) in format.layout.labels.enumerated() { descriptions[index].mChannelLabel = label }
  return Data(bytes: storage, count: length)
}
