import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Synchronization

private struct SmokeFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private final class DeliveryAudit: Sendable {
  // The smoke detects gross timebase errors. Recorded sync needs visible and audible cues.
  private static let maximumClockAge = 5.0
  struct Snapshot {
    var epoch: CaptureEpochID?
    var format: SourceFormat?
    var audio: SourceAudioDeclaration?
    var lastSequence: UInt64?
    var frames = 0
    var packets = 0
    var epochFrames = 0
    var epochPackets = 0
    var audioFrames = 0
    var declarations = 0
    var clockUpdates = 0
    var firstVideoPTS: CMTime?
    var lastVideoPTS: CMTime?
    var firstAudioPTS: CMTime?
    var lastAudioPTS: CMTime?
    var audioMapping: ClockMapping?
    var callbacks = 0
    var startupMessage: String?
    var errors: [String] = []
  }
  private let state = Mutex(Snapshot())
  private let expectsAudio: Bool
  init(expectsAudio: Bool) { self.expectsAudio = expectsAudio }
  var snapshot: Snapshot { state.withLock { $0 } }

  func audit(_ delivery: CaptureDelivery) {
    state.withLock { result in
      result.callbacks += 1
      if let last = result.lastSequence, delivery.sequence != last + 1 {
        result.errors.append("Nonconsecutive delivery sequence")
      }
      result.lastSequence = delivery.sequence
      switch delivery.payload {
      case .event(.formatChanged(let format)):
        result.declarations += 1
        result.epoch = delivery.epochID
        result.format = format
        result.audio = nil
        result.audioMapping = nil
        result.epochFrames = 0
        result.epochPackets = 0
        print("Declared epoch \(delivery.epochID.epoch) \(format.width)x\(format.height), clock=\(format.clock), \(format.rate)")
      case .event(.audioFormatChanged(let audio)):
        result.audio = audio
      case .event(.clockMappingChanged(let update)):
        result.clockUpdates += 1
        if update.effectiveSequence != delivery.sequence + 1 {
          result.errors.append("Clock mapping did not target the next delivery")
        }
        if update.clockID == delivery.clockBindings.audio { result.audioMapping = update.mapping }
      case .event(.unsupportedInput(let message)), .event(.fatal(let message)):
        result.errors.append(message)
      case .event(.signalLost(let reason)), .event(.info(let reason)):
        result.startupMessage = reason
      case .frame(let storage, let info):
        if result.epochFrames > 0, let previous = result.lastVideoPTS, previous >= info.presentationTime {
          result.errors.append("Video PTS did not advance within its epoch")
        }
        result.frames += 1
        result.epochFrames += 1
        result.firstVideoPTS = result.firstVideoPTS ?? info.presentationTime
        result.lastVideoPTS = info.presentationTime
        if let format = result.format {
          let image = storage.value
          if result.epoch != info.epochID || format.signature != info.formatSignature ||
            result.audio == nil || !info.signalValid || (try? info.validate()) == nil ||
            CVPixelBufferGetWidth(image) != format.width || CVPixelBufferGetHeight(image) != format.height ||
            CVPixelBufferGetPixelFormatType(image) != format.pixel.rawValue {
            result.errors.append("Frame did not match its ordered video/audio declarations")
          }
          if result.epochFrames == 1 {
            let age = info.captureHostTime.map { (CMClockGetTime(CMClockGetHostTimeClock()) - $0).seconds }
            print("First frame \(format.width)x\(format.height) \(String(format: "%08x", format.pixel.rawValue)) clock=\(format.clock) PTS=\(info.presentationTime.seconds) duration=\(info.duration.seconds) hostAgeSeconds=\(age?.description ?? "unknown") IOSurface=\(CVPixelBufferGetIOSurface(image) != nil)")
            if age.map({ abs($0) <= Self.maximumClockAge }) != true {
              result.errors.append("First video frame did not map near current host time")
            }
          }
        } else {
          result.errors.append("Frame arrived before its source declaration")
        }
      case .rawAudio(let packet):
        guard expectsAudio, result.audio == .present(packet.format), packet.pairedFrameSequence == nil,
          packet.sampleFrameCount > 0, packet.packetTime.isNumeric,
          result.epochPackets == 0 || (result.lastAudioPTS.map({ $0 < packet.packetTime }) ?? true) else {
          result.errors.append("Invalid or unexpected independent PCM delivery")
          return
        }
        result.packets += 1
        result.epochPackets += 1
        result.audioFrames += packet.sampleFrameCount
        result.firstAudioPTS = result.firstAudioPTS ?? packet.packetTime
        result.lastAudioPTS = packet.packetTime
        if result.epochPackets == 1 {
          let age = (try? result.audioMapping?.hostTime(for: packet.packetTime))
            .map { (CMClockGetTime(CMClockGetHostTimeClock()) - $0).seconds }
          print("First PCM \(packet.format.sampleRate) Hz, \(packet.format.channels) channels, \(packet.format.sample), frames=\(packet.sampleFrameCount), clock=\(packet.format.clock), PTS=\(packet.packetTime.seconds), hostAgeSeconds=\(age?.description ?? "unknown")")
          if age.map({ abs($0) <= Self.maximumClockAge }) != true {
            result.errors.append("First PCM packet did not map near current host time")
          }
        }
      default: break
      }
    }
  }
}

private func exactFPS(for duration: CMTime) -> String {
  let rate = try? Rational(Int64(duration.timescale), duration.value)
  return "\(rate?.numerator ?? Int64(duration.timescale))/\(rate?.denominator ?? duration.value)"
}

@MainActor private func run() async throws {
  let args = Array(CommandLine.arguments.dropFirst())
  if args == ["--audio-inputs"] {
    print("Microphone authorization=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
    for input in discovery.devices {
      print("Microphone uid=\(input.uniqueID) name=\(input.localizedName)")
    }
    return
  }
  let listing = args.first == "--formats"
  let explicit = args.first == "--capture"
  let validArguments = listing ? args.count == 2 :
    (explicit ? (4...5).contains(args.count) : (1...3).contains(args.count) && args.first?.hasPrefix("--") == false)
  guard validArguments else {
    throw SmokeFailure("Usage: mac-camera-hardware-smoke --audio-inputs | --formats INPUT_UID | --capture INPUT_UID FORMAT_ID FPS [MICROPHONE_UID] | INPUT_UID [CAPTURE_FORMAT_INDEX [MICROPHONE_UID]]")
  }
  let uid = args[listing || explicit ? 1 : 0]
  guard !uid.isEmpty, !VirtualCameraDescriptor.isDeviceUID(uid) else {
    throw SmokeFailure("Select an independent camera input UID")
  }
  let microphoneUID = explicit ? args.dropFirst(4).first : (listing ? nil : args.dropFirst(2).first)
  let microphone = microphoneUID.map { "input:" + $0 } ?? "off"
  let configuredSeconds = ProcessInfo.processInfo.environment["ULTRACAM_MAC_CAMERA_SMOKE_SECONDS"] ?? "0"
  guard let seconds = Int(configuredSeconds), (0...60).contains(seconds) else {
    throw SmokeFailure("ULTRACAM_MAC_CAMERA_SMOKE_SECONDS must be an integer from 0 through 60")
  }
  let plugin = MacCameraCapturePlugin()
  let id = MacCameraCapturePlugin.id(for: uid)
  try plugin.configureSettings(.init(desiredByDevice: [id: [MacCameraAudio.settingsKey: .choice(microphone)]]))
  try await plugin.authorizeCapture(deviceID: id)
  guard let device = try plugin.devices().first(where: { $0.id == id }),
    let mode = try await plugin.settings(deviceID: id).first(where: { $0.id == MacCameraCapturePlugin.modeKey }),
    let formats = mode.captureFormats else {
    throw SmokeFailure("The selected camera has no available capture formats")
  }
  if listing {
    print("Capture formats for \(device.name) (\(uid))")
    for (index, format) in formats.enumerated() {
      let intervals = format.ranges.map {
        "\(exactFPS(for: $0.longest))...\(exactFPS(for: $0.shortest))"
      }
      let presets = format.rates.map { exactFPS(for: $0.duration) }
      print("  [\(index)] id=\(format.id) \(format.label) fpsRanges=\(intervals) fpsPresets=\(presets)")
    }
    return
  }
  let format: VendorCaptureFormat
  let duration: CMTime
  if explicit {
    guard let choice = formats.first(where: { $0.id == args[2] }) else {
      throw SmokeFailure("The selected format ID is unavailable. Use --formats with the selected camera UID.")
    }
    guard let rate = VendorCaptureMode.customDuration(args[3]), choice.supports(rate) else {
      throw SmokeFailure("The requested FPS is unsupported by this format. Use an exact value in a --formats interval.")
    }
    format = choice
    duration = rate
  } else {
    let index = args.count >= 2 ? Int(args[1]) ?? -1 : 0
    guard formats.indices.contains(index), let rate = formats[index].rates.first else {
      throw SmokeFailure("The selected plugin format index is unavailable. Use --formats with the selected camera UID.")
    }
    format = formats[index]
    duration = rate.duration
  }
  let selection = VendorCaptureMode.value(formatID: format.id, duration: duration)
  try plugin.configureSettings(.init(desiredByDevice: [id: [
    MacCameraCapturePlugin.modeKey: selection, MacCameraAudio.settingsKey: .choice(microphone)
  ]]))
  print("Selected \(device.name) / \(format.label) / \(exactFPS(for: duration)) fps, formatID=\(format.id), microphone=\(microphone)")

  for attempt in 1...2 {
    let audit = DeliveryAudit(expectsAudio: microphone != "off")
    let session = plugin.makeSession()
    defer { session.stop() }
    try await Task.detached {
      try session.start(deviceID: id, timing: .automatic, handlers: CaptureHandlers(deliver: { audit.audit($0) }))
    }.value
    let settings = try await plugin.settings(deviceID: id)
    guard let readback = settings.first(where: { $0.id == MacCameraCapturePlugin.modeKey }),
      readback.value == selection, !readback.mutable, readback.applicationError == nil,
      plugin.status(deviceID: id)?.availability == .inUseHere else {
      throw SmokeFailure("Selected mode or running status did not read back through the plugin")
    }
    let clock = ContinuousClock()
    let sampleUntil = clock.now.advanced(by: .seconds(seconds))
    let deadline = sampleUntil.advanced(by: .seconds(15))
    while clock.now < deadline {
      let current = audit.snapshot
      if !current.errors.isEmpty || (clock.now >= sampleUntil && current.frames >= 8 &&
        (microphone == "off" || current.packets >= 4)) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let active = plugin.status(deviceID: id)
    let captured = audit.snapshot
    guard captured.errors.isEmpty, captured.frames >= 8, let delivered = captured.format else {
      throw SmokeFailure("Expected eight admitted video frames; received \(captured.frames). \((captured.errors + [captured.startupMessage].compactMap { $0 }).joined(separator: " "))")
    }
    if microphone == "off" {
      guard captured.audio == SourceAudioDeclaration.absent else { throw SmokeFailure("Expected absent audio declaration") }
    } else {
      guard captured.packets >= 4 else { throw SmokeFailure("Expected at least four PCM packets; received \(captured.packets). \(active?.signalDetail ?? "")") }
      print("Delivered \(captured.packets) independent PCM packets, \(captured.audioFrames) sample frames")
      print("Source PTS span in seconds: video \(captured.firstVideoPTS?.seconds ?? .nan)...\(captured.lastVideoPTS?.seconds ?? .nan), PCM \(captured.firstAudioPTS?.seconds ?? .nan)...\(captured.lastAudioPTS?.seconds ?? .nan)")
    }
    print("Attempt \(attempt) delivered \(delivered.width)x\(delivered.height), \(delivered.rate), \(captured.frames) frames, \(captured.declarations) epochs, \(captured.clockUpdates) clock mapping updates")
    print("Signal \(active?.signalDetail ?? "no detail"), device drops \(session.counters.deviceDroppedFrames)")
    await Task.detached { session.stop() }.value
    let stopped = audit.snapshot.callbacks
    try await Task.sleep(for: .milliseconds(350))
    guard audit.snapshot.callbacks == stopped, plugin.status(deviceID: id)?.availability != .inUseHere else {
      throw SmokeFailure("Stopped session still delivered callbacks or held its device")
    }
  }
  print("Shipping Mac Camera plugin completed both capture and stop cycles")
}

do {
  try await run()
} catch {
  fflush(nil)
  FileHandle.standardError.write(Data("Mac Camera hardware smoke failed: \(error)\n".utf8))
  exit(EXIT_FAILURE)
}
