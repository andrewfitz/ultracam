import AVFoundation
import Darwin
import Foundation
import MonitorKitAudio
import Synchronization
import XCTest

/// Counts heap allocations made on one thread, through libmalloc's
/// `malloc_logger` hook (the one MallocStackLogging uses).
enum AllocationCounter {
  typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
  static let count = Atomic<Int>(0)
  static let thread = Atomic<UInt>(0)
  static let logger: Logger = { type, _, _, _, _, _ in
    // stack_logging_type_alloc; realloc reports alloc | dealloc.
    guard type & 2 != 0 else { return }
    if AllocationCounter.thread.load(ordering: .relaxed) == UInt(bitPattern: pthread_self()) {
      AllocationCounter.count.add(1, ordering: .relaxed)
    }
  }

  /// nil when the hook is unavailable.
  static func allocations(_ body: () -> Void) -> Int? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
    let slot = symbol.assumingMemoryBound(to: Logger?.self)
    // Touch the statics first so their lazy initialization does not run inside the hook.
    _ = logger
    count.store(0, ordering: .relaxed)
    thread.store(UInt(bitPattern: pthread_self()), ordering: .relaxed)
    let previous = slot.pointee
    slot.pointee = logger
    body()
    slot.pointee = previous
    thread.store(0, ordering: .relaxed)
    return count.load(ordering: .relaxed)
  }
}

final class RealtimeTests: XCTestCase {
  func testAllocationCounterSeesAllocations() throws {
    let n = try XCTUnwrap(AllocationCounter.allocations {
      let a = [Int](repeating: 1, count: Int.random(in: 1000...2000))
      XCTAssertGreaterThan(a.count, 0)
    }, "malloc_logger unavailable")
    XCTAssertGreaterThan(n, 0)
  }

  func testProcessDoesNotAllocate() throws {
    guard AllocationCounter.allocations({ _ = [Int](repeating: 1, count: Int.random(in: 1000...2000)) }) ?? 0 > 0 else {
      throw XCTSkip("malloc_logger is not honoured on this system")
    }
    let fs = 48000.0
    let channels = 16
    // Loudness over every channel, so the K-weighting runs on all 16.
    let meter = try AudioMeter(configuration: .init(
      sampleRate: fs, channelCount: channels, loudnessChannels: Array(repeating: .weighted(1), count: channels)))
    // 2x true peak with the phases, then the samples, as the PPM's input;
    // a fold of 4 (768 kHz); every call publishing with a 60 s RMS window.
    let meter96 = try AudioMeter(sampleRate: 96000, channelCount: 3)
    let meter192 = try AudioMeter(sampleRate: 192_000, channelCount: 5)
    let meter768 = try AudioMeter(sampleRate: 768_000, channelCount: 4)
    let eager = try AudioMeter(configuration: .init(sampleRate: fs, channelCount: 2, rmsWindow: 60, publishInterval: 0))
    let loudness = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    let frames = 4096
    let block = PlanarBlock(channelCount: channels, capacity: frames)
    for c in 0..<channels {
      let x = Signal.noise(amplitude: 0.5, frames: frames, seed: UInt64(c))
      for i in 0..<frames { block.pointers[c][i] = x[i] }
    }
    let interleaved16 = [Int16](repeating: 1000, count: frames * channels)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fs, channels: 2, interleaved: true)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    pcm.frameLength = AVAudioFrameCount(frames)
    let list = pcm.audioBufferList
    // A buffer without data in front of a real one.
    let partial = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(partial.unsafeMutablePointer) }
    partial[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
    partial[1] = AudioBuffer(
      mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(block.pointers[0]))

    // The harness itself must not allocate either: no array literals or
    // Range loops inside (unoptimized Range iteration allocates per step).
    let sizes = [1, 64, 256, 333, 1024, 4096]
    func exercise() {
      var k = 0
      while k < sizes.count {
        let size = sizes[k]
        k += 1
        meter.process(planar: block.pointers, frameCount: size)
        interleaved16.withUnsafeBufferPointer { meter.process(interleaved: $0.baseAddress!, frameCount: size) }
        meter.process(bufferList: list, frameCount: size, format: .float32)
        meter.process(bufferList: partial.unsafePointer, frameCount: size, format: .float32)
        meter96.process(planar: block.pointers, frameCount: size)
        meter192.process(planar: block.pointers, frameCount: size)
        meter768.process(planar: block.pointers, frameCount: size)
        eager.process(planar: block.pointers, frameCount: size)
        loudness.process(planar: block.pointers, frameCount: size)
        _ = meter.snapshot()
        _ = loudness.snapshot()
      }
      meter.resetPeaks()
      meter.resetLoudness()
      _ = meter.snapshot()
      _ = meter.publishCount
      meter.pauseLoudness()
      loudness.pauseMeasurement()
      meter.process(planar: block.pointers, frameCount: 300)
      loudness.process(planar: block.pointers, frameCount: 300)
      meter.resumeLoudness()
      loudness.resumeMeasurement()
      eager.reset()
      meter.process(planar: block.pointers, frameCount: 100)
      meter.reset()
      loudness.reset()
      _ = loudness.snapshot()
      meter.process(planar: block.pointers, frameCount: 0)
      meter.process(planar: block.pointers, frameCount: 100)
      meter.flush()
      meter.resetLoudness()
      meter.flush()
      loudness.resetMeasurement()
      loudness.process(planar: block.pointers, frameCount: 100)
    }
    // Run long enough to fill the loudness histograms and rings.
    for _ in 0..<40 { exercise() }
    let n = try XCTUnwrap(AllocationCounter.allocations {
      var i = 0
      while i < 20 {
        exercise()
        i += 1
      }
    })
    XCTAssertEqual(n, 0, "heap allocations on the audio path")
  }

  /// A reader hammers `snapshot()` while the producer publishes. Every
  /// channel gets the same signal, so a torn read shows up as channels that
  /// disagree, or a frame count that does not match the sequence. 128-frame
  /// calls with the 240-frame (5 ms) publish interval publish every second call.
  func testSnapshotsStayConsistentUnderConcurrentReader() throws {
    let fs = 48000.0
    let channels = 8
    let blockFrames = 128
    let meter = try AudioMeter(sampleRate: fs, channelCount: channels)
    let blocks = 3000
    let done = Atomic<Bool>(false)
    let source = (0..<(blockFrames * 64)).map { i in Float(0.9 * sin(Double(i) * 0.05) * (0.5 + 0.5 * sin(Double(i) * 0.0003))) }

    let writer = Thread {
      let block = PlanarBlock(channelCount: channels, capacity: blockFrames)
      for b in 0..<blocks {
        let start = (b % 64) * blockFrames
        for c in 0..<channels {
          for i in 0..<blockFrames { block.pointers[c][i] = source[start + i] }
        }
        meter.process(planar: block.pointers, frameCount: blockFrames)
      }
      done.store(true, ordering: .releasing)
    }
    writer.start()

    var reads = 0
    var torn = 0
    var lastSequence: UInt64 = 0
    while !done.load(ordering: .acquiring) || reads < 1000 {
      let s = meter.snapshot()
      reads += 1
      if s.sequence < lastSequence { torn += 1 }
      lastSequence = s.sequence
      if s.frameCount != s.sequence * UInt64(2 * blockFrames) { torn += 1 }
      for c in 1..<channels where s[c] != s[0] { torn += 1 }
      if s.channelCount != channels { torn += 1 }
    }
    XCTAssertEqual(torn, 0, "inconsistent snapshots in \(reads) reads")
    XCTAssertEqual(meter.snapshot().sequence, UInt64(blocks / 2))
    XCTAssertGreaterThan(reads, 1000)
  }

  /// A reset shows in `snapshot()` and moves `publishCount` and `sequence`
  /// at once, even with the audio stopped; a zero-length `process` applies
  /// and publishes it.
  func testResetsShowWhileAudioIsStopped() throws {
    let fs = 48000.0
    let m = try AudioMeter(sampleRate: fs, channelCount: 2)
    var x = Signal.sine(frequency: 1000, dBFS: -10, seconds: 4, sampleRate: fs)
    x[1000] = 1
    m.feed(Signal(sampleRate: fs, channels: [x, x]))
    let before = m.snapshot()
    XCTAssertEqual(before[0].clipCount, 1)
    XCTAssertTrue(before.loudness.integrated.isFinite)

    var count = m.publishCount
    var sequence = m.snapshot().sequence
    m.resetPeaks()
    XCTAssertNotEqual(m.publishCount, count)
    var s = m.snapshot()
    // A view caching by sequence redraws.
    XCTAssertGreaterThan(s.sequence, sequence)
    for c in 0..<2 {
      XCTAssertEqual(s[c].clipCount, 0)
      XCTAssertEqual(s[c].truePeakMax, -.infinity)
      XCTAssertEqual(s[c].samplePeakHold, s[c].samplePeak)
      XCTAssertEqual(s[c].truePeakHold, s[c].truePeak)
      XCTAssertEqual(s[c].rms, before[c].rms)
    }
    XCTAssertEqual(s.loudness, before.loudness)

    count = m.publishCount
    sequence = s.sequence
    m.resetLoudness()
    XCTAssertNotEqual(m.publishCount, count)
    s = m.snapshot()
    XCTAssertGreaterThan(s.sequence, sequence)
    // The measurement starts over; the sliding windows carry on.
    let restarted = LoudnessSnapshot(momentary: before.loudness.momentary, shortTerm: before.loudness.shortTerm)
    XCTAssertTrue(restarted.momentary.isFinite)
    XCTAssertEqual(s.loudness, restarted)
    XCTAssertEqual(s[0].clipCount, 0)

    // The producer applies both on a zero-length call and publishes; what a
    // reader sees stays the same and its sequence moves on.
    sequence = s.sequence
    let empty = PlanarBlock(channelCount: 2, capacity: 1)
    m.process(planar: empty.pointers, frameCount: 0)
    s = m.snapshot()
    XCTAssertEqual(s.sequence, sequence + 1)
    XCTAssertEqual(s[0].clipCount, 0)
    XCTAssertEqual(s[0].truePeakMax, -.infinity)
    XCTAssertEqual(s.loudness, restarted)
    // With nothing requested or pending a zero-length call publishes nothing.
    m.process(planar: empty.pointers, frameCount: 0)
    XCTAssertEqual(m.snapshot().sequence, sequence + 1)

    m.reset()
    s = m.snapshot()
    XCTAssertEqual(s.sequence, sequence + 2)
    XCTAssertEqual(s.frameCount, 0)
    for c in 0..<2 { XCTAssertEqual(s[c], AudioChannelLevels()) }
    XCTAssertEqual(s.loudness, LoudnessSnapshot(), "a full reset clears the windows too")
    m.process(planar: empty.pointers, frameCount: 0)
    s = m.snapshot()
    XCTAssertEqual(s.sequence, sequence + 3)
    for c in 0..<2 { XCTAssertEqual(s[c], AudioChannelLevels()) }
    XCTAssertEqual(s.loudness, LoudnessSnapshot())

    let l = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    l.feed(.tone(dBFS: -20, seconds: 1, sampleRate: fs))
    XCTAssertTrue(l.snapshot().momentary.isFinite)
    let measured = l.snapshot()
    count = l.publishCount
    l.resetMeasurement()
    XCTAssertNotEqual(l.publishCount, count)
    XCTAssertEqual(l.snapshot(), measured.startingOver)
    l.process(planar: empty.pointers, frameCount: 0)
    XCTAssertEqual(l.snapshot(), measured.startingOver)
    l.feed(.tone(dBFS: -20, seconds: 0.5, sampleRate: fs))
    XCTAssertTrue(l.snapshot().momentary.isFinite)
    l.reset()
    XCTAssertEqual(l.snapshot(), LoudnessSnapshot())
    l.process(planar: empty.pointers, frameCount: 0)
    XCTAssertEqual(l.snapshot(), LoudnessSnapshot())
  }

  /// A reset never disappears again once requested: the producer runs long
  /// calls back to back while a reader injects a clip, waits for it, resets
  /// and checks every snapshot until the reset has certainly been published.
  /// With a request flag cleared when `process` starts (and the reset
  /// published only when it ends), the old clip count came back in every trial.
  func testResetNeverReappearsWhileProcessRuns() throws {
    let fs = 48000.0
    let channels = 16
    let frames = 4096
    let meter = try AudioMeter(sampleRate: fs, channelCount: channels)
    let loudness = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    let clip = Atomic<Bool>(false)
    let done = Atomic<Bool>(false)
    let writer = Thread {
      let block = PlanarBlock(channelCount: channels, capacity: frames)
      for c in 0..<channels {
        let x = Signal.sine(frequency: 1000 + 100 * Double(c), dBFS: -20, seconds: Double(frames) / fs, sampleRate: fs)
        for i in 0..<frames { block.pointers[c][i] = x[i] }
      }
      while !done.load(ordering: .acquiring) {
        block.pointers[0][100] = clip.exchange(false, ordering: .acquiring) ? 1 : 0
        meter.process(planar: block.pointers, frameCount: frames)
        loudness.process(planar: block.pointers, frameCount: frames)
      }
    }
    writer.start()
    defer { done.store(true, ordering: .releasing) }

    var reappeared = 0
    var loudnessReappeared = 0
    var reads = 0
    for _ in 0..<100 {
      clip.store(true, ordering: .releasing)
      while meter.snapshot()[0].clipCount == 0 {}
      while !(loudness.snapshot().duration > 0.5) {}
      meter.resetPeaks()
      loudness.resetMeasurement()
      // Three more publishes: the reset's own and two after it.
      let target = meter.publishCount + 3
      // The loudness meter publishes once per call, like the level meter here.
      let loudnessTarget = loudness.publishCount + 3
      while meter.publishCount < target || loudness.publishCount < loudnessTarget {
        if meter.snapshot()[0].clipCount != 0 { reappeared += 1 }
        // A fresh measurement is at most ~3 calls (0.26 s) old here.
        if loudness.snapshot().duration > 0.4 { loudnessReappeared += 1 }
        reads += 1
      }
    }
    XCTAssertEqual(reappeared, 0, "the old clip count came back after a reset (\(reads) reads)")
    XCTAssertEqual(loudnessReappeared, 0, "the old loudness came back after a reset (\(reads) reads)")
  }

  /// CPU time per 1024-frame block, every meter on, 16 channels at 48, 96,
  /// 192 and 768 kHz (4x phases, 2x phases, 2x with the samples as the PPM's
  /// input, a fold of 4), and the cost of small callbacks. Release numbers are
  /// what the plan's budget is about (`swift test -c release`); a debug host
  /// build gets its own, looser bound because it links this package
  /// unoptimized.
  func testBenchmarkSixteenChannels() throws {
    let frames = 1024
    let channels = 16
    let block = PlanarBlock(channelCount: channels, capacity: frames)
    for c in 0..<channels {
      let x = Signal.noise(amplitude: 0.3, frames: frames, seed: UInt64(c + 100))
      for i in 0..<frames { block.pointers[c][i] = x[i] }
    }
    func measure(_ label: String, sampleRate fs: Double = 48000, _ body: () -> Void) -> Double {
      for _ in 0..<20 { body() }
      var best = Double.infinity
      // Best of several runs: other work on the machine only ever adds time.
      #if DEBUG
        let (runs, iterations) = (5, 20)
      #else
        let (runs, iterations) = (15, 200)
      #endif
      for _ in 0..<runs {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for _ in 0..<iterations { body() }
        let elapsed = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / Double(iterations)
        best = min(best, elapsed)
      }
      let budget = Double(frames) / fs * 1e9
      print(String(format: "AudioBenchmark %@: %.2f us per 1024-frame block, %.4f %% of one core", label, best / 1000, 100 * best / budget))
      return best / budget
    }
    // Loudness over all 16 channels, the worst case (the default layout
    // measures only the first pair).
    func everything(_ fs: Double, rmsWindow: Double = 0.3) throws -> AudioMeter {
      try AudioMeter(configuration: .init(
        sampleRate: fs, channelCount: channels, rmsWindow: rmsWindow,
        loudnessChannels: Array(repeating: .weighted(1), count: channels)))
    }
    var shares: [Double] = []
    let rates = [48000.0, 96000, 192_000, 768_000]
    for fs in rates {
      let all = try everything(fs)
      shares.append(measure("AudioMeter 16ch all meters at \(Int(fs / 1000)) kHz", sampleRate: fs) {
        all.process(planar: block.pointers, frameCount: frames)
      })
    }
    let all = try everything(48000)
    // Constant input charges the PPM on every sample: its slowest case.
    let interleaved = [Float](repeating: 0.25, count: frames * channels)
    let constant = measure("AudioMeter 16ch all meters, interleaved constant input") {
      interleaved.withUnsafeBufferPointer { all.process(interleaved: $0.baseAddress!, frameCount: frames) }
    }
    let peaks = try AudioMeter(configuration: .init(sampleRate: 48000, channelCount: channels, meters: [.samplePeak, .truePeak]))
    _ = measure("AudioMeter 16ch sample+true peak") { peaks.process(planar: block.pointers, frameCount: frames) }
    let noFIR = try AudioMeter(configuration: .init(sampleRate: 48000, channelCount: channels, meters: [.samplePeak, .rms, .vu]))
    _ = measure("AudioMeter 16ch peak+RMS+VU") { noFIR.process(planar: block.pointers, frameCount: frames) }
    let ppmOnly = try AudioMeter(configuration: .init(sampleRate: 48000, channelCount: channels, meters: [.ppm]))
    _ = measure("AudioMeter 16ch PPM") { ppmOnly.process(planar: block.pointers, frameCount: frames) }
    let loud = try LoudnessMeter(sampleRate: 48000, channels: Array(repeating: .weighted(1), count: channels))
    _ = measure("LoudnessMeter 16ch") { loud.process(planar: block.pointers, frameCount: frames) }
    let stereo = try AudioMeter(sampleRate: 48000, channelCount: 2)
    _ = measure("AudioMeter 2ch all meters") { stereo.process(planar: block.pointers, frameCount: frames) }
    _ = measure("snapshot() read") { _ = all.snapshot() }
    // Small callbacks: the fixed cost per call, publishing once per 5 ms.
    for size in [16, 64] {
      let small = try everything(48000)
      _ = measure("AudioMeter 16ch all meters in \(size)-frame calls") {
        var offset = 0
        while offset < frames {
          small.process(planar: block.pointers, frameCount: size)
          offset += size
        }
      }
    }
    let longWindow = try everything(48000, rmsWindow: 60)
    _ = measure("AudioMeter 16ch all meters, 60 s RMS window, 32-frame calls") {
      var offset = 0
      while offset < frames {
        longWindow.process(planar: block.pointers, frameCount: 32)
        offset += 32
      }
    }

    // CPU time is only a fair budget check on an idle performance core; on
    // CI (slower, shared cores, E-cores) the numbers are printed without
    // asserting unless MONITORKIT_ASSERT_TIMING=1.
    let environment = ProcessInfo.processInfo.environment
    guard environment["CI"] == nil || environment["MONITORKIT_ASSERT_TIMING"] == "1" else { return }
    // The plan's budget ("well under 1 % of a core") is a 48 kHz figure. The
    // K-weighting runs at the full rate (BS.1770 weights the whole band) and
    // so does the true-peak FIR, so other rates get the bound scaled by fs / 48 kHz.
    #if DEBUG
      // A host linking the package unoptimized; about 3x for a loaded machine.
      let budget = 0.04
    #else
      // About 3x the M4 Max's 48 kHz figure.
      let budget = 0.01
    #endif
    for (share, fs) in zip(shares, rates) {
      XCTAssertLessThan(share, budget * fs / 48000, "all meters on 16 channels at \(fs)")
    }
    XCTAssertLessThan(constant, budget * 1.5, "the PPM's always-charging case")
  }

}
