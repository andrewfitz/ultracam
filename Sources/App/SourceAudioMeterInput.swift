import Foundation
import AudioToolbox
import MonitorKitAudio

/// PCM interpretation shared by metering and source-level analysis. Work is
/// performed away from the source delivery callback. Int24 is right justified
/// and sign extended in its 32-bit container, as in the source contract.
enum SourceAudioMeterInput {
  static func interleavedSamples(_ packet: CaptureAudioPacket) -> [Float] {
    let format = packet.format
    var result = [Float](repeating: 0, count: packet.sampleFrameCount * format.channels)
    for channel in 0..<format.channels {
      let plane = packet.planes[format.interleaved ? 0 : channel]
      plane.withUnsafeBytes { raw in
        for frame in 0..<packet.sampleFrameCount {
          let index = format.interleaved ? frame * format.channels + channel : frame
          let offset = index * format.sample.bytesPerSample
          let value: Float
          switch format.sample {
          case .int16:
            value = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32_768
          case .int24in32:
            value = Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int32.self))) / 8_388_608
          case .int32:
            value = Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int32.self))) / 2_147_483_648
          case .float32:
            value = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
          }
          result[frame * format.channels + channel] = value.isFinite ? value : 0
        }
      }
    }
    return result
  }

  /// Auto switching follows the strongest channel so speech outside the first
  /// stereo pair remains audible to its activity detector.
  static func activity(peaks: [Double], rms: [Double]) -> (peak: Float, rms: Float) {
    let peak = peaks.filter { $0.isFinite }.max() ?? 0
    let level = rms.filter { $0.isFinite }.max() ?? 0
    return (Float(max(0, peak)), Float(max(0, level)))
  }
}

// Channel positions are an admission decision on the control queue. Never infer
// a surround order from channel count; unlabelled embedded audio is a programme
// pair, while explicit discrete channels contribute equal energy to the programme.
extension SourceAudioMeterInput {
  static func loudnessChannels(for format: SourceAudioFormat) throws -> [LoudnessChannel] {
    let labels: [UInt32]
    if !format.layout.labels.isEmpty {
      labels = format.layout.labels
    } else if format.layout.layoutTag == 0 {
      return LoudnessChannel.programmePair(channelCount: format.channels)
    } else {
      var tag = format.layout.layoutTag
      var size: UInt32 = 0
      guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag,
        UInt32(MemoryLayout.size(ofValue: tag)), &tag, &size) == noErr,
        size >= MemoryLayout<AudioChannelLayout>.size, size <= 64 * 1024 else {
        throw AudioMeterError.invalidParameter("Unsupported source channel layout tag")
      }
      var storage = Data(count: Int(size))
      labels = try storage.withUnsafeMutableBytes { raw in
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag,
          UInt32(MemoryLayout.size(ofValue: tag)), &tag, &size, raw.baseAddress!) == noErr else {
          throw AudioMeterError.invalidParameter("Unsupported source channel layout tag")
        }
        let layout = raw.loadUnaligned(as: AudioChannelLayout.self)
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let count = Int(layout.mNumberChannelDescriptions)
        guard count == format.channels,
          offset + count * MemoryLayout<AudioChannelDescription>.stride <= Int(size) else {
          throw AudioMeterError.invalidParameter("Source channel layout does not match its channel count")
        }
        return (0..<count).map {
          raw.loadUnaligned(fromByteOffset: offset + $0 * MemoryLayout<AudioChannelDescription>.stride,
            as: AudioChannelDescription.self).mChannelLabel
        }
      }
    }
    guard labels.count == format.channels else {
      throw AudioMeterError.invalidParameter("Source channel label count differs from its channel count")
    }
    return try labels.map { label in
      switch label {
      case kAudioChannelLabel_Left: return .left
      case kAudioChannelLabel_Right: return .right
      case kAudioChannelLabel_Center, kAudioChannelLabel_Mono: return .center
      case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2, kAudioChannelLabel_LFE3: return .lfe
      case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect,
           kAudioChannelLabel_LeftSideSurround: return .leftSurround
      case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect,
           kAudioChannelLabel_RightSideSurround: return .rightSurround
      case kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
           kAudioChannelLabel_LeftBackSurround, kAudioChannelLabel_RightBackSurround: return .weighted(1)
      case kAudioChannelLabel_Unused: return .excluded
      case kAudioChannelLabel_Discrete: return .weighted(1)
      case kAudioChannelLabel_Discrete_0...kAudioChannelLabel_Discrete_65535: return .weighted(1)
      default: throw AudioMeterError.invalidParameter("Unsupported source channel label \(label)")
      }
    }
  }
}
