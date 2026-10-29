#if ULTRACAM_TEST_SUPPORT
import Foundation
import CoreMedia
import XCTest

@MainActor @objcMembers final class SyntheticCaptureFixtureChecks: XCTestCase {
  func testDefaultRateAndAudioSampleBoundariesStayAligned() throws {
    let fixture = try AppHardwareSyntheticFixture()
    defer { fixture.stop() }
    XCTAssertEqual(fixture.format.rate, .constant(VideoContract.fastDuration))
    let session = fixture.plugin.makeSession() as! FakeCaptureSession
    let captured = FixturePackets()
    try session.start(deviceID: "fake:fixture", timing: .automatic, handlers: CaptureHandlers(deliver: { captured.append($0) }))
    let pattern = try fixture.makePattern()
    for index in 0..<100 { XCTAssertEqual(try fixture.emit(pattern, index: Int32(index)), 1) }
    session.stop()
    XCTAssertEqual(captured.frames[60].timecode?.seconds, 1)
    XCTAssertEqual(captured.frames[60].timecode?.frames, 0)
    let packets = captured.packets
    XCTAssertEqual(packets.count, 100)
    XCTAssertEqual(Array(try XCTUnwrap(packets.first?.planes.first).prefix(8)), [0, 0, 0, 32, 0, 0, 0, 16])
    let expected = Int64(floor(VideoContract.fastDuration.seconds * 100 * 48000))
    XCTAssertEqual(packets.reduce(Int64(0)) { $0 + Int64($1.sampleFrameCount) }, expected)
    for (index, packet) in packets.enumerated() {
      let expectedStart = Int64(index) * 8008 / 10
      XCTAssertEqual(packet.packetTime, CMTime(value: expectedStart, timescale: 48000))
      XCTAssertEqual(packet.planes.first?.count, packet.sampleFrameCount * 8)
    }
  }
}
private final class FixturePackets: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CaptureAudioPacket] = []
  private var frameStorage: [CaptureFrameInfo] = []
  func append(_ value: CaptureDelivery) {
    lock.withLock {
      if case .rawAudio(let packet) = value.payload { storage.append(packet) }
      if case .frame(_, let info) = value.payload { frameStorage.append(info) }
    }
  }
  var frames: [CaptureFrameInfo] { lock.withLock { frameStorage } }
  var packets: [CaptureAudioPacket] { lock.withLock { storage } }
}
#endif
