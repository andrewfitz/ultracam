@preconcurrency import AVFAudio
import CoreMedia
import CoreVideo
import Foundation

private enum SmokeError: Error {
  case fixture(String)
}

private final class ConnectionTime: @unchecked Sendable {
  private let lock = NSLock()
  private var time: TimeInterval?
  func connected() { lock.withLock { time = ProcessInfo.processInfo.systemUptime } }
  var startup: Bool {
    lock.withLock { time.map { ProcessInfo.processInfo.systemUptime - $0 < 0.4 } ?? false }
  }
}

private final class CompressedWritePause: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = false
  private var injected = false
  func arm() { lock.withLock { pending = true } }
  var didPause: Bool { lock.withLock { injected } }
  func beforeWrite() async {
    let shouldPause = lock.withLock {
      guard pending, !injected else { return false }
      injected = true
      return true
    }
    if shouldPause { try? await Task.sleep(for: .milliseconds(800)) }
  }
}

// The prepared reference pictures and PCM are immutable for the duration of a run.
private struct Fixture: @unchecked Sendable {
  let gray: [CVPixelBuffer]
  let flash: CVPixelBuffer
  let black: CVPixelBuffer
  let format: CMVideoFormatDescription
  let frameDuration: CMTime
  let pcmByCount: [Int: (quiet: AVAudioPCMBuffer, tones: [AVAudioPCMBuffer])]

  init(_ output: ProgramStreamFormat, movingBars: Bool = false) throws {
    frameDuration = output.rate.duration
    flash = try Self.picture(output, luma: 230)
    black = try Self.picture(output, luma: 16)
    gray = try (1...6).map { try Self.picture(output, luma: 90, seed: UInt32($0), movingBars: movingBars) }
    var description: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: flash,
            formatDescriptionOut: &description) == noErr, let description else {
      throw SmokeError.fixture("Could not describe video fixture")
    }
    format = description
    let samples = frameDuration.seconds * 48_000
    var pcm: [Int: (quiet: AVAudioPCMBuffer, tones: [AVAudioPCMBuffer])] = [:]
    for count in Set([Int(floor(samples)), Int(ceil(samples))]) {
      // At 48 kHz the joint 900/1200 Hz stereo waveform repeats every 160 samples.
      // Fractional picture rates can split a PCM packet at any phase of this cycle.
      let tones = try (0..<160).map { try Self.pcm(sounding: true, count: count, phase: $0) }
      pcm[count] = (try Self.pcm(sounding: false, count: count), tones)
    }
    pcmByCount = pcm
  }

  private static func picture(_ output: ProgramStreamFormat, luma: UInt8, seed: UInt32? = nil,
                              movingBars: Bool = false) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let pixels = output.codec.pixelFormat
    guard CVPixelBufferCreate(nil, output.size.width, output.size.height, pixels,
                              attributes, &result) == kCVReturnSuccess, let result,
          CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else {
      throw SmokeError.fixture("Could not allocate video fixture")
    }
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    for plane in 0..<2 {
      guard let address = CVPixelBufferGetBaseAddressOfPlane(result, plane) else {
        throw SmokeError.fixture("Missing fixture plane")
      }
      let count = CVPixelBufferGetBytesPerRowOfPlane(result, plane) * CVPixelBufferGetHeightOfPlane(result, plane)
      if pixels != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
        // x420/x422 store 10-bit video-range values left justified in little-endian UInt16.
        let words = address.assumingMemoryBound(to: UInt16.self)
        let base = plane == 0 ? UInt16(luma) * 4 : 512
        if plane == 0, var state = seed {
          for i in 0..<(count / 2) {
            state = 1664525 &* state &+ 1013904223
            words[i] = (base + UInt16(state >> 25)) << 6
          }
        } else { words.update(repeating: base << 6, count: count / 2) }
        continue
      }
      memset(address, plane == 0 ? Int32(luma) : 128, count)
      if plane == 0, var state = seed {
        if movingBars {
          let stride = CVPixelBufferGetBytesPerRowOfPlane(result, plane)
          let x = Int(state - 1) * output.size.width / 7
          for row in 0..<output.size.height {
            memset(address + row * stride + x, 160, output.size.width / 7)
          }
          continue
        }
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count {
          state = 1664525 &* state &+ 1013904223
          bytes[i] = luma + UInt8(state >> 27)
        }
      }
    }
    let wide = output.colorSpaceID != "rec709-video"
    let primaries = wide ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2
    let matrix = wide ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
    let transfer: CFString
    switch output.colorSpaceID {
    case "rec2020-pq-video": transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    case "rec2020-hlg-video": transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
    default: transfer = kCVImageBufferTransferFunction_ITU_R_709_2
    }
    CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
    CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
    CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
    return result
  }

  static func pcm(sounding: Bool, slotFrequency: Int? = nil, count: Int = 1600, phase: Int = 0) throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
          let data = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let samples = data.floatChannelData else {
      throw SmokeError.fixture("Could not allocate audio fixture")
    }
    data.frameLength = AVAudioFrameCount(count)
    let leftLevel: Float = sounding ? 0.4 : slotFrequency == nil ? 0 : 0.055
    let rightLevel: Float = sounding || slotFrequency != nil ? 0.27 : 0
    for i in 0..<count {
      samples[0][i] = leftLevel * sin(2 * .pi * Float(i + phase) * 900 / 48_000)
      samples[1][i] = rightLevel * sin(2 * .pi * Float(i + phase) * Float(slotFrequency ?? 1200) / 48_000)
    }
    return data
  }

  func sample(frame: Int, phase: Int, at time: CMTime, lost: Bool = false) throws -> CMSampleBuffer {
    let image: CVPixelBuffer
    if lost || (48..<55).contains(phase) { image = black }
    else if (30..<42).contains(phase) { image = flash }
    else { image = gray[frame % gray.count] }
    var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
          formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else {
      throw SmokeError.fixture("Could not wrap fixture pixels")
    }
    return sample
  }

  func sendPCM(_ elapsed: CMTime, origin: CMTime, sounding: Bool,
               to audio: @Sendable (AVAudioPCMBuffer, CMTime) -> Void) throws {
    let first = CMTimeConvertScale(elapsed, timescale: 48_000, method: .roundHalfAwayFromZero)
    let end = CMTimeConvertScale(elapsed + frameDuration, timescale: 48_000, method: .roundHalfAwayFromZero)
    guard let pair = pcmByCount[Int(end.value - first.value)] else { throw SmokeError.fixture("Unexpected PCM frame length") }
    audio(sounding ? pair.tones[Int(first.value % 160)] : pair.quiet, origin + first)
  }

  // The app sources run on a scheduled media worker. Driving high-rate profiles from
  // the main actor measures UI wakeup jitter when the test host is heavily occupied.
  func publishProfile(seconds: Int, video: @escaping @Sendable (CMSampleBuffer, Bool) -> Void,
                      audio: @escaping @Sendable (AVAudioPCMBuffer, CMTime) -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let thread = Thread {
        do {
          let count = Int(Double(seconds) / frameDuration.seconds)
          let first = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 1, timescale: 4)
          let prepared = try (0..<count).map { index in
            let elapsed = CMTimeMultiply(frameDuration, multiplier: Int32(index))
            let phase = Int((elapsed.seconds * 30 + 0.000001).rounded(.down)) % 60
            let deadline = first + elapsed
            return (elapsed, phase, deadline, try sample(frame: index, phase: phase, at: deadline))
          }
          let wake = DispatchSemaphore(value: 0)
          let clock = DispatchSource.makeTimerSource(flags: .strict,
            queue: DispatchQueue(label: "org.ultracam.smoke.clock", qos: .userInteractive))
          clock.setEventHandler { wake.signal() }
          clock.resume()
          defer { clock.cancel() }
          var late = 0
          for (elapsed, phase, deadline, sample) in prepared {
            let delay = (deadline - CMClockGetTime(CMClockGetHostTimeClock())).seconds
            if delay > 0 {
              clock.schedule(deadline: .now() + .nanoseconds(Int(delay * 1e9)), leeway: .microseconds(100))
              wake.wait()
            }
            if CMClockGetTime(CMClockGetHostTimeClock()) - deadline > frameDuration { late += 1 }
            try sendPCM(elapsed, origin: first, sounding: (30..<42).contains(phase), to: audio)
            video(sample, !(48..<55).contains(phase))
          }
          print("fixture late by a frame on \(late) of \(count) input deadlines")
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
      thread.qualityOfService = .userInteractive
      thread.start()
    }
  }
}

@main enum ProgramStreamSmoke {
  @MainActor static func main() async throws {
    let args = CommandLine.arguments
    guard [4, 9].contains(args.count), let seconds = Int(args[3]), (1...7200).contains(seconds) else {
      throw SmokeError.fixture("Expected loopback server, mode and duration")
    }
    let server = args[1], mode = args[2]
    var output = ProgramStreamFormat()
    if args.count == 9 {
      guard seconds <= 60, let size = ResizeTarget(rawValue: args[4]), let rate = FrameRateTarget(rawValue: args[5]),
            let codec = ProgramStreamVideoCodec(rawValue: args[6]), let mbps = Int(args[7]) else {
        throw SmokeError.fixture("Invalid smoke profile")
      }
      output = ProgramStreamFormat(size: size, rate: rate, codec: codec, videoMbps: mbps, colorSpaceID: args[8])
    }
    if mode == "invalid-port" {
      let transport = makeProgramStreamPublisher()
      do {
        try await transport.connect(server: "rtmps://127.0.0.1:65536/live", key: "qualification", format: output, onDisconnect: { _ in })
        await transport.close()
        throw SmokeError.fixture("Accepted invalid destination port")
      } catch ProgramStreamPublisherError.rejected {
        print("Invalid port rejected before connection.")
      }
      return
    }
    if mode == "reject-tls" {
      let transport = FixturePublisher(loopbackPlaintext: false)
      var accepted = false
      do { try await transport.connect(server: server, key: "qualification", format: output, onDisconnect: { _ in }); accepted = true }
      catch { print("Untrusted TLS rejected by publisher.") }
      await transport.close()
      if accepted { throw SmokeError.fixture("Untrusted TLS accepted") }
      return
    }
    let suite = "org.ultracam.stream-smoke." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let withAudio = mode != "video-only"
    let trustedTLS = mode == "trusted-tls" || ProcessInfo.processInfo.environment["ULTRACAM_SMOKE_TRUSTED_TLS"] == "1"
    let connection = ConnectionTime()
    let writePause = CompressedWritePause()
    let session = ProgramStreamSession(defaults: defaults, credentials: FixtureKeychain(),
      makePublisher: {
        let transport: any ProgramStreamPublishing
        if mode == "compressed-pressure" {
          transport = makeProgramStreamPublisher(beforeCompressedSend: { await writePause.beforeWrite() })
        } else {
          transport = makeProgramStreamPublisher()
        }
        return FixturePublisher(loopbackPlaintext: !trustedTLS, transport: transport,
          initialVideoDrops: mode == "startup-epoch" ? 6 : 0,
          didConnect: { connection.connected() })
      })
    try session.save(ProgramStreamConfiguration(name: "Loopback", server: server, audioFeedID: withAudio ? "fixture" : nil, firstChannel: 0, format: output), key: "qualification")
    let fixture = try Fixture(output, movingBars: mode.contains("-camera-"))
    // A different carrier identifies each consecutive PCM packet even where the video
    // worker skips multiple ticks. Every window contains an integer number of cycles.
    let frequencies = [600, 1980, 960, 3240, 1380, 2580, 1740, 3660, 2220, 2940]
    let marked = mode == "audio-continuity" ? try frequencies.map { frequency in
      (try Fixture.pcm(sounding: false, slotFrequency: frequency),
       try Fixture.pcm(sounding: true, slotFrequency: frequency))
    } : []
    try session.start()
    let video = session.makeVideoHandler(), audio = session.makeAudioHandler()
    let origin = CMClockGetTime(CMClockGetHostTimeClock())
    var previousPhase = ""
    if args.count == 9 {
      async let feed: Void = fixture.publishProfile(seconds: seconds, video: video, audio: audio)
      while (CMClockGetTime(CMClockGetHostTimeClock()) - origin).seconds < Double(seconds) {
        let state = session.snapshot
        if state.phase.rawValue != previousPhase {
          previousPhase = state.phase.rawValue
          print("phase \(previousPhase)")
          if let reason = state.lastInterruption { print("interruption \(reason.rawValue)") }
          fflush(nil)
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      try await feed
      let finalState = session.snapshot
      print("finished \(finalState.phase.rawValue), dropped video \(finalState.droppedVideo)")
      session.stop()
      try await Task.sleep(for: .milliseconds(400))
      return
    }
    var lossReported = false
    var recoveryReported = false
    for index in 0..<Int(Double(seconds) / fixture.frameDuration.seconds) {
      let elapsed = CMTimeMultiply(fixture.frameDuration, multiplier: Int32(index))
      let time = CMTimeAdd(origin, elapsed)
      let wait = CMTimeSubtract(time, CMClockGetTime(CMClockGetHostTimeClock())).seconds
      if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
      if mode == "compressed-pressure", index == 104 { writePause.arm() }
      if mode == "worker-gaps", (103..<124).contains(index) || (192..<342).contains(index) { continue }
      // Image and audio share wall-clock markers at every rate, including 1000/1001.
      let phase = Int((elapsed.seconds * 30 + 0.000001).rounded(.down)) % 60
      let lost = mode == "media-loss" && (75..<120).contains(index)
      if withAudio && !lost, mode != "audio-late" || !connection.startup {
        let pulse = (30..<42).contains(phase)
        if mode == "audio-continuity" {
          let pair = marked[index % marked.count]
          audio(pulse ? pair.1 : pair.0, time)
        } else {
          try fixture.sendPCM(elapsed, origin: origin, sounding: pulse, to: audio)
        }
      }
      let omitVideo = mode == "audio-continuity" && (phase == 8 || (18...19).contains(phase) || (44...46).contains(phase))
      if !omitVideo, mode != "video-late" || !connection.startup {
        video(try fixture.sample(frame: index, phase: phase, at: time, lost: lost), !lost && !(48..<55).contains(phase))
      }
      if mode == "media-loss", session.snapshot.phase == .streaming {
        if lost, session.snapshot.audioMissing, !session.snapshot.pictureFresh { lossReported = true }
        if lossReported, !lost, !session.snapshot.audioMissing, session.snapshot.pictureFresh { recoveryReported = true }
      }
      let currentPhase = String(describing: session.snapshot.phase)
      if previousPhase != currentPhase {
        print("phase \(currentPhase) frame \(index)")
        if let reason = session.snapshot.lastInterruption { print("interruption \(reason.rawValue)") }
        fflush(nil)
        previousPhase = currentPhase
      }
    }
    let finalState = session.snapshot
    print("finished \(finalState.phase.rawValue), dropped video \(finalState.droppedVideo)")
    session.stop()
    if mode == "worker-gaps" || mode == "compressed-pressure" {
      guard finalState.phase == .streaming else { throw SmokeError.fixture("Recovery did not stay live") }
      if mode == "compressed-pressure" {
        guard writePause.didPause, (1...40).contains(finalState.droppedVideo) else {
          throw SmokeError.fixture("Expected bounded pressure drops; measured \(finalState.droppedVideo)")
        }
      }
      print("Recovery drops \(finalState.droppedVideo)")
    }
    if mode == "media-loss", !lossReported || !recoveryReported {
      throw SmokeError.fixture("Missing live media-loss or recovery status")
    }
    try await Task.sleep(for: .milliseconds(400))
  }
}
