import Foundation
import MonitorKitAudio
import XCTest

/// `AudioMeter.restart()` and `noteDiscontinuity()` (and `LoudnessMeter`'s): a
/// break in the input restarts the filters' signal memory from the new audio's
/// first sample instead of interpolating or K-weighting across stale samples.
final class DiscontinuityTests: XCTestCase {
  let fs = 48000.0

  /// A stretch ending on a positive crest and one starting on a negative trough:
  /// joined without a break, the interpolator rings across the step between them.
  func stretches() -> (a: Signal, b: Signal) {
    // 997 Hz, 0.25 s, the last sample at the positive crest.
    let n = 12_000
    let w = 2 * Double.pi * 997 / fs
    let amp = Signal.amplitude(-3)
    let a = (0..<n).map { Float(amp * sin(w * Double($0 - n + 1) + Double.pi / 2)) }
    let b = (0..<n).map { Float(-amp * cos(w * Double($0))) }
    return (Signal(sampleRate: fs, channels: [a, a]), Signal(sampleRate: fs, channels: [b, b]))
  }

  func meter() throws -> AudioMeter {
    try AudioMeter(configuration: .init(sampleRate: fs, channelCount: 2, publishInterval: 0))
  }

  /// After `noteDiscontinuity()` the true-peak reading of the new audio is what a
  /// fresh meter reads for it alone; joined without the note, the step reads
  /// higher than either stretch (an inter-sample peak that was never there).
  func testDiscontinuityKeepsTheTruePeakOfEachStretch() throws {
    let (a, b) = stretches()
    let alone = (try meter(), try meter())
    alone.0.feed(a, blockSize: 480)
    alone.1.feed(b, blockSize: 480)
    let expected = max(alone.0.snapshot().channels[0].truePeakMax, alone.1.snapshot().channels[0].truePeakMax)

    let noted = try meter()
    noted.feed(a, blockSize: 480)
    noted.noteDiscontinuity()
    noted.feed(b, blockSize: 480)
    XCTAssertEqual(noted.snapshot().channels[0].truePeakMax, expected, "each stretch as a fresh meter reads it")

    let joined = try meter()
    joined.feed(a, blockSize: 480)
    joined.feed(b, blockSize: 480)
    XCTAssertGreaterThan(
      joined.snapshot().channels[0].truePeakMax, expected + 0.5, "the control: the step overshoots without the note")
  }

  /// The note changes no reading: the snapshot, its sequence and the publish
  /// count stay as they were, and holds and loudness carry on over the break.
  func testDiscontinuityKeepsEveryReading() throws {
    let (a, b) = stretches()
    let m = try meter()
    m.feed(a, blockSize: 480)
    let before = m.snapshot()
    let published = m.publishCount
    m.noteDiscontinuity()
    XCTAssertEqual(m.snapshot().sequence, before.sequence)
    XCTAssertEqual(m.publishCount, published)
    m.flush()
    XCTAssertEqual(m.publishCount, published, "a pending note alone publishes nothing")
    m.feed(b, blockSize: 480)
    let after = m.snapshot()
    XCTAssertEqual(after.frameCount, UInt64(a.frameCount + b.frameCount))
    XCTAssertEqual(after.loudness.duration, Double(a.frameCount + b.frameCount) / fs, accuracy: 0.011)
    XCTAssertGreaterThanOrEqual(after.channels[0].samplePeakHold, before.channels[0].samplePeakHold - 1e-6)
  }

  /// The K-weighting restarts as if the signal had held the new audio's first
  /// sample: a constant after the break has no K-weighted energy at all (the
  /// RLB high-pass passes nothing at DC), where zeros or the old memory would
  /// put a step and its decay into momentary loudness.
  func testDiscontinuityStartsTheKWeightingWithoutAStep() throws {
    let tone = Signal.tone(dBFS: -20, seconds: 1, sampleRate: fs)
    let dc = Signal(sampleRate: fs, channels: Array(repeating: Array(repeating: Float(0.5), count: 19_200), count: 2))
    for primed in [true, false] {
      let level = try meter()
      let loudness = try LoudnessMeter(sampleRate: fs, channelCount: 2)
      level.feed(tone, blockSize: 480)
      loudness.feed(tone, blockSize: 480)
      if primed {
        level.noteDiscontinuity()
        loudness.noteDiscontinuity()
      }
      level.feed(dc, blockSize: 480)
      loudness.feed(dc, blockSize: 480)
      // 400 ms of the constant: the momentary window holds exactly it, the step included.
      let m = (level.snapshot().loudness.momentary, loudness.snapshot().momentary)
      if primed {
        XCTAssertLessThan(m.0, -150, "AudioMeter")
        XCTAssertLessThan(m.1, -150, "LoudnessMeter")
      } else {
        XCTAssertGreaterThan(m.0, -60, "the control: the step's decay reads")
        XCTAssertGreaterThan(m.1, -60, "the control: the step's decay reads")
      }
    }
  }

  /// `restart()` is `reset()` plus a discontinuity: after it, a stream that
  /// starts from 0 reads exactly what a new meter reads for it.
  func testRestartReadsLikeANewMeter() throws {
    let (a, _) = stretches()
    let tone = Signal.tone(dBFS: -12, seconds: 1, sampleRate: fs)
    XCTAssertEqual(tone.channels[0][0], 0)
    let fresh = try meter()
    fresh.feed(tone, blockSize: 480)
    let restarted = try meter()
    restarted.feed(a, blockSize: 480)
    let sequence = restarted.snapshot().sequence
    restarted.restart()
    XCTAssertNotEqual(restarted.snapshot().sequence, sequence, "a restart is a reset: the sequence moves")
    XCTAssertEqual(restarted.snapshot().channels[0].truePeakMax, -.infinity, "and shows at once")
    restarted.feed(tone, blockSize: 480)
    let x = restarted.snapshot(), y = fresh.snapshot()
    XCTAssertEqual(x.frameCount, y.frameCount)
    XCTAssertEqual(x.loudness, y.loudness)
    for c in 0..<2 { XCTAssertEqual(x.channels[c], y.channels[c], "channel \(c)") }

    // A plain reset keeps the memory, so the old crest's ring is still in it.
    let reset = try meter()
    reset.feed(a, blockSize: 480)
    reset.reset()
    reset.feed(tone, blockSize: 480)
    XCTAssertNotEqual(reset.snapshot().loudness, y.loudness, "the control: reset() keeps the K-weighting's memory")
  }

  /// Notes and restarts from another thread are generations, like resets: none
  /// is lost, and processing after one allocates nothing.
  func testDiscontinuityAllocatesNothing() throws {
    let m = try meter()
    let block = PlanarBlock(channelCount: 2, capacity: 480)
    let tone = Signal.tone(dBFS: -20, seconds: 0.01, sampleRate: fs)
    block.fill(from: tone, offset: 0, count: 480)
    m.process(planar: block.pointers, frameCount: 480)
    func count(_ label: String, _ request: () -> Void) {
      let n = AllocationCounter.allocations {
        var i = 0
        while i < 10 {
          request()
          m.process(planar: block.pointers, frameCount: 480)
          i += 1
        }
      }
      if let n { XCTAssertEqual(n, 0, label) }
    }
    count("plain") {}
    count("reset") { m.reset() }
    count("discontinuity") { m.noteDiscontinuity() }
    count("restart") { m.restart() }
  }
}
