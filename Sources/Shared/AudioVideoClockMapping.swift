import CoreMedia

/// Composes independently anchored audio and video clocks through their common
/// host clock.  No origin is synthesized: both mappings must carry explicit
/// anchors supplied by the capture source.
struct AudioVideoClockMapping: Sendable, Hashable {
  let audio: ClockMapping
  let video: ClockMapping

  init(audio: ClockMapping, video: ClockMapping) throws {
    guard audio.hostAnchor.isNumeric, video.hostAnchor.isNumeric,
      audio.hostAnchor.epoch == video.hostAnchor.epoch else {
      throw SourceFormatError.invalid("Audio and video mappings require a common host clock epoch")
    }
    self.audio = audio
    self.video = video
  }

  /// Places an audio-clock timestamp on the video clock: A -> host -> V⁻¹.
  func videoTime(forAudioTime audioTime: CMTime) throws -> CMTime {
    let host = try audio.hostTime(for: audioTime)
    let delta = CMTimeSubtract(host, video.hostAnchor)
    let scale = Double(video.rate.denominator) / Double(video.rate.numerator)
    let result = CMTimeAdd(video.sourceAnchor, CMTimeMultiplyByFloat64(delta, multiplier: scale))
    guard result.isNumeric, result.epoch == video.sourceAnchor.epoch else {
      throw SourceFormatError.invalid("Composed audio/video time is invalid")
    }
    return result
  }

  func hostTime(forAudioTime audioTime: CMTime) throws -> CMTime {
    try audio.hostTime(for: audioTime)
  }

  /// Video-clock seconds represented by one audio-clock second.
  var audioToVideoRate: Double {
    (Double(audio.rate.numerator) / Double(audio.rate.denominator)) /
      (Double(video.rate.numerator) / Double(video.rate.denominator))
  }

  /// Returns the exact (fractional) source sample count for a duration.
  func audioSamples(forVideoDuration duration: CMTime, sampleRate: Double) throws -> Double {
    guard duration.isNumeric, duration.epoch == 0, duration.seconds >= 0,
      sampleRate.isFinite, sampleRate > 0 else {
      throw SourceFormatError.invalid("Invalid duration or sample rate")
    }
    return duration.seconds * sampleRate / audioToVideoRate
  }
}
