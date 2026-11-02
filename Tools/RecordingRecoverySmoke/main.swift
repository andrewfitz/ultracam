import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation

// This helper never opens a camera. The parent SIGKILLs synthetic child
// writers before finalization, then exercises the production recovery path.
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw RecordingOutputError.ioFailure(message) }
}
func child(root: URL, codecName: String, timecode: Bool) throws {
  let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
  let output = try manager.beginExternalWriterSession(feedID: "Synthetic \(codecName)")
  let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("synthetic"),
    outputURL: output.temporaryURL, width: 3840, height: 2160,
    videoCodec: codecName == "ProRes" ? kCMVideoCodecType_AppleProRes422HQ : kCMVideoCodecType_HEVC,
    queueCapacity: 24, timecodePolicy: timecode ? .recordStart : .source)
  let recorder = try SourceRecorderCore(configuration: config)
  try recorder.start()
  var buffer: CVPixelBuffer?
  let status = CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
  try require(status == kCVReturnSuccess && buffer != nil, "Cannot allocate v210.")
  let image = buffer!
  CVPixelBufferLockBaseAddress(image, [])
  memset(CVPixelBufferGetBaseAddress(image)!, 0, CVPixelBufferGetDataSize(image))
  CVPixelBufferUnlockBaseAddress(image, [])
  let duration = CMTime(value: 1001, timescale: 60000)
  let start = ProcessInfo.processInfo.systemUptime
  print("READY"); fflush(stdout)
  for frame in 0..<1800 {
    let target = start + Double(frame) * duration.seconds
    while ProcessInfo.processInfo.systemUptime < target { Thread.sleep(forTimeInterval: 0.001) }
    try require(recorder.appendVideo(try VideoContract.sample(image,
      at: CMTimeMultiply(duration, multiplier: Int32(frame)), duration: duration)), "Video admission failed.")
    let packet = try EmbeddedAudioPacket(sourcePCM32: Data(repeating: 0, count: 800 * 2 * 4),
      sampleFrameCount: 800, presentationTime: CMTime(value: Int64(frame) * 800, timescale: 48000))
    try require(recorder.appendAudio(EmbeddedAudioRecording.makeSampleBuffer(for: packet)), "Audio admission failed.")
  }
  // A normal exit here is a test failure: the parent must interrupt us.
  withExtendedLifetime(output) {}
  throw RecordingOutputError.ioFailure("Child was not killed.")
}

func parent(root: URL) async throws {
  for codec in ["ProRes", "HEVC"] {
    for (seconds, timecode) in [(4.0, false), (14.0, true)] {
      let takeRoot = root.appendingPathComponent("\(codec)-\(Int(seconds))", isDirectory: true)
      try FileManager.default.createDirectory(at: takeRoot, withIntermediateDirectories: true)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = ["--child", takeRoot.path, codec, timecode ? "timecode" : "source"]
      let pipe = Pipe()
      process.standardOutput = pipe
      try process.run()
      let ready = pipe.fileHandleForReading.availableData
      try require(String(data: ready, encoding: .utf8)?.contains("READY") == true, "Child did not start.")
      let live = try RecordingRecovery.scan(root: takeRoot)
      try require(live.isEmpty, "Recovery offered an active recording.")
      try await Task.sleep(for: .seconds(seconds))
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      try require(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL,
        "Child was not abruptly interrupted.")
      let takes = try RecordingRecovery.scan(root: takeRoot)
      try require(takes.count == 1, "Interrupted take was not discovered.")
      let original = try Data(contentsOf: takes[0].temporaryURL)
      let recovered = try await RecordingRecovery.recover(takes[0], root: takeRoot)
      try require(try Data(contentsOf: takes[0].temporaryURL) == original, "Recovery modified the original.")
      let asset = AVURLAsset(url: recovered)
      let video = try await asset.loadTracks(withMediaType: .video)
      let audio = try await asset.loadTracks(withMediaType: .audio)
      let tc = try await asset.loadTracks(withMediaType: .timecode)
      let duration = try await asset.load(.duration)
      try require(video.count == 1 && audio.count == 1 && tc.count == (timecode ? 1 : 0), "Recovery lost tracks.")
      try require(duration.seconds >= (seconds > 10 ? 10 : 0.9) && duration.seconds <= seconds,
        "Recovered fragment duration is wrong: \(duration.seconds).")
      try require(try RecordingRecovery.scan(root: takeRoot).isEmpty, "Recovered take was offered again.")
      print("RECOVERY PASS codec=\(codec) killedAt=\(seconds)s recovered=\(duration.seconds)s timecode=\(timecode) originalUnchanged=true path=\(recovered.path)")
      fflush(stdout)
    }
  }
}

Task {
  do {
    if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--child" {
      try child(root: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
        codecName: CommandLine.arguments[3], timecode: CommandLine.arguments[4] == "timecode")
    } else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--recover" {
      let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
      guard let take = try RecordingRecovery.scan(root: root).first else {
        throw RecordingOutputError.ioFailure("No interrupted recording was found.")
      }
      print(try await RecordingRecovery.recover(take, root: root).path)
    } else {
      guard CommandLine.arguments.count == 2 else { throw RecordingOutputError.invalidRoot }
      try await parent(root: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
    }
    exit(0)
  } catch { fputs("RECOVERY FAIL \(error)\n", stderr); exit(1) }
}
dispatchMain()
