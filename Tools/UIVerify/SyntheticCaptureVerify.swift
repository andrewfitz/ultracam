#if ULTRACAM_TEST_SUPPORT
import Foundation
import CoreMedia
import CoreVideo

@MainActor enum SyntheticCaptureVerify {
  static func run(verifier: Verifier) {
    do {
      let fixture = try AppHardwareSyntheticFixture()
      defer { fixture.stop() }
      let hardware = fixture.hardware
      verifier.check("synthetic discovery starts empty", try hardware.devices().isEmpty)
      fixture.connect()
      verifier.check("synthetic hotplug reaches registry", try hardware.devices().map(\.id) == ["fake:fixture"])
      let services = hardware.captureServices(FeedID(rawValue: "ui-synthetic-capture"))
      let received = Received()
      guard let start = services.startTyped else {
        verifier.check("synthetic route uses typed capture", false)
        return
      }
      try start("fake:fixture", .automatic, CaptureHandlers(deliver: { received.append($0) }))
      let pattern = try fixture.makePattern()
      verifier.check("synthetic input uses IOSurface", CVPixelBufferGetIOSurface(pattern) != nil)
      verifier.check("synthetic input keeps Part A v210", CVPixelBufferGetPixelFormatType(pattern) == kCVPixelFormatType_422YpCbCr10)
      verifier.check("synthetic frame admitted", try fixture.emit(pattern, index: 1) == 1)
      services.stop()
      let values = received.values
      verifier.check("typed synthetic delivery preserves frame/media/PCM group", values.count == 5)
      if values.count == 5 {
        if case .frame(_, let info) = values[2].payload {
          verifier.check("typed frame carries timecode", info.timecode != nil)
        } else { verifier.check("typed synthetic frame delivered", false) }
        if case .media(let media) = values[3].payload {
          verifier.check("typed media preserves audio clock and meters", media.audioPacketTime != nil && media.peaks.count == 2)
        } else { verifier.check("typed synthetic media delivered", false) }
        if case .rawAudio(let packet) = values[4].payload {
          let start = fixture.duration.value * 48000 / Int64(fixture.duration.timescale)
          let end = fixture.duration.value * 2 * 48000 / Int64(fixture.duration.timescale)
          verifier.check("typed synthetic PCM retained", packet.sampleFrameCount == Int(end - start) &&
            packet.packetTime == CMTime(value: start, timescale: 48000) && packet.planes.first?.count == packet.sampleFrameCount * 8)
        } else { verifier.check("typed synthetic audio delivered", false) }
      }
      fixture.disconnect()
      verifier.check("synthetic removal reaches registry", try hardware.devices().isEmpty)
    } catch { verifier.check("typed synthetic capture scenario", false, String(describing: error)) }
  }
  private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CaptureDelivery] = []
    func append(_ value: CaptureDelivery) { lock.withLock { storage.append(value) } }
    var values: [CaptureDelivery] { lock.withLock { storage } }
  }
}
#endif
