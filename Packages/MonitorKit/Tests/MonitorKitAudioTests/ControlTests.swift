import Foundation
import MonitorKitAudio
import XCTest

/// Measurement control (EBU Tech 3341 pause and continue), default channel
/// layouts, the RMS window's running sum and the publish interval.
final class ControlTests: XCTestCase {
  // MARK: Pause and continue (Tech 3341 section 2.2)

  /// -20 dBFS for 10 s, a -30 dBFS stretch while paused, -20 dBFS again: I
  /// and LRA read as if the stretch were cut out, momentary follows it, and
  /// `duration` counts only measured audio.
  func testPausedSegmentIsLeftOutOfIntegratedAndRange() throws {
    let fs = 48000.0
    let signal = Signal.toneSequence([(-20, 10), (-30, 10), (-20, 10)], sampleRate: fs)
    let ten = Int(10 * fs)
    func part(_ range: Range<Int>) -> Signal {
      Signal(sampleRate: fs, channels: signal.channels.map { Array($0[range]) })
    }

    let paused = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    paused.feed(part(0..<ten), blockSize: 480)
    paused.pauseMeasurement()
    XCTAssertTrue(paused.isMeasurementPaused)
    var momentaryDuringPause = -Float.infinity
    paused.feed(part(ten..<(2 * ten)), blockSize: 480) { momentaryDuringPause = $0.momentary }
    let during = paused.snapshot()
    XCTAssertEqual(during.duration, 10, accuracy: 1e-9)
    XCTAssertEqual(Double(momentaryDuringPause), -30, accuracy: 0.1, "momentary keeps running")
    XCTAssertEqual(Double(during.shortTerm), -30, accuracy: 0.1, "short-term keeps running")
    XCTAssertEqual(Double(during.integrated), -20, accuracy: 0.1, "integrated is frozen")
    paused.resumeMeasurement()
    XCTAssertFalse(paused.isMeasurementPaused)
    paused.feed(part((2 * ten)..<(3 * ten)), blockSize: 480)

    // The same programme with the paused stretch cut out.
    let cut = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    cut.feed(part(0..<ten).appending(part((2 * ten)..<(3 * ten))), blockSize: 480)
    let a = paused.snapshot()
    let b = cut.snapshot()
    XCTAssertEqual(a.duration, 20, accuracy: 1e-9)
    XCTAssertEqual(a.integrated, b.integrated, accuracy: 0.01)
    XCTAssertEqual(a.loudnessRange, b.loudnessRange, accuracy: 0.05)
    XCTAssertEqual(Double(a.integrated), -20, accuracy: 0.1)
    XCTAssertEqual(Double(a.loudnessRange), 0, accuracy: 0.1)
    // The maxima are display values and saw the whole signal.
    XCTAssertEqual(a.momentaryMax, b.momentaryMax, accuracy: 0.01)

    // Without the pause the -30 dBFS stretch passes the relative gate and widens LRA.
    let whole = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    whole.feed(signal, blockSize: 480)
    XCTAssertLessThan(whole.snapshot().integrated, a.integrated - 1)
    XCTAssertGreaterThan(whole.snapshot().loudnessRange, 5)
  }

  /// `AudioMeter`'s embedded loudness pauses the same way while its level meters keep running.
  func testAudioMeterPausesLoudnessOnly() throws {
    let fs = 48000.0
    let signal = Signal.toneSequence([(-20, 5), (-10, 5), (-20, 5)], sampleRate: fs)
    let five = Int(5 * fs)
    func part(_ range: Range<Int>) -> Signal {
      Signal(sampleRate: fs, channels: signal.channels.map { Array($0[range]) })
    }
    let m = try AudioMeter(sampleRate: fs, channelCount: 2)
    let l = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    m.feed(part(0..<five), blockSize: 960)
    l.feed(part(0..<five), blockSize: 960)
    m.pauseLoudness()
    l.pauseMeasurement()
    XCTAssertTrue(m.isLoudnessPaused)
    m.feed(part(five..<(2 * five)), blockSize: 960)
    l.feed(part(five..<(2 * five)), blockSize: 960)
    XCTAssertEqual(Double(m.snapshot()[0].samplePeak), -10, accuracy: 0.01, "level meters keep running")
    XCTAssertEqual(Double(m.snapshot()[0].truePeakMax), -10, accuracy: 0.05)
    // A reset while paused starts a measurement that stays on stand-by.
    m.resetLoudness()
    l.resetMeasurement()
    m.feed(part((2 * five)..<(2 * five + 48000)), blockSize: 960)
    l.feed(part((2 * five)..<(2 * five + 48000)), blockSize: 960)
    XCTAssertEqual(m.snapshot().loudness.duration, 0)
    XCTAssertEqual(m.snapshot().loudness.integrated, -.infinity)
    XCTAssertTrue(m.snapshot().loudness.momentary.isFinite)
    m.resumeLoudness()
    l.resumeMeasurement()
    m.feed(part((2 * five + 48000)..<(3 * five)), blockSize: 960)
    l.feed(part((2 * five + 48000)..<(3 * five)), blockSize: 960)
    XCTAssertEqual(m.snapshot().loudness, l.snapshot())
    XCTAssertEqual(m.snapshot().loudness.duration, 4, accuracy: 1e-9)
    XCTAssertEqual(Double(m.snapshot().loudness.integrated), -20, accuracy: 0.1)
  }

  /// Pause and continue requested between calls that do not fall on the
  /// 5 ms tick grid take effect at the next tick, so `duration` (and the
  /// gating input) holds whole ticks only.
  func testPauseTakesEffectOnTickBoundaries() throws {
    let fs = 48000.0
    let tick = 240.0 / fs
    let m = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    let a = try AudioMeter(sampleRate: fs, channelCount: 2)
    let tone = Signal.tone(dBFS: -20, seconds: 1.0021, sampleRate: fs)
    m.feed(tone, blockSize: 100)
    a.feed(tone, blockSize: 100)
    m.pauseMeasurement()
    a.pauseLoudness()
    m.feed(tone, blockSize: 100)
    a.feed(tone, blockSize: 100)
    let paused = m.snapshot().duration
    // 48101 frames measured so far; the tick open at the pause (frames 48000 ..< 48240) completes.
    XCTAssertEqual(paused, 201 * tick, accuracy: 1e-9)
    XCTAssertEqual(a.snapshot().loudness.duration, paused, accuracy: 1e-9)
    m.resumeMeasurement()
    a.resumeLoudness()
    m.feed(tone, blockSize: 100)
    a.feed(tone, blockSize: 100)
    // Continues at the first tick boundary after the call: 96202 frames in, the tick at 96240.
    let resumed = m.snapshot().duration
    XCTAssertEqual(resumed, paused + (144_303 - 96240) / fs, accuracy: 1e-9)
    XCTAssertEqual(a.snapshot().loudness, m.snapshot())
  }

  // MARK: Channel layouts

  func testDefaultLayoutsAndPresets() throws {
    XCTAssertEqual(LoudnessChannel.standardLayout(channelCount: 1), [.center])
    XCTAssertEqual(LoudnessChannel.standardLayout(channelCount: 2), [.left, .right])
    XCTAssertEqual(LoudnessChannel.standardLayout(channelCount: 6), LoudnessChannel.surround51)
    for count in [3, 4, 7, 8, 12, 16] {
      let layout = LoudnessChannel.standardLayout(channelCount: count)
      XCTAssertEqual(layout.count, count)
      XCTAssertEqual(Array(layout.prefix(2)), [.left, .right], "\(count)")
      XCTAssertTrue(layout.dropFirst(2).allSatisfy { $0 == .excluded }, "\(count)")
    }
    XCTAssertEqual(LoudnessChannel.surround71.map(\.weight), [1, 1, 1, 0, 1.41, 1.41, 1, 1])
    XCTAssertEqual(
      LoudnessChannel.programmePair(channelCount: 8, first: 4),
      [.excluded, .excluded, .excluded, .excluded, .left, .right, .excluded, .excluded])
    XCTAssertEqual(LoudnessChannel.programmePair(channelCount: 1), [.center])
  }

  /// A layout that measures no channel would read -infinity for ever, like
  /// silence on the programme; the meters refuse it instead. That includes a
  /// pair outside the channels (a stale or 1-based pair index).
  func testLayoutsThatMeasureNothingThrow() throws {
    let fs = 48000.0
    let nothing = AudioMeterError.invalidParameter("loudness layout measures no channel")
    let layouts: [[LoudnessChannel]] = [
      LoudnessChannel.programmePair(channelCount: 4, first: 3),
      LoudnessChannel.programmePair(channelCount: 16, first: 15),
      LoudnessChannel.programmePair(channelCount: 2, first: -1),
      LoudnessChannel.programmePair(channelCount: 1, first: 1),
      [.lfe], [.excluded, .excluded], [.weighted(0), .lfe],
    ]
    for layout in layouts {
      XCTAssertThrowsError(try LoudnessMeter(sampleRate: fs, channels: layout), "\(layout)") {
        XCTAssertEqual($0 as? AudioMeterError, nothing)
      }
      XCTAssertThrowsError(
        try AudioMeter(configuration: .init(sampleRate: fs, channelCount: layout.count, loudnessChannels: layout)),
        "\(layout)"
      ) { XCTAssertEqual($0 as? AudioMeterError, nothing) }
      // The layout is only checked when loudness runs.
      XCTAssertNoThrow(try AudioMeter(configuration: .init(
        sampleRate: fs, channelCount: layout.count, meters: [.samplePeak, .truePeak], loudnessChannels: layout)))
    }
    // One measured channel is enough.
    XCTAssertNoThrow(try LoudnessMeter(sampleRate: fs, channels: [.excluded, .lfe, .weighted(0.5)]))
  }

  /// A stored configuration without an explicit layout follows a change of
  /// `channelCount` (a new SDI format); an explicit layout has to be reassigned.
  func testConfigurationLayoutFollowsChannelCount() throws {
    var c = AudioMeterConfiguration(sampleRate: 48000, channelCount: 2, ppmType: .typeI)
    XCTAssertNil(c.loudnessLayout)
    XCTAssertEqual(c.loudnessChannels, LoudnessChannel.stereo)
    c.channelCount = 16
    XCTAssertEqual(c.loudnessChannels, LoudnessChannel.standardLayout(channelCount: 16))
    XCTAssertEqual(try AudioMeter(configuration: c).configuration.ppmType, .typeI)
    c.channelCount = 6
    XCTAssertEqual(try AudioMeter(configuration: c).configuration.loudnessChannels, LoudnessChannel.surround51)

    c.loudnessChannels = LoudnessChannel.surround51
    XCTAssertEqual(c.loudnessLayout, LoudnessChannel.surround51)
    c.channelCount = 2
    XCTAssertThrowsError(try AudioMeter(configuration: c)) {
      XCTAssertEqual($0 as? AudioMeterError, .channelLayoutMismatch(expected: 2, actual: 6))
    }
    c.loudnessLayout = nil
    XCTAssertNoThrow(try AudioMeter(configuration: c))
    // Equality compares the stored choice.
    let standard = AudioMeterConfiguration(sampleRate: 48000, channelCount: 2)
    XCTAssertEqual(standard, AudioMeterConfiguration(sampleRate: 48000, channelCount: 2))
    XCTAssertNotEqual(standard, AudioMeterConfiguration(sampleRate: 48000, channelCount: 2, loudnessChannels: LoudnessChannel.stereo))
  }

  // MARK: Programme true peak

  /// EBU R 128 "Max TP" is the programme's: on a 16-channel embed with the
  /// programme on pair 1, a hotter ISO feed on channel 3 does not count.
  func testProgrammeMaximumTruePeakSkipsExcludedChannels() throws {
    let fs = 48000.0
    let programme = Signal.sine(frequency: 997, dBFS: -2, seconds: 1, sampleRate: fs)
    let iso = Signal.sine(frequency: 997, dBFS: -0.5, seconds: 1, sampleRate: fs)
    let silent = [Float](repeating: 0, count: programme.count)
    var channels = [[Float]](repeating: silent, count: 16)
    channels[0] = programme
    channels[1] = programme
    channels[2] = iso
    let signal = Signal(sampleRate: fs, channels: channels)

    let m = try AudioMeter(sampleRate: fs, channelCount: 16)
    m.feed(signal, blockSize: 480)
    let s = m.snapshot()
    XCTAssertEqual(s.programmeChannelMask, 0b11)
    XCTAssertEqual(Double(s.programmeMaximumTruePeak), -2, accuracy: 0.05)
    XCTAssertEqual(Double(s.maximumTruePeak), -0.5, accuracy: 0.05)
    XCTAssertEqual(s.programmeMaximumTruePeak, max(s[0].truePeakMax, s[1].truePeakMax))
    // The mask survives resets and pending resets.
    m.reset()
    XCTAssertEqual(m.snapshot().programmeChannelMask, 0b11)
    XCTAssertEqual(m.snapshot().programmeMaximumTruePeak, -.infinity)
    m.flush()
    XCTAssertEqual(m.snapshot().programmeChannelMask, 0b11)

    // A pair elsewhere moves the programme; LFE stays in it at weight 0.
    let pair3 = try AudioMeter(configuration: .init(
      sampleRate: fs, channelCount: 16, loudnessChannels: LoudnessChannel.programmePair(channelCount: 16, first: 2)))
    pair3.feed(signal, blockSize: 480)
    XCTAssertEqual(pair3.snapshot().programmeChannelMask, 0b1100)
    XCTAssertEqual(Double(pair3.snapshot().programmeMaximumTruePeak), -0.5, accuracy: 0.05)
    let surround = try AudioMeter(sampleRate: fs, channelCount: 6)
    XCTAssertEqual(surround.snapshot().programmeChannelMask, 0b11_1111)
    // With loudness off every channel is the programme.
    let levels = try AudioMeter(configuration: .init(sampleRate: fs, channelCount: 16, meters: [.truePeak]))
    levels.feed(signal, blockSize: 480)
    XCTAssertEqual(levels.snapshot().programmeChannelMask, 0xFFFF)
    XCTAssertEqual(levels.snapshot().programmeMaximumTruePeak, levels.snapshot().maximumTruePeak)
    XCTAssertEqual(AudioMeterSnapshot().programmeMaximumTruePeak, -.infinity)
  }

  // MARK: Loudness reset

  /// A loudness reset on a meter that keeps running starts integrated, LRA,
  /// the maxima and duration over, from the next tick boundary, while
  /// momentary and short-term slide on over the continuous audio.
  func testLoudnessResetKeepsMomentaryAndShortTermRunning() throws {
    let fs = 48000.0
    let tick = 240
    let a = try AudioMeter(configuration: .init(sampleRate: fs, channelCount: 2, publishInterval: 0))
    let l = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    // 4 s at -10 dBFS then -20 dBFS, one continuous sine, in 100-frame calls:
    // the reset at 4.0021 s falls 101 frames into a 240-frame tick.
    let loudStart = 192_101
    let signal = Signal.toneSequence([(-10, Double(loudStart) / fs), (-20, 4)], sampleRate: fs)
    func part(_ range: Range<Int>) -> Signal {
      Signal(sampleRate: fs, channels: signal.channels.map { Array($0[range]) })
    }
    a.feed(part(0..<loudStart), blockSize: 100)
    l.feed(part(0..<loudStart), blockSize: 100)
    let before = l.snapshot()
    XCTAssertEqual(Double(before.momentary), -10, accuracy: 0.05)
    XCTAssertEqual(Double(before.shortTerm), -10, accuracy: 0.05)
    XCTAssertEqual(a.snapshot().loudness, before)

    a.resetLoudness()
    l.resetMeasurement()
    XCTAssertEqual(l.snapshot(), before.startingOver)
    XCTAssertEqual(a.snapshot().loudness, before.startingOver)
    a.flush()
    XCTAssertEqual(a.snapshot().loudness, before.startingOver)

    var sawBlank = false
    var momentaryMaxFrom = -1
    var shortTermMaxFrom = -1
    var fed = loudStart
    let check = { (s: LoudnessSnapshot) in
      if !s.momentary.isFinite || !s.shortTerm.isFinite { sawBlank = true }
      if momentaryMaxFrom < 0, s.momentaryMax.isFinite { momentaryMaxFrom = fed }
      if shortTermMaxFrom < 0, s.shortTermMax.isFinite { shortTermMaxFrom = fed }
    }
    let block = 100
    var offset = loudStart
    while offset < signal.frameCount {
      let n = min(block, signal.frameCount - offset)
      a.feed(part(offset..<(offset + n)), blockSize: block)
      l.feed(part(offset..<(offset + n)), blockSize: block)
      offset += n
      fed = offset
      check(l.snapshot())
      XCTAssertEqual(a.snapshot().loudness, l.snapshot())
    }
    XCTAssertFalse(sawBlank, "momentary and short-term run through the reset")

    // The new measurement starts at the tick boundary 139 frames after the reset.
    let start = loudStart + tick - loudStart % tick
    let s = l.snapshot()
    XCTAssertEqual(s.duration, Double(signal.frameCount - start) / fs, accuracy: 1e-9)
    // The maxima only take windows wholly inside it: the first full 400 ms
    // and 3 s windows close 80 and 600 ticks after its start.
    XCTAssertEqual(momentaryMaxFrom, start + 80 * tick, accuracy: block)
    XCTAssertEqual(shortTermMaxFrom, start + 600 * tick, accuracy: block)
    XCTAssertEqual(Double(s.momentaryMax), -20, accuracy: 0.05)
    XCTAssertEqual(Double(s.shortTermMax), -20, accuracy: 0.05)
    XCTAssertEqual(Double(s.integrated), -20, accuracy: 0.05)
    XCTAssertEqual(Double(s.loudnessRange), 0, accuracy: 0.1)
    XCTAssertEqual(Double(s.momentary), -20, accuracy: 0.05)

    // A full reset clears the windows as well.
    a.reset()
    l.reset()
    XCTAssertEqual(a.snapshot().loudness, LoudnessSnapshot())
    XCTAssertEqual(l.snapshot(), LoudnessSnapshot())
    a.feed(part(0..<4800))
    l.feed(part(0..<4800))
    XCTAssertEqual(a.snapshot().loudness.momentary, -.infinity)
    XCTAssertEqual(l.snapshot().momentary, -.infinity)
  }

  /// A reset on a tick boundary starts the measurement right there.
  func testLoudnessResetOnTickBoundaryCountsEveryFrame() throws {
    let fs = 48000.0
    let l = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    l.feed(.tone(dBFS: -20, seconds: 1, sampleRate: fs), blockSize: 480)
    l.resetMeasurement()
    l.feed(.tone(dBFS: -20, seconds: 1, sampleRate: fs), blockSize: 480)
    let s = l.snapshot()
    XCTAssertEqual(s.duration, 1, accuracy: 1e-9)
    XCTAssertEqual(Double(s.momentaryMax), -20, accuracy: 0.05)
    XCTAssertEqual(s.shortTermMax, -.infinity)
  }

  /// A DeckLink embed carrying the same pair on all 16 channels reads as that
  /// one stereo programme by default, not 9 LU louder.
  func testSixteenChannelEmbedDefaultsToTheFirstPair() throws {
    let fs = 48000.0
    let m = try LoudnessMeter(sampleRate: fs, channelCount: 16)
    m.feed(.tone(dBFS: -23, seconds: 5, sampleRate: fs, channels: 16))
    let stereo = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    stereo.feed(.tone(dBFS: -23, seconds: 5, sampleRate: fs, channels: 2))
    XCTAssertEqual(m.snapshot().integrated, stereo.snapshot().integrated, accuracy: 1e-4)
    let a = try AudioMeter(sampleRate: fs, channelCount: 16)
    a.feed(.tone(dBFS: -23, seconds: 5, sampleRate: fs, channels: 16), blockSize: 1024)
    XCTAssertEqual(a.snapshot().loudness.integrated, stereo.snapshot().integrated, accuracy: 1e-4)
  }

  /// SMPTE 7.1: Tech 3341 case 6's 5.0 levels on L R C Lss Rss, a loud LFE
  /// that must not count, and the rears at weight 1.0.
  func testSurround71Weights() throws {
    let fs = 48000.0
    let levels: [Double?] = [-28, -28, -24, 0, -30, -30, -30, -30]
    let channels = levels.map { level in
      level.map { Signal.sine(frequency: 1000, dBFS: $0, seconds: 10, sampleRate: fs) }
        ?? [Float](repeating: 0, count: Int(10 * fs))
    }
    let m = try LoudnessMeter(sampleRate: fs, channels: LoudnessChannel.surround71)
    m.feed(Signal(sampleRate: fs, channels: channels))
    // Case 6 alone reads -23 LUFS; each rear adds a -30 dBFS sine's mono
    // loudness (-33.01 LUFS) at weight 1.
    let rear = pow(10, (-30 - 10 * log10(2.0)) / 10)
    let expected = 10 * log10(pow(10, -2.3) + 2 * rear)
    XCTAssertEqual(Double(m.snapshot().integrated), expected, accuracy: 0.1)
  }

  // MARK: RMS window

  /// A 60 s window kept as a running sum: after loud audio, a long quiet
  /// stretch (90 dB lower) and digital silence, the reading equals a direct
  /// sum over the window, and reads -infinity once only silence is left in it.
  func testLongRMSWindowRunningSumStaysExact() throws {
    // 8 kHz keeps the test short: 40-frame ticks, 12000 of them in the window.
    let fs = 8000.0
    let window = 60.0
    let m = try AudioMeter(configuration: .init(
      sampleRate: fs, channelCount: 1, meters: [.rms], rmsWindow: window, rmsScale: .unscaled, publishInterval: 0))
    let loud = Signal.noise(amplitude: 0.9, frames: Int(5 * fs), seed: 41)
    let quiet = Signal.noise(amplitude: 1e-5, frames: Int(57 * fs), seed: 42)
    let silence = [Float](repeating: 0, count: Int(62 * fs))
    let x = loud + quiet + silence
    let windowFrames = Int(window * fs)
    var checks = 0
    var fed = 0
    var sawQuietAfterLoud = false
    let block = 800
    m.feed(Signal(sampleRate: fs, channels: [x]), blockSize: block) { s in
      fed += block
      // Check every 2 s once the window has filled.
      guard fed % Int(2 * fs) == 0, fed >= windowFrames else { return }
      if fed == Int(66 * fs) { sawQuietAfterLoud = true }
      let start = fed - windowFrames
      var energy = 0.0
      for i in start..<fed { energy += Double(x[i]) * Double(x[i]) }
      if energy == 0 {
        XCTAssertEqual(s[0].rms, -.infinity, "at \(Double(fed) / fs) s")
      } else {
        XCTAssertEqual(Double(s[0].rms), 10 * log10(energy / Double(windowFrames)), accuracy: 1e-3, "at \(Double(fed) / fs) s")
      }
      checks += 1
    }
    XCTAssertGreaterThan(checks, 20)
    // 66 s in, the loud start has left and only the quiet noise is summed.
    XCTAssertTrue(sawQuietAfterLoud)
    // 124 s in, only silence remains in the window.
    XCTAssertEqual(m.snapshot()[0].rms, -.infinity)

    // A full reset clears the window without clearing the ring.
    m.reset()
    m.feed(Signal(sampleRate: fs, channels: [Array(loud.prefix(8000))]))
    let energy = loud.prefix(8000).reduce(0.0) { $0 + Double($1) * Double($1) }
    XCTAssertEqual(Double(m.snapshot()[0].rms), 10 * log10(energy / Double(windowFrames)), accuracy: 1e-3)
  }

  // MARK: Publish interval

  /// Small calls publish once per interval; nothing a publish carries is lost
  /// in between, and a zero-length call flushes what is pending.
  func testPublishIntervalKeepsEveryPeak() throws {
    let fs = 48000.0
    var x = Signal.sine(frequency: 997, dBFS: -30, seconds: 1, sampleRate: fs)
    for i in 3000..<3048 { x[i] = 0.9 * sin(Float(i)) }
    x[20017] = 1
    let signal = Signal(sampleRate: fs, channels: [x])
    let throttled = try AudioMeter(sampleRate: fs, channelCount: 1)
    let eager = try AudioMeter(configuration: .init(sampleRate: fs, channelCount: 1, publishInterval: 0))
    var throttledPPM = -Float.infinity
    var eagerPPM = -Float.infinity
    var publishes = Set<UInt64>()
    throttled.feed(signal, blockSize: 16) { s in
      throttledPPM = max(throttledPPM, s[0].ppm)
      publishes.insert(s.sequence)
      // A publish lands on a call boundary at least 240 frames after the last.
      XCTAssertEqual(s.frameCount % 16, 0)
    }
    eager.feed(signal, blockSize: 16) { eagerPPM = max(eagerPPM, $0[0].ppm) }
    // 48000 / 16 calls, a publish every 15 calls (240 frames).
    XCTAssertEqual(publishes.count, 48000 / 240 + 1, accuracy: 2)
    XCTAssertEqual(throttledPPM, eagerPPM, accuracy: 1e-4, "the PPM maximum covers the whole interval")
    let a = throttled.snapshot()[0]
    let b = eager.snapshot()[0]
    XCTAssertEqual(a.clipCount, b.clipCount)
    XCTAssertEqual(a.clipCount, 1)
    XCTAssertEqual(a.truePeakMax, b.truePeakMax)
    XCTAssertEqual(a.samplePeakHold, b.samplePeakHold)
    XCTAssertEqual(a.rms, b.rms)
    XCTAssertEqual(throttled.snapshot().frameCount, 48000)

    // Pending audio is published by a zero-length call, and only then.
    var m = try AudioMeter(sampleRate: fs, channelCount: 1)
    let block = PlanarBlock(channelCount: 1, capacity: 100)
    for i in 0..<100 { block.pointers[0][i] = 0.5 }
    m.process(planar: block.pointers, frameCount: 100)
    XCTAssertEqual(m.snapshot().frameCount, 0)
    XCTAssertEqual(m.snapshot()[0].samplePeak, -.infinity)
    m.process(planar: block.pointers, frameCount: 0)
    XCTAssertEqual(m.snapshot().frameCount, 100)
    XCTAssertEqual(Double(m.snapshot()[0].samplePeak), dB(0.5), accuracy: 1e-5)

    // `flush()` does the same without a buffer, and an over in the tail
    // reaches the snapshot.
    m = try AudioMeter(sampleRate: fs, channelCount: 1)
    block.pointers[0][50] = 1
    m.process(planar: block.pointers, frameCount: 100)
    XCTAssertEqual(m.snapshot()[0].clipCount, 0)
    let sequence = m.snapshot().sequence
    m.flush()
    XCTAssertEqual(m.snapshot().sequence, sequence + 1)
    XCTAssertEqual(m.snapshot().frameCount, 100)
    XCTAssertEqual(m.snapshot()[0].clipCount, 1)
    XCTAssertEqual(Double(m.snapshot()[0].truePeakMax), 0, accuracy: 0.6)
    // Nothing pending: no publish.
    m.flush()
    XCTAssertEqual(m.snapshot().sequence, sequence + 1)
    // A pending reset is applied and published.
    m.resetPeaks()
    m.flush()
    XCTAssertEqual(m.snapshot().sequence, sequence + 3)
    XCTAssertEqual(m.snapshot()[0].clipCount, 0)
    m.flush()
    XCTAssertEqual(m.snapshot().sequence, sequence + 3)

    XCTAssertThrowsError(try AudioMeter(configuration: .init(sampleRate: fs, channelCount: 1, publishInterval: -1)))
  }
}
