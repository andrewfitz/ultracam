import AudioToolbox
import CoreMedia
import Foundation
import XCTest

@objcMembers final class MacCameraAudioChecks: XCTestCase {
  func testMacCameraMicrophonePreservesNativePCM() throws {
    for (rate, channels, interleaved) in [(44_100.0, 1, true), (48_000.0, 2, false), (48_000.0, 2, true)] {
      let labels = channels == 1 ? [kAudioChannelLabel_Mono] : [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
      let format = try SourceAudioFormat(sampleRate: rate, channels: channels, sample: .float32,
        interleaved: interleaved, layout: AudioChannelMap(labels: labels), clock: .deviceClock)
      let values: [[Float]] = channels == 1 ? [[0.25, 0.5]]
        : interleaved ? [[0.25, -0.25, 0.5, -0.5]] : [[0.25, 0.5], [-0.25, -0.5]]
      let planes = values.map { $0.withUnsafeBytes { Data($0) } }
      let pts = CMTime(value: 9_000_001, timescale: 48_000)
      let packet = try MacCameraAudio.readPacket(makeSourceSample(planes: planes, sampleFrameCount: 2,
        format: format, presentationTime: pts))

      XCTAssertEqual(packet.format, format)
      XCTAssertEqual(packet.packetTime, pts)
      XCTAssertEqual(packet.sampleFrameCount, 2)
      XCTAssertEqual(packet.planes, planes)
      XCTAssertNil(packet.pairedFrameSequence)
    }
  }

  func testMacCameraMicrophonePreservesDiscreteMultichannelPCM() throws {
    let channels = 4
    let format = try SourceAudioFormat(sampleRate: 48_000, channels: channels, sample: .int16,
      interleaved: true, layout: AudioChannelMap(), clock: .deviceClock)
    let planes = [[Int16](1...8).withUnsafeBytes { Data($0) }]
    let packet = try MacCameraAudio.readPacket(makeSourceSample(planes: planes, sampleFrameCount: 2,
      format: format, presentationTime: .zero))

    XCTAssertEqual(packet.format, format)
    XCTAssertEqual(packet.planes, planes)
  }

  func testMacCameraMicrophoneFormatCacheTracksLayoutRateAndClock() throws {
    let input = MacCameraAudio(selection: nil)
    let left = kAudioChannelLabel_Left
    let right = kAudioChannelLabel_Right
    func format(_ rate: Double, _ labels: [UInt32], clock: AudioClockDomain = .deviceClock) throws -> SourceAudioFormat {
      try SourceAudioFormat(sampleRate: rate, channels: 2, sample: .float32, interleaved: true,
        layout: AudioChannelMap(labels: labels), clock: clock)
    }
    func sample(_ format: SourceAudioFormat, frames: Int, at pts: CMTime) throws -> (CMSampleBuffer, [Data]) {
      let values = (1...(frames * 2)).map(Float.init)
      let planes = [values.withUnsafeBytes { Data($0) }]
      return (try makeSourceSample(planes: planes, sampleFrameCount: frames, format: format, presentationTime: pts), planes)
    }

    let stereo = try format(48_000, [left, right])
    let (first, firstPlanes) = try sample(stereo, frames: 2, at: .zero)
    let firstPacket = try input.packet(from: first)
    XCTAssertEqual(firstPacket.format, stereo)
    XCTAssertEqual(try input.packet(from: first).planes, firstPlanes)

    let nextPTS = CMTime(value: 2, timescale: 48_000)
    let (next, nextPlanes) = try sample(stereo, frames: 3, at: nextPTS)
    let nextPacket = try input.packet(from: next)
    XCTAssertEqual(nextPacket.format, stereo)
    XCTAssertEqual(nextPacket.packetTime, nextPTS)
    XCTAssertEqual(nextPacket.sampleFrameCount, 3)
    XCTAssertEqual(nextPacket.planes, nextPlanes)
    XCTAssertEqual(try input.packet(from: next, clock: .hostTime).format, try format(48_000, [left, right], clock: .hostTime))
    XCTAssertEqual(try input.packet(from: next).format, stereo)

    let reverseStereo = try format(48_000, [right, left])
    let (reordered, _) = try sample(reverseStereo, frames: 2, at: nextPTS)
    XCTAssertEqual(try input.packet(from: reordered).format, reverseStereo)
    let differentRate = try format(44_100, [right, left])
    let (changed, _) = try sample(differentRate, frames: 2, at: nextPTS)
    XCTAssertEqual(try input.packet(from: changed).format, differentRate)
    XCTAssertEqual(firstPacket.planes, firstPlanes)
  }

  func testMacCameraMicrophoneDetectsGapsAndClockResets() throws {
    let format = try SourceAudioFormat(sampleRate: 48_000, channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .deviceClock)
    func packet(at milliseconds: Int64) throws -> CaptureAudioPacket {
      try CaptureAudioPacket(ownedInterleavedPCM: Data(count: 480 * 4), sampleFrameCount: 480,
        format: format, packetTime: CMTime(value: milliseconds, timescale: 1_000))
    }
    var timeline = MacCameraAudioTimeline()
    XCTAssertEqual(timeline.ingest(try packet(at: 0)), .continuous)
    XCTAssertEqual(timeline.ingest(try packet(at: 10)), .continuous)
    XCTAssertEqual(timeline.ingest(try packet(at: 40)), .continuous)
    XCTAssertEqual(timeline.ingest(try packet(at: 110)), .gap)
    XCTAssertEqual(timeline.ingest(try packet(at: 25)), .reset)
    timeline.reset()
    XCTAssertEqual(timeline.ingest(try packet(at: 0)), .continuous)
  }

  func testMacCameraMicrophoneClaimsAndSavedIdentity() {
    let claims = MacMicrophoneClaims()
    XCTAssertTrue(claims.claim("USB:1"))
    XCTAssertFalse(claims.claim("USB:1"))
    XCTAssertTrue(claims.claim("USB:2"))
    claims.release("USB:1")
    XCTAssertTrue(claims.claim("USB:1"))
    XCTAssertNil(MacCameraAudio(selection: nil).deviceUID)
    XCTAssertNil(MacCameraAudio(selection: "off").deviceUID)
    XCTAssertEqual(MacCameraAudio(selection: "linked:USB:1").deviceUID, "USB:1")
    XCTAssertEqual(MacCameraAudio(selection: "input:USB:2").deviceUID, "USB:2")
  }
}
