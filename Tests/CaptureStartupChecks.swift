import CoreMedia
import CoreVideo
import XCTest

/// Desktop Video reports a callback's audio while the HDMI input is still
/// locking, before the first frame declares the format. Build 41 stopped
/// Camera 2 at every launch for it.
@objcMembers final class CaptureStartupChecks: XCTestCase {
  func testAudioBeforeTheFirstDeclarationIsSkippedNotFatal() throws {
    let format = try SourceFormat(width: 128, height: 72, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let session = EarlyAudioSession(format: format, audio: audio)
    let feed = FeedID(rawValue: "early-audio")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in session }))
    controller.setCameraOutputEnabled(false)
    defer { controller.onUpdate = nil; controller.stop() }
    let done = expectation(description: "Deliveries handled")
    let stopped = Stopped()
    controller.onUpdate = { update in
      if update.message.contains("refused") { stopped.note(update.message) }
      if update.message == "early-audio done" { done.fulfill() }
    }
    controller.start(feedID: feed, deviceID: "early:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [done], timeout: 3)
    XCTAssertNil(stopped.message, "Audio while the input locks must not stop capture")
    XCTAssertTrue(controller.isAccepting(feedID: feed), "The first declared frame runs as normal")
  }
}

private final class Stopped: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?
  func note(_ message: String) { lock.withLock { value = value ?? message } }
  var message: String? { lock.withLock { value } }
}

/// Media and audio first, then the declarations and a frame, as the DeckLink
/// plugin emits them while the input locks.
private final class EarlyAudioSession: CaptureSession, @unchecked Sendable {
  private let queue = DispatchQueue(label: "Ultracam.EarlyAudio.delivery")
  private let format: SourceFormat
  private let audio: SourceAudioFormat
  init(format: SourceFormat, audio: SourceAudioFormat) { self.format = format; self.audio = audio }
  var counters: CaptureCounters { CaptureCounters() }
  func stop() { queue.sync {} }
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws {
    var image: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary,
      &image) == kCVReturnSuccess, let image else { throw PluginError.unsupported("No fixture image") }
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 1)
    let bindings = CaptureClockBindings(video: ClockInstanceID(), audio: nil)
    let undeclared = CaptureEpochID(sessionID: epoch.sessionID, epoch: 0)
    let samples = Data(count: 8 * audio.channels * 4)
    let payloads: [(CaptureEpochID, String, CaptureDelivery.Payload)] = [
      (undeclared, "", .media(CaptureMediaInfo(timecode: nil, pairedFrameSequence: nil, audioDeclaration: .present(audio),
        audioPacketTime: CMTime(value: 0, timescale: 48000), audioClockInstance: nil, sampleFrameCount: 8,
        byteCount: samples.count, peaks: [0, 0], rms: [0, 0]))),
      (undeclared, "", .rawAudio(try CaptureAudioPacket(planes: [samples], sampleFrameCount: 8, format: audio,
        packetTime: CMTime(value: 0, timescale: 48000)))),
      (epoch, format.signature, .event(.formatChanged(format))),
      (epoch, format.signature, .event(.audioFormatChanged(.present(audio)))),
      (epoch, format.signature, .frame(CapturedPixelBuffer(immutable: image), CaptureFrameInfo(epochID: epoch,
        formatSignature: format.signature, presentationTime: CMTime(value: 20, timescale: 1),
        duration: VideoContract.fastDuration, signalValid: true, timecode: nil))),
      (epoch, format.signature, .event(.info("early-audio done")))
    ]
    queue.async {
      for (sequence, (epochID, signature, payload)) in payloads.enumerated() {
        handlers.deliver(CaptureDelivery(sequence: UInt64(sequence + 1), epochID: epochID, formatSignature: signature,
          clockBindings: bindings, mappingRevision: 0, payload: payload))
      }
    }
  }
}
