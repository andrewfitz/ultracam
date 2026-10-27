import CoreMedia

struct FrameRateGate {
  private var last: CMTime = .invalid
  private var next: CMTime = .invalid
  private var lastDuration: CMTime = .invalid

  mutating func reset() {
    last = .invalid
    next = .invalid
    lastDuration = .invalid
  }

  mutating func shouldDeliver(_ pts: CMTime, duration: CMTime) -> Bool {
    // A gate is a timing boundary, so reject clocks it cannot compare. In
    // particular, an indefinite duration previously made the threshold NaN
    // and allowed every frame through while an epoch-bearing PTS could poison
    // the next source generation.
    let durationSeconds = duration.seconds
    guard pts.isValid, pts.isNumeric, pts.epoch == 0,
      duration.isValid, duration.isNumeric, duration.epoch == 0,
      durationSeconds.isFinite, durationSeconds > 0 else { return false }
    if last.isValid, lastDuration.isValid, CMTimeCompare(lastDuration, duration) != 0 {
      // Callers normally reset on a source-rate change. Keeping this local
      // makes the gate safe for direct users and prevents one old-rate frame
      // from suppressing the first frame of a new cadence.
      last = .invalid
    }
    if last.isValid {
      let ordering = CMTimeCompare(pts, last)
      if ordering == 0 {
        // A duplicate timestamp is never a new video frame.
        return false
      }
      if ordering > 0 {
        let delta = CMTimeSubtract(pts, last)
        // A valid CMTime subtraction can still overflow for extreme values.
        // Refuse to publish when the cadence cannot be represented reliably.
        guard delta.isValid, delta.isNumeric, delta.epoch == 0 else { return false }
        guard delta.seconds.isFinite else { return false }
        // Keep a target-clock phase instead of restarting the interval at each
        // selected source frame. Ratios such as 59.94 → 24 need alternating
        // source-frame intervals; restarting would incorrectly yield 19.98.
        let tolerance = durationSeconds * 0.1
        guard next.isNumeric, next.seconds.isFinite else { return false }
        let lateness = CMTimeSubtract(pts, next)
        guard lateness.isNumeric, lateness.seconds.isFinite else { return false }
        if lateness.seconds < -tolerance { return false }
        let steps = max(1, floor((lateness.seconds + tolerance) / durationSeconds) + 1)
        if steps < Double(Int32.max) {
          next = CMTimeAdd(next, CMTimeMultiply(duration, multiplier: Int32(steps)))
        } else {
          next = CMTimeAdd(pts, duration)
        }
        last = pts
        lastDuration = duration
        return true
      }
      // A backwards source clock re-anchors the gate at the new generation.
    }
    next = CMTimeAdd(pts, duration)
    last = pts
    lastDuration = duration
    return true
  }
}
