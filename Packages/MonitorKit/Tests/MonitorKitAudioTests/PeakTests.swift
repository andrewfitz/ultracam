import AVFoundation
import MonitorKitAudio
import XCTest

final class PeakTests: XCTestCase {
  static let rates: [Double] = [44100, 48000, 96000]

  private func meter(
    _ fs: Double, channels: Int = 2, meters: AudioMeterKinds = .all,
    hold: Double = 2, decay: Double = 20 / 1.7
  ) throws -> AudioMeter {
    try AudioMeter(configuration: AudioMeterConfiguration(
      sampleRate: fs, channelCount: channels, meters: meters, peakHoldTime: hold, peakDecayRate: decay))
  }

  /// fs/48 puts sample 12 of every period exactly on the crest.
  func testSamplePeakIsExact() throws {
    for fs in Self.rates {
      let m = try meter(fs)
      let tone = Signal.sine(frequency: fs / 48, dBFS: -6, seconds: 0.5, sampleRate: fs)
      m.feed(Signal(sampleRate: fs, channels: [tone, tone.map { $0 * 0.5 }]))
      let s = m.snapshot()
      let crest = Float(Signal.amplitude(-6))
      XCTAssertEqual(s[0].samplePeak, 20 * log10(crest), accuracy: 1e-5)
      XCTAssertEqual(s[0].samplePeakHold, 20 * log10(crest), accuracy: 1e-5)
      XCTAssertEqual(s[1].samplePeakHold, 20 * log10(crest * 0.5), accuracy: 1e-5)
    }
    let noise = Signal.noise(amplitude: 0.7, frames: 30000, seed: 3)
    let m = try meter(48000, channels: 1)
    m.feed(Signal(sampleRate: 48000, channels: [noise]), blockSize: 333)
    let expected = noise.map { abs($0) }.max()!
    XCTAssertEqual(m.snapshot()[0].samplePeakHold, 20 * log10(expected), accuracy: 1e-5)
  }

  func testRMSIsExact() throws {
    for fs in Self.rates {
      for scale in [RMSScale.aes17, .unscaled] {
        let m = try AudioMeter(configuration: .init(sampleRate: fs, channelCount: 1, rmsScale: scale))
        // 1 kHz fills the 300 ms window with whole cycles at every rate.
        m.feed(Signal(sampleRate: fs, channels: [Signal.sine(frequency: 1000, dBFS: -20, seconds: 1, sampleRate: fs)]))
        let expected = scale == .aes17 ? -20 : -20 - 10 * log10(2.0)
        XCTAssertEqual(Double(m.snapshot()[0].rms), expected, accuracy: 1e-3, "\(fs) \(scale)")
      }
    }
    // Noise: the window is the last 300 ms (60 ticks of 5 ms at 48 kHz).
    let fs = 48000.0
    let noise = Signal.noise(amplitude: 0.5, frames: 48000, seed: 11)
    let m = try AudioMeter(configuration: .init(sampleRate: fs, channelCount: 1, rmsScale: .unscaled))
    m.feed(Signal(sampleRate: fs, channels: [noise]), blockSize: 700)
    let window = noise.suffix(14400).map { Double($0) * Double($0) }.reduce(0, +) / 14400
    XCTAssertEqual(Double(m.snapshot()[0].rms), 10 * log10(window), accuracy: 1e-3)
  }

  /// A stereo tone tapered with 10 ms fades, as EBU Tech 3341 cases 15-19 specify.
  private func taperedTone(fs: Double, frequency: Double, amplitude: Double, phase: Double) -> Signal {
    let n = Int(fs)
    let fade = Int(0.01 * fs)
    let w = 2 * Double.pi * frequency / fs
    let p = phase * Double.pi / 180
    let x: [Float] = (0..<n).map { i in
      let g = min(1, Double(min(i, n - 1 - i)) / Double(fade))
      return Float(g * amplitude * sin(w * Double(i) + p))
    }
    return Signal(sampleRate: fs, channels: [x, x])
  }

  static let allRates: [Double] = [32000, 44100, 48000, 88200, 96000, 176_400, 192_000, 352_800, 384_000, 768_000]

  // EBU Tech 3341 cases 15-19: expected -6.0 / +3.0 dBTP, +0.2 / -0.4 dB.
  // Tech 3341 states the tones as fractions of the meter's own rate ("fs/4
  // denotes 12 kHz for a sample-rate of 48 kHz, etc."), so every rate gets
  // its own fs/4, fs/6 and fs/8, with the filter's error included.
  func testTruePeakTech3341Cases15To19AtEveryRate() throws {
    let cases: [(divisor: Double, amplitude: Double, phase: Double)] = [
      (4, 0.5, 0), (4, 0.5, 45), (6, 0.5, 60), (8, 0.5, 67.5), (4, 1.41, 45),
    ]
    for fs in Self.allRates {
      for c in cases {
        let m = try meter(fs)
        m.feed(taperedTone(fs: fs, frequency: fs / c.divisor, amplitude: c.amplitude, phase: c.phase))
        let tp = Double(m.snapshot().maximumTruePeak)
        let expected = dB(c.amplitude)
        XCTAssertLessThanOrEqual(tp, expected + 0.2, "fs/\(c.divisor) \(c.phase) deg at \(fs)")
        XCTAssertGreaterThanOrEqual(tp, expected - 0.4, "fs/\(c.divisor) \(c.phase) deg at \(fs)")
        // At 45 degrees the samples of fs/4 sit 3 dB below its crests.
        if c.divisor == 4 && c.phase == 45 {
          XCTAssertEqual(Double(m.snapshot()[0].samplePeakHold), expected - 3.01, accuracy: 0.05, "\(fs)")
        }
      }
    }
  }

  // The same tones at their 48 kHz frequencies (12, 8 and 6 kHz) at other
  // rates: there they sample the Annex 2 filter's passband ripple at other
  // normalized frequencies, which reads up to +0.22 dB (at 48 kHz it already
  // reads +0.19 dB at 4.8 kHz).
  func testTruePeakTech3341TonesAt48kFrequencies() throws {
    let cases: [(divisor: Double, amplitude: Double, phase: Double)] = [
      (4, 0.5, 0), (4, 0.5, 45), (6, 0.5, 60), (8, 0.5, 67.5), (4, 1.41, 45),
    ]
    for fs in Self.allRates where fs >= 48000 {
      for c in cases {
        let m = try meter(fs)
        m.feed(taperedTone(fs: fs, frequency: 48000 / c.divisor, amplitude: c.amplitude, phase: c.phase))
        let tp = Double(m.snapshot().maximumTruePeak)
        let expected = dB(c.amplitude)
        XCTAssertLessThanOrEqual(tp, expected + (fs == 48000 ? 0.2 : 0.25), "fs/\(c.divisor) \(c.phase) deg at \(fs)")
        XCTAssertGreaterThanOrEqual(tp, expected - 0.4, "fs/\(c.divisor) \(c.phase) deg at \(fs)")
      }
    }
  }

  /// BS.1770-4 Annex 2: a dBTP reading needs an oversampled rate of at least
  /// 192 kHz. Every rate from 48 kHz up gets there; below, 4x is the most
  /// Annex 2 offers.
  func testTruePeakOversampledRateIsAtLeast192kHz() throws {
    for fs in Self.allRates {
      let factor = Reference.oversampling(fs)
      if fs >= 48000 {
        XCTAssertGreaterThanOrEqual(Double(factor) * fs, 192_000, "\(fs)")
      } else {
        XCTAssertEqual(factor, 4, "\(fs)")
      }
      XCTAssertGreaterThanOrEqual(factor, 2, "\(fs)")
      // The meter runs exactly this factor (the reference test pins its output to it).
      let x = Signal.sine(frequency: fs / 4, dBFS: -6, seconds: 0.05, sampleRate: fs, phaseDegrees: 45)
      let m = try meter(fs, channels: 1, meters: [.samplePeak, .truePeak])
      m.feed(Signal(sampleRate: fs, channels: [x]))
      XCTAssertEqual(Double(m.snapshot()[0].truePeakMax), dB(Reference.truePeak(x, sampleRate: fs)), accuracy: 1e-4, "\(fs)")
    }
  }

  // EBU Tech 3341 cases 20-23: fs/6 at 0.5 with one fs/4 period at 1.0,
  // synthesized at 4 fs, low-passed and decimated at offsets 0-3. Expected
  // 0.0 dBTP. The samples depend only on fs-relative frequencies, so the
  // same arrays are the cases at every rate.
  func testTruePeakTech3341Cases20To23() throws {
    let fs = 48000.0
    let up = 4 * fs
    // fs/6 is 24 samples per period at 4 fs, fs/4 is 16.
    var hi: [Double] = []
    for i in 0..<(24 * 400) { hi.append(0.5 * sin(2 * Double.pi * Double(i) / 24)) }
    for i in 0..<16 { hi.append(sin(2 * Double.pi * Double(i) / 16)) }
    for i in 0..<(24 * 400) { hi.append(0.5 * sin(2 * Double.pi * Double(i) / 24)) }
    // Blackman-windowed sinc, cut-off 0.45 fs.
    let taps = 511
    let fc = 0.45 * fs / up
    var h = (0..<taps).map { k -> Double in
      let m = Double(k - taps / 2)
      let sinc = m == 0 ? 2 * fc : sin(2 * Double.pi * fc * m) / (Double.pi * m)
      let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(k) / Double(taps - 1))
        + 0.08 * cos(4 * Double.pi * Double(k) / Double(taps - 1))
      return sinc * w
    }
    let gain = h.reduce(0, +)
    h = h.map { $0 / gain }
    for offset in 0..<4 {
      var x: [Float] = []
      var i = taps + offset
      while i < hi.count {
        var acc = 0.0
        for k in 0..<taps { acc += h[k] * hi[i - k] }
        x.append(Float(acc))
        i += 4
      }
      for rate in Self.allRates {
        let m = try meter(rate)
        m.feed(Signal(sampleRate: rate, channels: [x, x]))
        let tp = Double(m.snapshot().maximumTruePeak)
        XCTAssertLessThanOrEqual(tp, 0.2, "offset \(offset) at \(rate)")
        XCTAssertGreaterThanOrEqual(tp, -0.4, "offset \(offset) at \(rate)")
      }
    }
  }

  func testTruePeakNeverReadsBelowSamplePeak() throws {
    for fs in Self.rates {
      let m = try meter(fs, channels: 3)
      let signal = Signal(sampleRate: fs, channels: [
        Signal.noise(amplitude: 0.9, frames: 20000, seed: 5),
        Signal.sine(frequency: 0.37 * fs, dBFS: -1, seconds: 0.4, sampleRate: fs, phaseDegrees: 17),
        Signal.sine(frequency: 997, dBFS: -3, seconds: 0.4, sampleRate: fs),
      ].map { Array($0.prefix(15000)) })
      m.feed(signal, blockSize: 97) { s in
        for c in 0..<3 {
          XCTAssertGreaterThanOrEqual(s[c].truePeak, s[c].samplePeak)
          XCTAssertGreaterThanOrEqual(s[c].truePeakHold, s[c].samplePeakHold)
          XCTAssertGreaterThanOrEqual(s[c].truePeakMax, s[c].samplePeakHold)
        }
      }
    }
  }

  func testInputFormatsAgree() throws {
    let fs = 48000.0
    let frames = 9600
    let left = Signal.noise(amplitude: 0.6, frames: frames, seed: 21)
    let right = Signal.sine(frequency: 1234, dBFS: -9, seconds: 0.2, sampleRate: fs)
    let signal = Signal(sampleRate: fs, channels: [left, right])

    let reference = try meter(fs)
    reference.feed(signal)
    let expected = reference.snapshot()

    func check(_ s: AudioMeterSnapshot, _ tolerance: Float, _ label: String) {
      for c in 0..<2 {
        XCTAssertEqual(s[c].samplePeakHold, expected[c].samplePeakHold, accuracy: tolerance, label)
        XCTAssertEqual(s[c].truePeakMax, expected[c].truePeakMax, accuracy: tolerance, label)
        XCTAssertEqual(s[c].rms, expected[c].rms, accuracy: tolerance, label)
        XCTAssertEqual(s[c].vu, expected[c].vu, accuracy: tolerance, label)
        XCTAssertEqual(s[c].ppm, expected[c].ppm, accuracy: tolerance, label)
      }
      XCTAssertEqual(s.loudness.momentary, expected.loudness.momentary, accuracy: tolerance, label)
      XCTAssertEqual(s.frameCount, UInt64(frames), label)
    }

    // Interleaved Float32, fed in uneven blocks.
    let interleaved = signal.interleaved
    let a = try meter(fs)
    interleaved.withUnsafeBufferPointer { p in
      var offset = 0
      for n in [1, 100, 511, 512, 513, 4000] {
        a.process(interleaved: p.baseAddress! + offset * 2, frameCount: n)
        offset += n
      }
      a.process(interleaved: p.baseAddress! + offset * 2, frameCount: frames - offset)
    }
    check(a.snapshot(), 1e-4, "interleaved float")

    // Int16 and Int32, interleaved and planar.
    let i16 = interleaved.map { Int16(($0 * 32768).rounded()) }
    let b = try meter(fs)
    i16.withUnsafeBufferPointer { b.process(interleaved: $0.baseAddress!, frameCount: frames) }
    check(b.snapshot(), 0.01, "interleaved int16")

    let i32 = interleaved.map { Int32((Double($0) * 2_147_483_648).rounded()) }
    let c = try meter(fs)
    i32.withUnsafeBufferPointer { c.process(interleaved: $0.baseAddress!, frameCount: frames) }
    check(c.snapshot(), 1e-4, "interleaved int32")

    var left16 = left.map { Int16(($0 * 32768).rounded()) }
    var right16 = right.map { Int16(($0 * 32768).rounded()) }
    let d = try meter(fs)
    left16.withUnsafeMutableBufferPointer { l in
      right16.withUnsafeMutableBufferPointer { r in
        let pointers = [l.baseAddress!, r.baseAddress!]
        d.process(planar: pointers, frameCount: frames)
      }
    }
    check(d.snapshot(), 0.01, "planar int16")

    // AVAudioPCMBuffer, deinterleaved and interleaved, through the buffer list.
    for interleave in [false, true] {
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: fs, channels: 2, interleaved: interleave)!
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
      buffer.frameLength = AVAudioFrameCount(frames)
      let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
      if interleave {
        list[0].mData!.copyMemory(from: interleaved, byteCount: frames * 2 * 4)
      } else {
        list[0].mData!.copyMemory(from: left, byteCount: frames * 4)
        list[1].mData!.copyMemory(from: right, byteCount: frames * 4)
      }
      let e = try meter(fs)
      e.process(bufferList: buffer.audioBufferList, frameCount: frames, format: .float32)
      check(e.snapshot(), 1e-4, "buffer list interleaved \(interleave)")
      if !interleave {
        let f = try meter(fs)
        f.process(planar: buffer.floatChannelData!, frameCount: frames)
        check(f.snapshot(), 1e-4, "floatChannelData")
      }
    }
  }

  func testFrameStrideAndMissingChannels() throws {
    let fs = 48000.0
    // Four interleaved channels; meter the first two only.
    let frames = 4800
    var wide = [Float](repeating: 0, count: frames * 4)
    for i in 0..<frames {
      wide[i * 4] = 0.5
      wide[i * 4 + 1] = 0.25
      wide[i * 4 + 2] = 1
      wide[i * 4 + 3] = 1
    }
    let m = try meter(fs)
    wide.withUnsafeBufferPointer { m.process(interleaved: $0.baseAddress!, frameCount: frames, frameStride: 4) }
    XCTAssertEqual(m.snapshot()[0].samplePeakHold, 20 * log10(0.5), accuracy: 1e-5)
    XCTAssertEqual(m.snapshot()[1].samplePeakHold, 20 * log10(0.25), accuracy: 1e-5)

    // A mono buffer list feeding a stereo meter: the second channel is silent.
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fs, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480
    for i in 0..<480 { buffer.floatChannelData![0][i] = 0.5 }
    let n = try meter(fs)
    n.process(bufferList: buffer.audioBufferList, frameCount: 480, format: .float32)
    XCTAssertEqual(n.snapshot()[0].samplePeakHold, 20 * log10(0.5), accuracy: 1e-5)
    XCTAssertEqual(n.snapshot()[1].samplePeakHold, -.infinity)
  }

  /// A buffer without data (an unrendered bus) reads as silence and keeps
  /// every later buffer on its own channels.
  func testBufferListWithoutDataKeepsChannelPositions() throws {
    let fs = 48000.0
    let frames = 256
    let data = (0..<4).map { c in
      let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
      p.initialize(repeating: Float(c + 1) / 8, count: frames * 2)
      return p
    }
    defer { data.forEach { $0.deallocate() } }
    func list(_ buffers: [(channels: Int, data: UnsafeMutablePointer<Float>?)]) -> UnsafeMutableAudioBufferListPointer {
      let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
      for (i, b) in buffers.enumerated() {
        list[i] = AudioBuffer(
          mNumberChannels: UInt32(b.channels), mDataByteSize: b.data == nil ? 0 : UInt32(frames * b.channels * 4),
          mData: b.data.map(UnsafeMutableRawPointer.init))
      }
      return list
    }
    let cases: [(buffers: [(channels: Int, data: UnsafeMutablePointer<Float>?)], expected: [Float?])] = [
      // Nil first, then the right channel.
      ([(1, nil), (1, data[0])], [nil, 1.0 / 8]),
      // Nil in the middle of three.
      ([(1, data[0]), (1, nil), (1, data[2])], [1.0 / 8, nil, 3.0 / 8]),
      // A nil stereo pair before a mono buffer, then channels the list does not carry.
      ([(2, nil), (1, data[1])], [nil, nil, 2.0 / 8, nil]),
      // An interleaved pair after a nil buffer.
      ([(1, nil), (2, data[3])], [nil, 4.0 / 8, 4.0 / 8]),
    ]
    for (i, c) in cases.enumerated() {
      let l = list(c.buffers)
      defer { free(l.unsafeMutablePointer) }
      let m = try meter(fs, channels: c.expected.count, meters: [.samplePeak])
      m.process(bufferList: l.unsafePointer, frameCount: frames, format: .float32)
      for (ch, level) in c.expected.enumerated() {
        let reading = m.snapshot()[ch].samplePeakHold
        if let level {
          XCTAssertEqual(reading, 20 * log10(level), accuracy: 1e-5, "case \(i) channel \(ch)")
        } else {
          XCTAssertEqual(reading, -.infinity, "case \(i) channel \(ch)")
        }
      }
    }

    // Loudness weights stay on their channels: 5.1 with an unrendered LFE bus
    // reads like 5.1 with a silent LFE, not like the surrounds moved down.
    let tone = Signal.sine(frequency: 1000, dBFS: -20, seconds: 1, sampleRate: fs)
    let surround = Signal.sine(frequency: 1000, dBFS: -30, seconds: 1, sampleRate: fs)
    let count = tone.count
    let planes = [tone, tone, tone, nil, surround, surround].map { plane -> UnsafeMutablePointer<Float>? in
      plane.map { p in
        let b = UnsafeMutablePointer<Float>.allocate(capacity: count)
        b.initialize(from: p, count: count)
        return b
      }
    }
    defer { planes.forEach { $0?.deallocate() } }
    let l = AudioBufferList.allocate(maximumBuffers: 6)
    defer { free(l.unsafeMutablePointer) }
    for (i, p) in planes.enumerated() {
      l[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: p == nil ? 0 : UInt32(count * 4), mData: p.map(UnsafeMutableRawPointer.init))
    }
    let withList = try LoudnessMeter(sampleRate: fs, channelCount: 6)
    withList.process(bufferList: l.unsafePointer, frameCount: count, format: .float32)
    let planar = try LoudnessMeter(sampleRate: fs, channelCount: 6)
    planar.feed(Signal(sampleRate: fs, channels: [tone, tone, tone, [Float](repeating: 0, count: count), surround, surround]))
    XCTAssertEqual(withList.snapshot().momentary, planar.snapshot().momentary, accuracy: 1e-5)
    XCTAssertTrue(withList.snapshot().momentary.isFinite)
  }

  /// Exactly at the clip level counts; the next Float below does not.
  func testClipLevelBoundary() throws {
    let fs = 48000.0
    let clip = Float(pow(10, -0.01 / 20))
    var x = [Float](repeating: 0.1, count: 1000)
    x[10] = clip
    x[20] = -clip
    x[30] = clip.nextDown
    x[40] = -clip.nextDown
    x[50] = 2
    let m = try meter(fs, channels: 1)
    m.feed(Signal(sampleRate: fs, channels: [x]), blockSize: 300)
    XCTAssertEqual(m.snapshot()[0].clipCount, 3)
  }

  /// A full reset during programme keeps the interpolator's memory, so a
  /// reset that lands on a crest adds no false over to Max TP.
  func testResetMidStreamAddsNoTruePeakOvershoot() throws {
    let fs = 48000.0
    // A -1 dBTP cosine; 480-frame blocks put every block start on a crest.
    let amplitude = Signal.amplitude(-1)
    let x = (0..<Int(fs)).map { Float(amplitude * cos(2 * Double.pi * 1000 * Double($0) / fs)) }
    let half = Int(fs / 2)
    for reset in [false, true] {
      let m = try meter(fs, channels: 1)
      m.feed(Signal(sampleRate: fs, channels: [Array(x.prefix(half))]), blockSize: 480)
      if reset { m.reset() } else { m.resetPeaks() }
      m.feed(Signal(sampleRate: fs, channels: [Array(x[half..<(half + 480)])]), blockSize: 480)
      let s = m.snapshot()[0]
      XCTAssertEqual(Double(s.truePeakMax), -1, accuracy: 0.1, "reset \(reset)")
      XCTAssertEqual(Double(s.truePeakHold), -1, accuracy: 0.1, "reset \(reset)")
    }
  }

  /// A meter attached to a running stream (its first buffer starts on a
  /// crest) does not read the zeros before it as a step.
  func testAttachMidStreamAddsNoTruePeakOvershoot() throws {
    let fs = 48000.0
    for phase in stride(from: 0.0, to: 360, by: 30) {
      let x = Signal.sine(frequency: 997, dBFS: -1, seconds: 0.02, sampleRate: fs, phaseDegrees: 90 + phase)
      let m = try meter(fs, channels: 1)
      m.feed(Signal(sampleRate: fs, channels: [x]), blockSize: 480)
      XCTAssertLessThanOrEqual(Double(m.snapshot()[0].truePeakMax), -1 + 0.1, "phase \(phase)")
    }
  }

  func testPeakHoldAndDecay() throws {
    let fs = 48000.0
    let m = try meter(fs, channels: 1, hold: 1, decay: 20)
    m.feed(Signal(sampleRate: fs, channels: [Signal.sine(frequency: 1000, dBFS: -6, seconds: 0.1, sampleRate: fs)]))
    var t = 0.0
    var checks = 0
    m.feed(.silence(seconds: 2, sampleRate: fs, channels: 1), blockSize: 480) { s in
      t += 0.01
      let crest = 20 * log10(Signal.amplitude(-6))
      XCTAssertEqual(Double(s[0].samplePeak), crest - 20 * t, accuracy: 0.05, "bar at \(t)")
      if t < 0.99 {
        XCTAssertEqual(Double(s[0].samplePeakHold), crest, accuracy: 1e-4, "hold at \(t)")
      } else if t > 1.02 {
        XCTAssertEqual(Double(s[0].samplePeakHold), crest - 20 * (t - 1), accuracy: 0.25, "release at \(t)")
        checks += 1
      }
    }
    XCTAssertGreaterThan(checks, 90)

    // Infinite hold.
    let h = try meter(fs, channels: 1, hold: .infinity)
    h.feed(Signal(sampleRate: fs, channels: [Signal.sine(frequency: 1000, dBFS: -3, seconds: 0.1, sampleRate: fs)]))
    h.feed(.silence(seconds: 10, sampleRate: fs, channels: 1), blockSize: 4096)
    XCTAssertEqual(Double(h.snapshot()[0].samplePeakHold), -3, accuracy: 1e-3)
    XCTAssertLessThan(h.snapshot()[0].samplePeak, -100)
    // A peak reset drops the marker onto the bar.
    h.resetPeaks()
    h.feed(.silence(seconds: 0.01, sampleRate: fs, channels: 1))
    XCTAssertEqual(h.snapshot()[0].samplePeakHold, h.snapshot()[0].samplePeak, accuracy: 0.2)
  }

  func testClipCountAndPeakReset() throws {
    let fs = 48000.0
    var x = [Float](repeating: 0.1, count: 4800)
    for i in [10, 11, 12, 900, 2000, 4700] { x[i] = 1 }
    x[3000] = -1
    let m = try meter(fs, channels: 1)
    m.feed(Signal(sampleRate: fs, channels: [x]), blockSize: 1000)
    XCTAssertEqual(m.snapshot()[0].clipCount, 7)
    XCTAssertGreaterThanOrEqual(m.snapshot()[0].truePeakMax, 0)
    m.resetPeaks()
    m.feed(.silence(seconds: 0.1, sampleRate: fs, channels: 1))
    let s = m.snapshot()[0]
    XCTAssertEqual(s.clipCount, 0)
    // Only the 0.1 tail that was still in the interpolator's delay line remains.
    XCTAssertEqual(Double(s.truePeakMax), -20, accuracy: 1.5)
  }

  func testNonFiniteInputIsContained() throws {
    let fs = 48000.0
    var x = Signal.sine(frequency: 1000, dBFS: -20, seconds: 1, sampleRate: fs)
    x[100] = .nan
    x[5000] = .infinity
    x[20000] = -.infinity
    x[25000] = 3e38
    for i in 30000..<30600 { x[i] = .nan }
    let m = try meter(fs, channels: 1)
    m.feed(Signal(sampleRate: fs, channels: [x]))
    m.feed(Signal(sampleRate: fs, channels: [Signal.sine(frequency: 1000, dBFS: -20, seconds: 3, sampleRate: fs)]))
    let s = m.snapshot()
    for v in [s[0].samplePeak, s[0].truePeak, s[0].rms, s[0].vu, s[0].ppm, s.loudness.momentary, s.loudness.integrated] {
      XCTAssertTrue(v.isFinite, "\(s[0]) \(s.loudness)")
    }
    XCTAssertEqual(Double(s[0].rms), -20, accuracy: 0.01)
    XCTAssertEqual(Double(s.loudness.momentary), -23, accuracy: 0.1)
    // Huge finite samples are clamped to +120 dBFS, so nothing overflowed.
    XCTAssertEqual(Double(s[0].truePeakMax), 120, accuracy: 0.5)

    // Infinity alone reads as full scale.
    var y = [Float](repeating: 0, count: 4800)
    y[100] = .infinity
    let n = try meter(fs, channels: 1)
    n.feed(Signal(sampleRate: fs, channels: [y]))
    XCTAssertEqual(n.snapshot()[0].samplePeakHold, 0, accuracy: 1e-6)
  }

  func testDisabledMetersAndFullReset() throws {
    let fs = 48000.0
    let m = try meter(fs, channels: 1, meters: [.samplePeak, .rms])
    m.feed(.tone(dBFS: -10, seconds: 0.5, sampleRate: fs, channels: 1))
    var s = m.snapshot()
    XCTAssertEqual(Double(s[0].samplePeak), -10, accuracy: 0.01)
    XCTAssertEqual(s[0].truePeak, -.infinity)
    XCTAssertEqual(s[0].vu, -.infinity)
    XCTAssertEqual(s[0].ppm, -.infinity)
    XCTAssertEqual(s.loudness.momentary, -.infinity)
    m.reset()
    m.feed(.silence(seconds: 0.01, sampleRate: fs, channels: 1))
    s = m.snapshot()
    XCTAssertEqual(s[0].samplePeak, -.infinity)
    XCTAssertEqual(s[0].rms, -.infinity)
    XCTAssertEqual(s.frameCount, 480)
  }

  /// Every channel lands in its own lane: 1, 2, 6 and 16 channels, each at its own level.
  func testChannelsAreIndependent() throws {
    let fs = 48000.0
    for count in [1, 2, 6, 16] {
      let levels = (0..<count).map { -3 - 2 * Double($0) }
      let signal = Signal(sampleRate: fs, channels: levels.map {
        Signal.sine(frequency: 1000, dBFS: $0, seconds: 2, sampleRate: fs)
      })
      let m = try AudioMeter(sampleRate: fs, channelCount: count)
      m.feed(signal, blockSize: 1000)
      let s = m.snapshot()
      XCTAssertEqual(s.channelCount, count)
      for c in 0..<count {
        let level = levels[c]
        XCTAssertEqual(Double(s[c].samplePeak), level, accuracy: 1e-3, "peak \(c)/\(count)")
        XCTAssertEqual(Double(s[c].truePeakMax), level, accuracy: 0.05, "true peak \(c)/\(count)")
        XCTAssertEqual(Double(s[c].rms), level, accuracy: 1e-3, "rms \(c)/\(count)")
        XCTAssertEqual(Double(s[c].vu), level + 18, accuracy: 0.02, "vu \(c)/\(count)")
        XCTAssertEqual(Double(s[c].ppm), level + 18, accuracy: 0.06, "ppm \(c)/\(count)")
      }
    }
  }

  func testEmbeddedLoudnessMatchesLoudnessMeter() throws {
    let fs = 48000.0
    let signal = Signal(sampleRate: fs, channels: (0..<6).map {
      Signal.noise(amplitude: 0.1 * Double($0 + 1), frames: Int(4 * fs), seed: UInt64($0))
    })
    let a = try AudioMeter(sampleRate: fs, channelCount: 6)
    a.feed(signal, blockSize: 1024)
    let l = try LoudnessMeter(sampleRate: fs, channelCount: 6)
    l.feed(signal, blockSize: 1024)
    XCTAssertEqual(a.snapshot().loudness, l.snapshot())
  }
}
