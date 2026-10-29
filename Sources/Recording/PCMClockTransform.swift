import CoreMedia

/// A paired source supplies a measured audio/video correspondence directly;
/// it never needs invented host anchors. Independent clocks require mappings.
enum PCMClockTransform {
  case mapped(AudioVideoClockMapping)
  case paired(audioAnchor: CMTime, videoAnchor: CMTime)

  var audioToVideoRate: Double {
    switch self { case .mapped(let mapping): return mapping.audioToVideoRate; case .paired: return 1 }
  }
  func videoTime(forAudioTime time: CMTime) throws -> CMTime {
    switch self {
    case .mapped(let mapping): return try mapping.videoTime(forAudioTime: time)
    case .paired(let audio, let video):
      guard time.isNumeric, audio.isNumeric, video.isNumeric, time.epoch == audio.epoch else {
        throw ClockMappedPCMError.invalidPacket
      }
      let result = CMTimeAdd(video, CMTimeSubtract(time, audio))
      guard result.isNumeric else { throw ClockMappedPCMError.invalidPacket }
      return result
    }
  }
}

/// Fractional source rates resample onto the nearest positive integral rate
/// representable by the track's exact CMTime sample grid. Source ASBD remains
/// unchanged. This is an output-grid choice, never a source admission guess.
func recordingPCMOutputSampleRate(for format: SourceAudioFormat) throws -> Double {
  let selected = max(1, format.sampleRate.rounded())
  guard selected <= Double(Int32.max) else { throw ClockMappedPCMError.invalidPacket }
  return selected
}
