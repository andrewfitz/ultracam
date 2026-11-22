import CoreMedia
import Foundation

struct ClockMappedPCMChunk {
  let samples: Data // interleaved Float32, native endian
  let presentationTime: CMTime
  let sampleFrameCount: Int
  let channels: Int
  let correctionRatio: Double
}

enum ClockMappedPCMError: Error, Equatable {
  case invalidPacket, nonFiniteSample, driftLimit, slewLimit, discontinuity, workspaceLimit
}

/// Streaming PCM conversion onto a fixed video-clock sample grid. Linear
/// interpolation retains the preceding frame and fractional source phase,
/// including across callback boundaries. Bounds fail before state advances.
struct ClockMappedPCMConverter {
  let format: SourceAudioFormat
  let outputSampleRate: Double
  let maximumDriftPPM: Double
  let maximumSlewPPM: Double
  let maximumAVErrorSeconds: Double
  let maximumWorkspaceBytes: Int
  private let selectedChannels: Range<Int>
  private var pending: [Float] = []
  private var phase = 0.0
  private var outputOrigin: CMTime?
  private var emitted: Int64 = 0
  private var expectedAudioTime: CMTime?
  private var expectedVideoTime: CMTime?
  private var previousRatio: Double?
  private var finished = false

  mutating func resume(audioTime: CMTime, mapping: AudioVideoClockMapping) throws {
    try resume(audioTime: audioTime, mapping: .mapped(mapping))
  }
  mutating func convert(planes: [Data], sampleFrameCount: Int, audioTime: CMTime,
    mapping: AudioVideoClockMapping) throws -> ClockMappedPCMChunk {
    try convert(planes: planes, sampleFrameCount: sampleFrameCount, audioTime: audioTime, mapping: .mapped(mapping))
  }
  @discardableResult
  func preflight(sampleFrameCount: Int, mapping: AudioVideoClockMapping) throws -> Int {
    try preflight(sampleFrameCount: sampleFrameCount, mapping: .mapped(mapping))
  }

  /// Moves the source-clock origin across an intentional pause. The output
  /// keeps that gap; the writer removes it once using its shared A/V pause
  /// offset. Fractional interpolation phase and frame counters are preserved.
  mutating func resume(audioTime: CMTime, mapping: PCMClockTransform) throws {
    guard !finished else { throw ClockMappedPCMError.invalidPacket }
    let videoTime = try mapping.videoTime(forAudioTime: audioTime)
    if let expectedVideoTime, let origin = outputOrigin {
      outputOrigin = CMTimeAdd(origin, CMTimeSubtract(videoTime, expectedVideoTime))
    }
    expectedAudioTime = audioTime
    expectedVideoTime = videoTime
  }

  /// A microphone gap leaves video and the movie origin intact. Reanchor
  /// the audio grid at the returning packet without mixing two segments.
  mutating func restartSegment(audioTime: CMTime, mapping: PCMClockTransform) throws {
    guard !finished else { throw ClockMappedPCMError.invalidPacket }
    let videoTime = try mapping.videoTime(forAudioTime: audioTime)
    if let expectedAudioTime, CMTimeSubtract(expectedAudioTime, audioTime).seconds > 1 / format.sampleRate {
      throw ClockMappedPCMError.discontinuity
    }
    if let origin = outputOrigin,
      videoTime < CMTimeAdd(origin, CMTime(value: emitted, timescale: Int32(outputSampleRate))) {
      throw ClockMappedPCMError.discontinuity
    }
    pending.removeAll(keepingCapacity: true)
    phase = 0
    outputOrigin = videoTime
    emitted = 0
    expectedAudioTime = audioTime
    expectedVideoTime = videoTime
  }

  /// Drains the final interpolation interval by extending the last sample.
  /// Repeated drains return nil; a drained stream cannot accept more packets.
  mutating func finish() -> ClockMappedPCMChunk? {
    guard !finished else { return nil }
    finished = true
    guard let origin = outputOrigin, let ratio = previousRatio, !pending.isEmpty else { return nil }
    let step = format.sampleRate / (outputSampleRate * ratio)
    let channels = selectedChannels.count
    let frameCount = pending.count / channels
    var output = [Float]()
    while phase < Double(frameCount) {
      let index = min(Int(phase), frameCount - 1)
      let next = min(index + 1, frameCount - 1)
      let fraction = Float(phase - Double(index))
      for channel in 0..<channels {
        let first = Double(pending[index * channels + channel])
        let second = Double(pending[next * channels + channel])
        output.append(Float(first + (second - first) * Double(fraction)))
      }
      phase += step
    }
    let start = CMTimeAdd(origin, CMTime(value: emitted, timescale: Int32(outputSampleRate)))
    let count = output.count / channels
    pending.removeAll(); emitted += Int64(count)
    guard count > 0 else { return nil }
    return ClockMappedPCMChunk(samples: output.withUnsafeBytes { Data($0) }, presentationTime: start,
      sampleFrameCount: count, channels: channels, correctionRatio: ratio)
  }

  /// An explicit selection limits sample decoding and output to consecutive
  /// source channels. Packet layout and byte sizes still describe the source.
  init(format: SourceAudioFormat, outputSampleRate: Double, selectedChannels: Range<Int>? = nil,
    maximumDriftPPM: Double = 2_000, maximumSlewPPM: Double = 100,
    maximumAVErrorSeconds: Double = 0.02, maximumWorkspaceBytes: Int = 64 * 1024 * 1024) throws {
    let selection = selectedChannels ?? 0..<format.channels
    guard selection.lowerBound >= 0, selection.upperBound <= format.channels, !selection.isEmpty,
      outputSampleRate.isFinite, outputSampleRate > 0, outputSampleRate <= Double(Int32.max),
      outputSampleRate.rounded() == outputSampleRate,
      maximumDriftPPM.isFinite, maximumDriftPPM >= 0,
      maximumSlewPPM.isFinite, maximumSlewPPM >= 0,
      maximumAVErrorSeconds.isFinite, maximumAVErrorSeconds >= 0, maximumWorkspaceBytes > 0 else {
      throw ClockMappedPCMError.invalidPacket
    }
    self.format = format; self.outputSampleRate = outputSampleRate
    self.maximumDriftPPM = maximumDriftPPM; self.maximumSlewPPM = maximumSlewPPM
    self.maximumAVErrorSeconds = maximumAVErrorSeconds
    self.maximumWorkspaceBytes = maximumWorkspaceBytes
    self.selectedChannels = selection
  }

  mutating func convert(planes: [Data], sampleFrameCount: Int,
    audioTime: CMTime, mapping: PCMClockTransform) throws -> ClockMappedPCMChunk {
    let ratio = mapping.audioToVideoRate
    guard ratio.isFinite, abs(ratio - 1) * 1_000_000 <= maximumDriftPPM else { throw ClockMappedPCMError.driftLimit }
    if let previousRatio, abs(ratio - previousRatio) * 1_000_000 > maximumSlewPPM { throw ClockMappedPCMError.slewLimit }
    guard !finished, sampleFrameCount > 0, audioTime.isNumeric else { throw ClockMappedPCMError.invalidPacket }
    let videoTime = try mapping.videoTime(forAudioTime: audioTime)
    if let expectedAudioTime {
      guard abs(CMTimeSubtract(audioTime, expectedAudioTime).seconds) <= maximumAVErrorSeconds else {
        throw ClockMappedPCMError.discontinuity
      }
    }
    if let outputOrigin {
      let gridTime = CMTimeAdd(outputOrigin, CMTime(value: emitted, timescale: Int32(outputSampleRate)))
      // One retained interpolation frame may trail the packet boundary.
      guard abs(CMTimeSubtract(videoTime, gridTime).seconds) <= maximumAVErrorSeconds + 2 / format.sampleRate else {
        throw ClockMappedPCMError.discontinuity
      }
    }
    let outputCapacity = try preflight(sampleFrameCount: sampleFrameCount, mapping: mapping)
    let nextAudioTime = CMTimeAdd(audioTime, CMTime(seconds: Double(sampleFrameCount) / format.sampleRate,
      preferredTimescale: 1_000_000_000))
    let nextVideoTime = try mapping.videoTime(forAudioTime: nextAudioTime)
    let frames = try decode(planes, frames: sampleFrameCount)
    let channels = selectedChannels.count
    let frameCount = frames.count / channels
    var cursor = phase
    let step = format.sampleRate / (outputSampleRate * ratio)
    var output = [Float]()
    output.reserveCapacity(outputCapacity * channels)
    while cursor + 1 < Double(frameCount) {
      let index = Int(cursor), fraction = Float(cursor - Double(index))
      for channel in 0..<channels {
        let first = Double(frames[index * channels + channel])
        let second = Double(frames[(index + 1) * channels + channel])
        output.append(Float(first + (second - first) * Double(fraction)))
      }
      cursor += step
    }
    let consumed = cursor >= Double(frameCount) ? frameCount : Int(cursor)
    let start = CMTimeAdd(outputOrigin ?? videoTime,
      CMTime(value: emitted, timescale: Int32(outputSampleRate)))
    // Copy only the remaining interpolation frame; retaining the combined
    // array capacity would keep an entire large packet alive between calls.
    pending = Array(frames[(consumed * channels)...]); phase = cursor - Double(consumed)
    outputOrigin = outputOrigin ?? videoTime
    previousRatio = ratio
    let count = output.count / channels
    emitted += Int64(count)
    expectedAudioTime = nextAudioTime
    expectedVideoTime = nextVideoTime
    return ClockMappedPCMChunk(samples: output.withUnsafeBytes { Data($0) }, presentationTime: start,
      sampleFrameCount: count, channels: channels, correctionRatio: ratio)
  }

  /// Checked before PCM decoding or bridge copies. Conservatively includes
  /// source bytes, old retention, decoded/combined/copied retention and both
  /// Float output plus immutable Data publication (with capacity headroom).
  @discardableResult
  func preflight(sampleFrameCount: Int, mapping: PCMClockTransform) throws -> Int {
    guard sampleFrameCount > 0 else { throw ClockMappedPCMError.invalidPacket }
    func multiply(_ a: Int, _ b: Int) throws -> Int {
      let (value, overflow) = a.multipliedReportingOverflow(by: b)
      guard !overflow else { throw ClockMappedPCMError.workspaceLimit }
      return value
    }
    func add(_ a: Int, _ b: Int) throws -> Int {
      let (value, overflow) = a.addingReportingOverflow(b)
      guard !overflow else { throw ClockMappedPCMError.workspaceLimit }
      return value
    }
    let inputSamples = try multiply(sampleFrameCount, format.channels)
    let inputBytes = try multiply(inputSamples, format.sample.bytesPerSample)
    let channels = selectedChannels.count
    let samples = try multiply(sampleFrameCount, channels)
    let allSamples = try add(samples, pending.count)
    let floatBytes = try multiply(allSamples, MemoryLayout<Float>.stride)
    let step = format.sampleRate / (outputSampleRate * mapping.audioToVideoRate)
    let bound = ceil(Double(allSamples / channels) / step) + 1
    guard step.isFinite, step > 0, bound.isFinite, bound > 0, bound < Double(Int.max) else {
      throw ClockMappedPCMError.workspaceLimit
    }
    let outputFrames = Int(bound)
    let outputBytes = try multiply(try multiply(outputFrames, channels), MemoryLayout<Float>.stride)
    let workspace = try add(inputBytes, try add(try multiply(floatBytes, 3), try multiply(outputBytes, 3)))
    guard workspace <= maximumWorkspaceBytes else { throw ClockMappedPCMError.workspaceLimit }
    return outputFrames
  }

  private func decode(_ planes: [Data], frames: Int) throws -> [Float] {
    let sourceChannels = format.channels
    let sampleType = format.sample
    let bytesPerSample = sampleType.bytesPerSample
    let (samples, overflow) = frames.multipliedReportingOverflow(by: format.interleaved ? sourceChannels : 1)
    let (bytes, byteOverflow) = samples.multipliedReportingOverflow(by: bytesPerSample)
    guard !overflow, !byteOverflow, planes.count == (format.interleaved ? 1 : format.channels),
      planes.allSatisfy({ $0.count == bytes }) else { throw ClockMappedPCMError.invalidPacket }
    // Decode directly after the retained interpolation frame and borrow each
    // used plane once.
    let prefix = pending.count
    let channels = selectedChannels.count
    var output = [Float](repeating: 0, count: prefix + frames * channels)
    output.replaceSubrange(0..<prefix, with: pending)
    if format.interleaved {
      try planes[0].withUnsafeBytes { raw in
        if channels == sourceChannels {
          for sample in 0..<samples {
            output[prefix + sample] = try Self.decodeSample(raw, at: sample * bytesPerSample, as: sampleType)
          }
        } else {
          for frame in 0..<frames {
            let source = frame * sourceChannels + selectedChannels.lowerBound
            let destination = prefix + frame * channels
            for channel in 0..<channels {
              output[destination + channel] = try Self.decodeSample(raw, at: (source + channel) * bytesPerSample, as: sampleType)
            }
          }
        }
      }
    } else {
      for (channel, plane) in selectedChannels.enumerated() {
        try planes[plane].withUnsafeBytes { raw in
          for frame in 0..<frames {
            output[prefix + frame * channels + channel] = try Self.decodeSample(raw, at: frame * bytesPerSample, as: sampleType)
          }
        }
      }
    }
    return output
  }

  private static func decodeSample(_ raw: UnsafeRawBufferPointer, at offset: Int, as sampleType: AudioSampleType) throws -> Float {
    switch sampleType {
    case .int16:
      return Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32_768
    case .int24in32:
      return Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int32.self))) / 8_388_608
    case .int32:
      return Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int32.self))) / 2_147_483_648
    case .float32:
      let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
      let value = Float(bitPattern: bits)
      guard value.isFinite else { throw ClockMappedPCMError.nonFiniteSample }
      return value
    }
  }
}
