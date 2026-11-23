import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation

// This helper never opens a camera. Closing the parent's control pipe kills
// its synthetic writer before finalization, including if the parent exits.
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw RecordingOutputError.ioFailure(message) }
}
func waitForReady(_ handle: FileHandle) throws {
  let deadline = ProcessInfo.processInfo.systemUptime + 10
  var input = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
  for expected in "READY\n".utf8 {
    while true {
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      try require(remaining > 0, "Timed out waiting for the child writer.")
      let result = poll(&input, 1, Int32((remaining * 1_000).rounded(.up)))
      if result < 0 && errno == EINTR { continue }
      try require(result > 0, "Child writer readiness poll failed or timed out.")
      let byte = try handle.read(upToCount: 1)?.first
      try require(byte == expected, "Child writer exited or sent an invalid readiness signal.")
      break
    }
  }
}

func fingerprint(_ url: URL) throws -> SHA256Digest {
  let input = try FileHandle(forReadingFrom: url)
  defer { try? input.close() }
  var hash = SHA256()
  while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
    hash.update(data: chunk)
  }
  return hash.finalize()
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
  guard status == kCVReturnSuccess, let image = buffer else {
    throw RecordingOutputError.ioFailure("Cannot allocate v210.")
  }
  try require(CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess, "Cannot lock v210.")
  if let base = CVPixelBufferGetBaseAddress(image) {
    memset(base, 0, CVPixelBufferGetDataSize(image))
  }
  CVPixelBufferUnlockBaseAddress(image, [])
  let duration = CMTime(value: 1001, timescale: 60000)
  let start = ProcessInfo.processInfo.systemUptime
  print("READY"); fflush(stdout)
  for frame in 0..<1800 {
    let target = start + Double(frame) * duration.seconds
    let delay = target - ProcessInfo.processInfo.systemUptime
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    try require(recorder.appendVideo(try VideoContract.sample(image,
      at: CMTimeMultiply(duration, multiplier: Int32(frame)), duration: duration)), "Video admission failed.")
    let audioStart = Int64(frame) * 1001 * 48_000 / 60_000
    let audioEnd = Int64(frame + 1) * 1001 * 48_000 / 60_000
    let audio = try EmbeddedAudioRecording.makeSilenceSampleBuffer(sampleFrameCount: Int(audioEnd - audioStart),
      presentationTime: CMTime(value: audioStart, timescale: 48_000))
    try require(recorder.appendAudio(audio), "Audio admission failed.")
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
      process.arguments = ["--owned-child", takeRoot.path, codec, timecode ? "timecode" : "source"]
      let pipe = Pipe()
      process.standardOutput = pipe
      let control = Pipe()
      process.standardInput = control
      let exited = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
      process.terminationHandler = { _ in
        exited.continuation.yield(())
        exited.continuation.finish()
      }
      try process.run()
      defer {
        try? control.fileHandleForWriting.close()
        exited.continuation.finish()
      }
      try pipe.fileHandleForWriting.close()
      try waitForReady(pipe.fileHandleForReading)
      try await Task.sleep(for: .seconds(seconds))
      try require(process.isRunning, "Child writer exited before it could be interrupted.")
      let live = try RecordingRecovery.scan(root: takeRoot)
      try require(live.isEmpty, "Recovery offered an active recording.")
      try control.fileHandleForWriting.close()
      let timeout = Task {
        try await Task.sleep(for: .seconds(10))
        exited.continuation.finish()
      }
      var exits = exited.stream.makeAsyncIterator()
      let didExit = await exits.next() != nil
      timeout.cancel()
      try require(didExit, "Timed out waiting for child termination.")
      try require(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL,
        "Child was not abruptly interrupted.")
      let initial = try RecordingRecovery.scan(root: takeRoot)
      try require(initial.count == 1, "Interrupted take was not discovered.")
      let occupied = Data("unrelated movie".utf8)
      if !timecode { try occupied.write(to: initial[0].finalURL, options: .withoutOverwriting) }
      let takes = try RecordingRecovery.scan(root: takeRoot)
      try require(takes.count == 1, "Interrupted take was not discovered.")
      let original = try fingerprint(takes[0].temporaryURL)
      let recovered = try await RecordingRecovery.recover(takes[0], root: takeRoot)
      try require(try fingerprint(takes[0].temporaryURL) == original, "Recovery modified the original.")
      if !timecode {
        try require(recovered != takes[0].finalURL, "Recovery reused the occupied destination.")
        try require(try Data(contentsOf: takes[0].finalURL) == occupied, "Recovery modified the occupied destination.")
      }
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
  let arguments = Array(CommandLine.arguments.dropFirst())
  let usage = """
    Usage: recovery-smoke OUTPUT_DIRECTORY
           recovery-smoke --recover RECORDING_DIRECTORY
           recovery-smoke --help
    """
  if arguments == ["--help"] {
    print(usage)
    exit(0)
  }
  do {
    switch arguments.first {
    case "--child", "--owned-child":
      guard arguments.count == 4,
        !arguments[1].isEmpty, !arguments[1].hasPrefix("-"),
        ["ProRes", "HEVC"].contains(arguments[2]),
        ["timecode", "source"].contains(arguments[3]) else {
        fputs("Usage: recovery-smoke \(arguments[0]) OUTPUT_DIRECTORY {ProRes|HEVC} {timecode|source}\n", stderr)
        exit(2)
      }
      if arguments[0] == "--owned-child" {
        Thread.detachNewThread {
          // EOF also arrives if the parent exits while the take is active.
          _ = try? FileHandle.standardInput.read(upToCount: 1)
          raise(SIGKILL)
        }
      }
      try child(root: URL(fileURLWithPath: arguments[1], isDirectory: true),
        codecName: arguments[2], timecode: arguments[3] == "timecode")
    case "--recover" where arguments.count == 2 && !arguments[1].isEmpty && !arguments[1].hasPrefix("-"):
      let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
      guard let take = try RecordingRecovery.scan(root: root).first else {
        throw RecordingOutputError.ioFailure("No interrupted recording was found.")
      }
      print(try await RecordingRecovery.recover(take, root: root).path)
    case let path? where arguments.count == 1 && !path.isEmpty && !path.hasPrefix("-"):
      try await parent(root: URL(fileURLWithPath: path, isDirectory: true))
    default:
      fputs("\(usage)\n", stderr)
      exit(2)
    }
    exit(0)
  } catch { fputs("RECOVERY FAIL \(error)\n", stderr); exit(1) }
}
dispatchMain()
