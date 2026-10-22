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
    let meter = try AudioMeter(sampleRate: fs, channelCount: channels)
    // The 2x and 1x true-peak paths.
    let meter96 = try AudioMeter(sampleRate: 96000, channelCount: 3)
    let meter192 = try AudioMeter(sampleRate: 192_000, channelCount: 5)
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
        loudness.process(planar: block.pointers, frameCount: size)
        _ = meter.snapshot()
        _ = loudness.snapshot()
      }
      meter.resetPeaks()
      meter.resetLoudness()
      _ = meter.snapshot()
      _ = meter.publishCount
      meter.process(planar: block.pointers, frameCount: 100)
      meter.reset()
      loudness.reset()
      _ = loudness.snapshot()
      meter.process(planar: block.pointers, frameCount: 0)
      meter.process(planar: block.pointers, frameCount: 100)
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
  /// disagree, or a frame count that does not match the sequence.
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
      if s.frameCount != s.sequence * UInt64(blockFrames) { torn += 1 }
      for c in 1..<channels where s[c] != s[0] { torn += 1 }
      if s.channelCount != channels { torn += 1 }
    }
    XCTAssertEqual(torn, 0, "inconsistent snapshots in \(reads) reads")
    XCTAssertEqual(meter.snapshot().sequence, UInt64(blocks))
    XCTAssertGreaterThan(reads, 1000)
  }

  /// A reset shows in `snapshot()` and moves `publishCount` at once, even
  /// with the audio stopped; a zero-length `process` applies and publishes it.
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
    m.resetPeaks()
    XCTAssertNotEqual(m.publishCount, count)
    var s = m.snapshot()
    for c in 0..<2 {
      XCTAssertEqual(s[c].clipCount, 0)
      XCTAssertEqual(s[c].truePeakMax, -.infinity)
      XCTAssertEqual(s[c].samplePeakHold, s[c].samplePeak)
      XCTAssertEqual(s[c].truePeakHold, s[c].truePeak)
      XCTAssertEqual(s[c].rms, before[c].rms)
    }
    XCTAssertEqual(s.loudness, before.loudness)

    count = m.publishCount
    m.resetLoudness()
    XCTAssertNotEqual(m.publishCount, count)
    s = m.snapshot()
    XCTAssertEqual(s.loudness, LoudnessSnapshot())
    XCTAssertEqual(s[0].clipCount, 0)

    // The producer applies both on a zero-length call and publishes.
    let sequence = s.sequence
    m.process(planar: PlanarBlock(channelCount: 2, capacity: 1).pointers, frameCount: 0)
    s = m.snapshot()
    XCTAssertEqual(s.sequence, sequence + 1)
    XCTAssertEqual(s[0].clipCount, 0)
    XCTAssertEqual(s[0].truePeakMax, -.infinity)
    XCTAssertEqual(s.loudness, LoudnessSnapshot())
    // Without a request a zero-length call publishes nothing.
    m.process(planar: PlanarBlock(channelCount: 2, capacity: 1).pointers, frameCount: 0)
    XCTAssertEqual(m.snapshot().sequence, sequence + 1)

    m.reset()
    s = m.snapshot()
    XCTAssertEqual(s.frameCount, 0)
    for c in 0..<2 { XCTAssertEqual(s[c], AudioChannelLevels()) }
    m.process(planar: PlanarBlock(channelCount: 2, capacity: 1).pointers, frameCount: 0)
    s = m.snapshot()
    XCTAssertEqual(s.sequence, sequence + 2)
    for c in 0..<2 { XCTAssertEqual(s[c], AudioChannelLevels()) }

    let l = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    l.feed(.tone(dBFS: -20, seconds: 1, sampleRate: fs))
    XCTAssertTrue(l.snapshot().momentary.isFinite)
    count = l.publishCount
    l.resetMeasurement()
    XCTAssertNotEqual(l.publishCount, count)
    XCTAssertEqual(l.snapshot(), LoudnessSnapshot())
    l.process(planar: PlanarBlock(channelCount: 2, capacity: 1).pointers, frameCount: 0)
    XCTAssertEqual(l.snapshot(), LoudnessSnapshot())
    l.feed(.tone(dBFS: -20, seconds: 0.5, sampleRate: fs))
    XCTAssertTrue(l.snapshot().momentary.isFinite)
  }

  /// CPU time per 1024-frame block, every meter on, 16 channels at 48, 96
  /// and 192 kHz (the 4x, 2x and 1x true-peak paths). Release numbers are
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
    var shares: [Double] = []
    for fs in [48000.0, 96000, 192_000] {
      let all = try AudioMeter(sampleRate: fs, channelCount: channels)
      shares.append(measure("AudioMeter 16ch all meters at \(Int(fs / 1000)) kHz", sampleRate: fs) {
        all.process(planar: block.pointers, frameCount: frames)
      })
    }
    let all = try AudioMeter(sampleRate: 48000, channelCount: channels)
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
    let loud = try LoudnessMeter(sampleRate: 48000, channelCount: channels)
    _ = measure("LoudnessMeter 16ch") { loud.process(planar: block.pointers, frameCount: frames) }
    let stereo = try AudioMeter(sampleRate: 48000, channelCount: 2)
    _ = measure("AudioMeter 2ch all meters") { stereo.process(planar: block.pointers, frameCount: frames) }
    _ = measure("snapshot() read") { _ = all.snapshot() }
    #if DEBUG
      // Measured on an M4 Max: 1.0, 1.9 and 3.5 % of a core at 48, 96 and
      // 192 kHz, 2.0 % for constant input (release: 0.31, 0.52, 0.86, 0.42).
      // The bounds leave about 3x for a loaded machine.
      for (share, bound) in zip(shares + [constant], [0.04, 0.06, 0.10, 0.06]) {
        XCTAssertLessThan(share, bound, "debug build: all meters on 16 channels")
      }
    #else
      for share in shares { XCTAssertLessThan(share, 0.01, "all meters on 16 channels must stay under 1 % of a core") }
      XCTAssertLessThan(constant, 0.01, "the PPM's always-charging case must stay under 1 % of a core")
    #endif
  }
}
