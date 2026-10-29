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

  /// Drains the final interpolation interval by extending the last sample.
  /// Repeated drains return nil; a drained stream cannot accept more packets.
  mutating func finish() -> ClockMappedPCMChunk? {
    guard !finished else { return nil }
    finished = true
    guard let origin = outputOrigin, let ratio = previousRatio, !pending.isEmpty else { return nil }
    let step = format.sampleRate / (outputSampleRate * ratio)
    var output = [Float]()
    while phase < Double(pending.count / format.channels) {
      let index = min(Int(phase), pending.count / format.channels - 1)
      let next = min(index + 1, pending.count / format.channels - 1)
      let fraction = Float(phase - Double(index))
      for channel in 0..<format.channels {
        let first = Double(pending[index * format.channels + channel])
        let second = Double(pending[next * format.channels + channel])
        output.append(Float(first + (second - first) * Double(fraction)))
      }
      phase += step
    }
    let start = CMTimeAdd(origin, CMTime(value: emitted, timescale: Int32(outputSampleRate)))
    let count = output.count / format.channels
    pending.removeAll(); emitted += Int64(count)
    guard count > 0 else { return nil }
    return ClockMappedPCMChunk(samples: output.withUnsafeBytes { Data($0) }, presentationTime: start,
      sampleFrameCount: count, channels: format.channels, correctionRatio: ratio)
  }

  init(format: SourceAudioFormat, outputSampleRate: Double,
    maximumDriftPPM: Double = 2_000, maximumSlewPPM: Double = 100,
    maximumAVErrorSeconds: Double = 0.02, maximumWorkspaceBytes: Int = 64 * 1024 * 1024) throws {
    guard outputSampleRate.isFinite, outputSampleRate > 0, outputSampleRate <= Double(Int32.max),
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
    let decoded = try decode(planes, frames: sampleFrameCount)
    let frames = pending + decoded
    var cursor = phase
    let step = format.sampleRate / (outputSampleRate * ratio)
    var output = [Float]()
    output.reserveCapacity(outputCapacity * format.channels)
    while cursor + 1 < Double(frames.count / format.channels) {
      let index = Int(cursor), fraction = Float(cursor - Double(index))
      for channel in 0..<format.channels {
        let first = Double(frames[index * format.channels + channel])
        let second = Double(frames[(index + 1) * format.channels + channel])
        output.append(Float(first + (second - first) * Double(fraction)))
      }
      cursor += step
    }
    let frameCount = frames.count / format.channels
    let consumed = cursor >= Double(frameCount) ? frameCount : Int(cursor)
    let start = CMTimeAdd(outputOrigin ?? videoTime,
      CMTime(value: emitted, timescale: Int32(outputSampleRate)))
    // Copy only the remaining interpolation frame; retaining the combined
    // array capacity would keep an entire large packet alive between calls.
    pending = Array(frames[(consumed * format.channels)...]); phase = cursor - Double(consumed)
    outputOrigin = outputOrigin ?? videoTime
    previousRatio = ratio
    let count = output.count / format.channels
    emitted += Int64(count)
    expectedAudioTime = CMTimeAdd(audioTime, CMTime(seconds: Double(sampleFrameCount) / format.sampleRate, preferredTimescale: 1_000_000_000))
    expectedVideoTime = try mapping.videoTime(forAudioTime: expectedAudioTime!)
    return ClockMappedPCMChunk(samples: output.withUnsafeBytes { Data($0) }, presentationTime: start,
      sampleFrameCount: count, channels: format.channels, correctionRatio: ratio)
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
    let samples = try multiply(sampleFrameCount, format.channels)
    let inputBytes = try multiply(samples, format.sample.bytesPerSample)
    let allSamples = try add(samples, pending.count)
    let floatBytes = try multiply(allSamples, MemoryLayout<Float>.stride)
    let step = format.sampleRate / (outputSampleRate * mapping.audioToVideoRate)
    let bound = ceil(Double(allSamples / format.channels) / step) + 1
    guard step.isFinite, step > 0, bound.isFinite, bound > 0, bound < Double(Int.max) else {
      throw ClockMappedPCMError.workspaceLimit
    }
    let outputFrames = Int(bound)
    let outputBytes = try multiply(try multiply(outputFrames, format.channels), MemoryLayout<Float>.stride)
    let workspace = try add(inputBytes, try add(try multiply(floatBytes, 3), try multiply(outputBytes, 3)))
    guard workspace <= maximumWorkspaceBytes else { throw ClockMappedPCMError.workspaceLimit }
    return outputFrames
  }

  private func decode(_ planes: [Data], frames: Int) throws -> [Float] {
    let (samples, overflow) = frames.multipliedReportingOverflow(by: format.interleaved ? format.channels : 1)
    let (bytes, byteOverflow) = samples.multipliedReportingOverflow(by: format.sample.bytesPerSample)
    guard !overflow, !byteOverflow, planes.count == (format.interleaved ? 1 : format.channels),
      planes.allSatisfy({ $0.count == bytes }) else { throw ClockMappedPCMError.invalidPacket }
    var output = [Float]()
    output.reserveCapacity(frames * format.channels)
    for frame in 0..<frames {
      for channel in 0..<format.channels {
        let plane = planes[format.interleaved ? 0 : channel]
        let index = (format.interleaved ? frame * format.channels + channel : frame) * format.sample.bytesPerSample
        let value: Float = plane.withUnsafeBytes { raw in
          if format.sample == .int16 {
            return Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index, as: Int16.self))) / 32768
          }
          let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index, as: UInt32.self))
          switch format.sample {
          case .float32: return Float(bitPattern: bits)
          case .int24in32: return Float(Int32(bitPattern: bits)) / 8_388_608
          case .int32: return Float(Int32(bitPattern: bits)) / 2_147_483_648
          case .int16: return 0
          }
        }
        guard value.isFinite else { throw ClockMappedPCMError.nonFiniteSample }
        output.append(value)
      }
    }
    return output
  }
}
