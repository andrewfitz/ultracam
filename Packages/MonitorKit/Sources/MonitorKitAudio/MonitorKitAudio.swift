import Foundation

// MonitorKitAudio: broadcast audio meters on the host's audio thread.
//
// Realtime contract shared by `AudioMeter` and `LoudnessMeter`:
// - Everything is allocated at init. `process` makes no heap allocation, takes
//   no lock, uses no Swift concurrency and no Objective-C.
// - One producer: `process` is called from one thread at a time (the audio
//   thread). `snapshot()` and the `reset` requests are safe from any thread at
//   any time; they never block the producer.
// - Snapshots are published lock-free (a sequence lock over atomic words), so a
//   reader always sees one consistent set of readings.

/// The largest channel count a meter accepts (two 8-pair SDI groups).
public let audioMeterMaximumChannelCount = 16

@inline(__always) func amplitudeDB(_ value: Double) -> Float {
  value > 0 ? Float(20 * log10(value)) : -.infinity
}

/// BS.1770-4 eq. 2: loudness from the channel-weighted mean square.
@inline(__always) func loudnessLUFS(_ weightedMeanSquare: Double) -> Float {
  weightedMeanSquare > 0 ? Float(-0.691 + 10 * log10(weightedMeanSquare)) : -.infinity
}

/// `for i in 0..<count` for the realtime path. In unoptimized builds Range
/// iteration heap-allocates on every step (measured with Swift 6.4); this
/// while loop does not, so debug builds of a host stay allocation-free too.
@inline(__always) func forEachIndex(_ count: Int, _ body: (Int) -> Void) {
  var i = 0
  while i < count {
    body(i)
    i += 1
  }
}
