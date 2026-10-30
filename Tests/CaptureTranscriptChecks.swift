#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import Foundation
import XCTest

@objcMembers final class CaptureTranscriptChecks: XCTestCase {
  func testCPUVideoRequiresBothDeclarationsAndMatchingFrameContext() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(CMTime(value: 1, timescale: 30)))
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 0)
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 4)
    defer { pointer.deallocate() }
    let memory = CapturedCPUMemoryFrame(pointer: pointer, width: 1, height: 1, bytesPerRow: 4,
      allocation: NoCopyIngestAllocation(baseAddress: pointer, length: 4, generation: 1), inspectVM: { _, _ in nil }, frameOwner: NSObject())
    let bindings = CaptureClockBindings(video: ClockInstanceID(), audio: nil)
    func delivery(_ sequence: UInt64, _ payload: CaptureDelivery.Payload) -> CaptureDelivery {
      CaptureDelivery(sequence: sequence, epochID: epoch, formatSignature: format.signature,
        clockBindings: bindings, mappingRevision: 0, payload: payload)
    }
    let info = CaptureFrameInfo(epochID: epoch, formatSignature: format.signature, presentationTime: .zero,
      duration: CMTime(value: 1, timescale: 30), signalValid: true, timecode: nil)
    var missing = PluginConformanceHarness.Transcript()
    XCTAssertThrowsError(try missing.accept(delivery(1, .cpuMemory(memory, info))))
    var missingAudio = PluginConformanceHarness.Transcript()
    try missingAudio.accept(delivery(1, .event(.formatChanged(format))))
    XCTAssertThrowsError(try missingAudio.accept(delivery(2, .cpuMemory(memory, info))))
    for audio in [SourceAudioDeclaration.absent, .unknown] {
      var valid = PluginConformanceHarness.Transcript()
      try valid.accept(delivery(1, .event(.formatChanged(format))))
      try valid.accept(delivery(2, .event(.audioFormatChanged(audio))))
      XCTAssertNoThrow(try valid.accept(delivery(3, .cpuMemory(memory, info))))
    }
    let audioFormat = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let packet = try CaptureAudioPacket(planes: [Data(count: 8)], sampleFrameCount: 1,
      format: audioFormat, packetTime: .zero)
    var audioMissing = PluginConformanceHarness.Transcript()
    try audioMissing.accept(delivery(1, .event(.formatChanged(format))))
    XCTAssertThrowsError(try audioMissing.accept(delivery(2, .rawAudio(packet))))
    var audioPresent = PluginConformanceHarness.Transcript()
    try audioPresent.accept(delivery(1, .event(.formatChanged(format))))
    try audioPresent.accept(delivery(2, .event(.audioFormatChanged(.present(audioFormat)))))
    XCTAssertNoThrow(try audioPresent.accept(delivery(3, .rawAudio(packet))))
    let badInfo = CaptureFrameInfo(epochID: epoch, formatSignature: "wrong", presentationTime: .invalid,
      duration: .zero, signalValid: true, timecode: nil)
    XCTAssertThrowsError(try audioPresent.accept(delivery(4, .cpuMemory(memory, badInfo))))
    let nextEpoch = CaptureEpochID(sessionID: epoch.sessionID, epoch: 1)
    let nextDeclaration = CaptureDelivery(sequence: 5, epochID: nextEpoch, formatSignature: format.signature,
      clockBindings: CaptureClockBindings(video: ClockInstanceID(), audio: nil), mappingRevision: 0,
      payload: .event(.formatChanged(format)))
    try audioPresent.accept(nextDeclaration)
    let nextInfo = CaptureFrameInfo(epochID: nextEpoch, formatSignature: format.signature, presentationTime: .zero,
      duration: CMTime(value: 1, timescale: 30), signalValid: true, timecode: nil)
    XCTAssertThrowsError(try audioPresent.accept(CaptureDelivery(sequence: 6, epochID: nextEpoch,
      formatSignature: format.signature, clockBindings: nextDeclaration.clockBindings, mappingRevision: 0,
      payload: .cpuMemory(memory, nextInfo))))
    let session = FakeCaptureSession(format: format)
    try session.start(deviceID: "fake:fixture", timing: .automatic, handlers: CaptureHandlers(deliver: { _ in }))
    defer { session.stop() }
    XCTAssertFalse(session.submit(.cpuMemory(memory, info))) // wrong session epoch
  }
  func testEpochFreezesVideoAudioAndClockContracts() throws {
    let first = try SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(CMTime(value: 1, timescale: 30)))
    let second = try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(CMTime(value: 1, timescale: 30)))
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 0)
    let next = CaptureEpochID(sessionID: epoch.sessionID, epoch: 1)
    let bindings = CaptureClockBindings(video: ClockInstanceID(), audio: nil)
    let replacement = CaptureClockBindings(video: ClockInstanceID(), audio: nil)
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    func delivery(_ sequence: UInt64, _ payload: CaptureDelivery.Payload,
                  format: SourceFormat? = nil, epochID: CaptureEpochID? = nil,
                  clocks: CaptureClockBindings? = nil) -> CaptureDelivery {
      CaptureDelivery(sequence: sequence, epochID: epochID ?? epoch, formatSignature: (format ?? first).signature,
        clockBindings: clocks ?? bindings, mappingRevision: 0, payload: payload)
    }
    func declared() throws -> PluginConformanceHarness.Transcript {
      var transcript = PluginConformanceHarness.Transcript()
      try transcript.accept(delivery(1, .event(.formatChanged(first))))
      try transcript.accept(delivery(2, .event(.audioFormatChanged(.absent))))
      return transcript
    }
    var video = try declared()
    XCTAssertThrowsError(try video.accept(delivery(3, .event(.formatChanged(second)), format: second)))
    var resolvedAudio = try declared()
    XCTAssertThrowsError(try resolvedAudio.accept(delivery(3, .event(.audioFormatChanged(.present(audio))))))
    var unresolvedAgain = try declared()
    XCTAssertThrowsError(try unresolvedAgain.accept(delivery(3, .event(.audioFormatChanged(.unknown)))))
    var clockDeclaration = try declared()
    XCTAssertThrowsError(try clockDeclaration.accept(delivery(3, .event(.formatChanged(first)), clocks: replacement)))
    var clockEnvelope = try declared()
    XCTAssertThrowsError(try clockEnvelope.accept(delivery(3, .event(.info("changed clock")), clocks: replacement)))
    var signatureEnvelope = try declared()
    XCTAssertThrowsError(try signatureEnvelope.accept(delivery(3, .event(.info("changed signature")), format: second)))
    var identical = try declared()
    XCTAssertNoThrow(try identical.accept(delivery(3, .event(.formatChanged(first)))))
    XCTAssertNoThrow(try identical.accept(delivery(4, .event(.audioFormatChanged(.absent)))))
    for resolved in [SourceAudioDeclaration.absent, .present(audio)] {
      var discovery = PluginConformanceHarness.Transcript()
      try discovery.accept(delivery(1, .event(.formatChanged(first))))
      try discovery.accept(delivery(2, .event(.audioFormatChanged(.unknown))))
      XCTAssertNoThrow(try discovery.accept(delivery(3, .event(.audioFormatChanged(resolved)))))
    }
    var fresh = try declared()
    try fresh.accept(delivery(3, .event(.formatChanged(second)), format: second, epochID: next, clocks: replacement))
    let packet = try CaptureAudioPacket(planes: [Data(count: 8)], sampleFrameCount: 1, format: audio, packetTime: .zero)
    XCTAssertThrowsError(try fresh.accept(delivery(4, .rawAudio(packet), format: second, epochID: next, clocks: replacement)))
    try fresh.accept(delivery(5, .event(.audioFormatChanged(.present(audio))), format: second, epochID: next, clocks: replacement))
    XCTAssertNoThrow(try fresh.accept(delivery(6, .rawAudio(packet), format: second, epochID: next, clocks: replacement)))
  }

}
#endif
