import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// Synthetic v210 only. Exercise the real ProRes and HEVC encoders, callback
// queue, audio interleave and movie finalization without opening any device.
let arguments = Array(CommandLine.arguments.dropFirst())
let usage = "Usage: recording-stop-smoke OUTPUT_DIRECTORY"
if arguments == ["--help"] {
  print(usage)
  exit(0)
}
guard arguments.count == 1, let path = arguments.first, !path.isEmpty, !path.hasPrefix("-") else {
  fputs("\(usage)\n", stderr)
  exit(2)
}

DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
  fputs("RECORDING_STOP FAIL watchdog expired\n", stderr)
  _exit(124)
}
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw SourceRecordingError.writerFailure(message) }
}
Task {
  do {
    let root = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var buffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    guard result == kCVReturnSuccess, let image = buffer else {
      throw SourceRecordingError.writerFailure("Cannot allocate synthetic v210 input.")
    }
    try require(CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess, "Cannot lock synthetic v210 input.")
    if let base = CVPixelBufferGetBaseAddress(image) {
      memset(base, 0, CVPixelBufferGetDataSize(image))
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    let duration = CMTime(value: 1001, timescale: 60000)
    for (codecName, codec) in [("ProRes", kCMVideoCodecType_AppleProRes422HQ), ("HEVC", kCMVideoCodecType_HEVC)] {
      for take in 1...3 {
        let url = root.appendingPathComponent("Synthetic \(codecName) \(take).mov")
        let configuration = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("synthetic"),
          outputURL: url, width: 3840, height: 2160, videoCodec: codec,
          queueCapacity: 24)
        let recorder = try SourceRecorderCore(configuration: configuration)
        try recorder.start()
        let started = ProcessInfo.processInfo.systemUptime
        for frame in 0..<60 {
          let target = started + Double(frame) * duration.seconds
          let delay = target - ProcessInfo.processInfo.systemUptime
          if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
          let pts = CMTimeMultiply(duration, multiplier: Int32(frame))
          let sample = try VideoContract.sample(image, at: pts, duration: duration)
          try require(recorder.appendVideo(sample), "Synthetic video admission failed.")
          let audioStart = Int64(frame) * 1001 * 48_000 / 60_000
          let audioEnd = Int64(frame + 1) * 1001 * 48_000 / 60_000
          let audio = try EmbeddedAudioRecording.makeSilenceSampleBuffer(sampleFrameCount: Int(audioEnd - audioStart),
            presentationTime: CMTime(value: audioStart, timescale: 48_000))
          try require(recorder.appendAudio(audio), "Synthetic audio admission failed.")
        }
        let stopping = ProcessInfo.processInfo.systemUptime
        try recorder.stop()
        let stopSeconds = ProcessInfo.processInfo.systemUptime - stopping
        try require(recorder.state == .finished, "Recorder did not finish.")
        let telemetry = recorder.telemetry
        try require(telemetry.encodedVideo == 60 && telemetry.encoderErrors == 0 && telemetry.totalDrops == 0,
          "Encoded frames were lost or the encoder reported an error: \(telemetry)")
        try require(telemetry.encodedVideoBytes > 0 && telemetry.hardwareEncoder == true,
          "Missing encoded-byte or hardware-encoder telemetry.")
        try require(telemetry.encoderLatencyMS != nil && telemetry.maxEncoderLatencyMS != nil
          && telemetry.encoderPendingFrames == 0 && telemetry.queueSamples == 0,
          "Latency or drained queue telemetry is wrong.")
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let actualDuration = try await asset.load(.duration)
        try require(video.count == 1 && audio.count == 1,
          "Final movie is missing its video or audio track.")
        try require(actualDuration.seconds > 0.9, "Final movie duration is truncated.")
        print("RECORDING_STOP PASS codec=\(codecName) take=\(take) encoded=60 stopSeconds=\(stopSeconds) tracks=video,audio encodedBytes=\(telemetry.encodedVideoBytes) hardware=\(telemetry.hardwareEncoder == true) latencyMS=\(telemetry.encoderLatencyMS ?? -1) physicalCapture=false")
      }
    }
    exit(0)
  } catch {
    fputs("RECORDING_STOP FAIL \(error.localizedDescription)\n", stderr)
    exit(1)
  }
}
dispatchMain()
