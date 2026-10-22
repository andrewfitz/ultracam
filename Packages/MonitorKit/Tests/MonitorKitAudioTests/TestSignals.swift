import Foundation
import MonitorKitAudio
import XCTest

/// Planar test signals in Double, converted to Float32 only when fed.
struct Signal {
  var sampleRate: Double
  var channels: [[Float]]

  init(sampleRate: Double, channels: [[Float]]) {
    self.sampleRate = sampleRate
    self.channels = channels
  }

  init(sampleRate: Double, channelCount: Int, frames: Int = 0) {
    self.init(sampleRate: sampleRate, channels: Array(repeating: Array(repeating: 0, count: frames), count: channelCount))
  }

  var frameCount: Int { channels.first?.count ?? 0 }

  static func amplitude(_ dBFS: Double) -> Double { pow(10, dBFS / 20) }

  /// A sine with its peak at `dBFS`, starting at `phase` degrees.
  static func sine(
    frequency: Double, dBFS: Double, seconds: Double, sampleRate: Double, phaseDegrees: Double = 0
  ) -> [Float] {
    let n = Int((seconds * sampleRate).rounded())
    let a = amplitude(dBFS)
    let w = 2 * Double.pi * frequency / sampleRate
    let p = phaseDegrees * Double.pi / 180
    return (0..<n).map { Float(a * sin(w * Double($0) + p)) }
  }

  /// The same sine on every channel (EBU "applied in phase to both channels").
  static func tone(
    frequency: Double = 1000, dBFS: Double, seconds: Double, sampleRate: Double, channels: Int = 2
  ) -> Signal {
    let s = sine(frequency: frequency, dBFS: dBFS, seconds: seconds, sampleRate: sampleRate)
    return Signal(sampleRate: sampleRate, channels: Array(repeating: s, count: channels))
  }

  static func silence(seconds: Double, sampleRate: Double, channels: Int = 2) -> Signal {
    Signal(sampleRate: sampleRate, channelCount: channels, frames: Int((seconds * sampleRate).rounded()))
  }

  /// Concatenation, keeping the 1 kHz phase continuous so segment joins add no clicks.
  static func toneSequence(
    _ segments: [(dBFS: Double?, seconds: Double)], frequency: Double = 1000, sampleRate: Double, channels: Int = 2
  ) -> Signal {
    var samples: [Float] = []
    var n = 0
    let w = 2 * Double.pi * frequency / sampleRate
    for segment in segments {
      let count = Int((segment.seconds * sampleRate).rounded())
      let a = segment.dBFS.map(amplitude) ?? 0
      samples.reserveCapacity(samples.count + count)
      for _ in 0..<count {
        samples.append(Float(a * sin(w * Double(n))))
        n += 1
      }
    }
    return Signal(sampleRate: sampleRate, channels: Array(repeating: samples, count: channels))
  }

  /// Deterministic white noise in [-amplitude, amplitude].
  static func noise(amplitude: Double, frames: Int, seed: UInt64) -> [Float] {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    return (0..<frames).map { _ in
      state = state &* 6364136223846793005 &+ 1442695040888963407
      let u = Double(state >> 11) / Double(1 << 53)
      return Float(amplitude * (2 * u - 1))
    }
  }

  func appending(_ other: Signal) -> Signal {
    Signal(sampleRate: sampleRate, channels: zip(channels, other.channels).map { $0 + $1 })
  }

  var interleaved: [Float] {
    var out = [Float](repeating: 0, count: frameCount * channels.count)
    for c in channels.indices {
      for i in 0..<frameCount { out[i * channels.count + c] = channels[c][i] }
    }
    return out
  }
}

/// Per-channel buffers a test copies each block into before calling `process`.
final class PlanarBlock {
  let channelCount: Int
  let capacity: Int
  let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

  init(channelCount: Int, capacity: Int) {
    self.channelCount = channelCount
    self.capacity = capacity
    pointers = .allocate(capacity: channelCount)
    for c in 0..<channelCount {
      let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
      p.initialize(repeating: 0, count: capacity)
      (pointers + c).initialize(to: p)
    }
  }

  deinit {
    for c in 0..<channelCount { pointers[c].deallocate() }
    pointers.deallocate()
  }

  func fill(from signal: Signal, offset: Int, count: Int) {
    for c in 0..<channelCount {
      signal.channels[c].withUnsafeBufferPointer { src in
        pointers[c].update(from: src.baseAddress! + offset, count: count)
      }
    }
  }
}

extension AudioMeter {
  /// Feeds planar Float32 in blocks of `blockSize`, calling `each` after every block.
  func feed(_ signal: Signal, blockSize: Int = 512, each: ((AudioMeterSnapshot) -> Void)? = nil) {
    let block = PlanarBlock(channelCount: signal.channels.count, capacity: blockSize)
    var offset = 0
    while offset < signal.frameCount {
      let n = min(blockSize, signal.frameCount - offset)
      block.fill(from: signal, offset: offset, count: n)
      process(planar: block.pointers, frameCount: n)
      offset += n
      if let each { each(snapshot()) }
    }
  }
}

extension LoudnessMeter {
  func feed(_ signal: Signal, blockSize: Int = 512, each: ((LoudnessSnapshot) -> Void)? = nil) {
    let block = PlanarBlock(channelCount: signal.channels.count, capacity: blockSize)
    var offset = 0
    while offset < signal.frameCount {
      let n = min(blockSize, signal.frameCount - offset)
      block.fill(from: signal, offset: offset, count: n)
      process(planar: block.pointers, frameCount: n)
      offset += n
      if let each { each(snapshot()) }
    }
  }
}

func dB(_ linear: Double) -> Double { 20 * log10(linear) }
