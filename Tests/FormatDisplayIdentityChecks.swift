import CoreMedia
import XCTest

@objcMembers final class FormatDisplayIdentityTests: XCTestCase {
  func testStableHumanReadableIdentity() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      colour: .rec709Video, rate: .constant(CMTime(value: 1001, timescale: 60000)))
    let identity = FormatDisplayIdentity(format)
    XCTAssertEqual(identity.resolution, "UHD 3840 × 2160")
    XCTAssertEqual(identity.aspect, "16:9")
    XCTAssertEqual(identity.colour, "Rec. 709")
    XCTAssertEqual(identity.transfer, "Rec. 709")
    XCTAssertEqual(identity.range, "Video range")
    XCTAssertEqual(identity.pixel, "10-bit 4:2:2 packed")
    XCTAssertEqual(identity.name, "UHD 3840 × 2160 · 59.94 fps · 16:9")
    XCTAssertFalse(identity.detail.contains("clock"))
    XCTAssertFalse(identity.detail.contains("UUID"))
  }

  func testExactCadenceAndVariableWording() throws {
    for (scale, expected) in [(24000, "23.976 fps"), (30000, "29.97 fps"), (60000, "59.94 fps")] {
      let source = try SourceFormat(width: 1920, height: 1080, pixel: .v210,
        rate: .constant(CMTime(value: 1001, timescale: Int32(scale))))
      XCTAssertEqual(FormatDisplayIdentity(source).frameRate, expected)
    }
    let source = try SourceFormat(width: 1920, height: 1080, pixel: .v210,
      rate: .variable(nominal: CMTime(value: 1, timescale: 30), shortest: CMTime(value: 1, timescale: 60), longest: CMTime(value: 1, timescale: 24)))
    XCTAssertEqual(FormatDisplayIdentity(source).frameRate, "Variable (30 fps nominal)")
  }

  func testUYVAHasPacked422SignalSampling() throws {
    let format = try SourceFormat(width: 1920, height: 1080, pixel: .uyva,
      rate: .constant(CMTime(value: 1, timescale: 30)))
    XCTAssertTrue(FormatDisplayIdentity(format).pixel.contains("4:2:2"))
    XCTAssertFalse(FormatDisplayIdentity(format).pixel.contains("4:4:4"))
  }

  func testAspectAndTransferWording() throws {
    let aspect = try Rational(4, 3)
    let colour = Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020,
      range: .full, horizontalChromaSiting: .center, verticalChromaSiting: .center)
    let format = try SourceFormat(width: 1440, height: 1080, pixelAspect: aspect,
      pixel: .v210, colour: colour, rate: .constant(CMTime(value: 1, timescale: 24)))
    let identity = FormatDisplayIdentity(format)
    XCTAssertEqual(identity.aspect, "16:9")
    XCTAssertEqual(identity.colour, "Rec. 2020")
    XCTAssertEqual(identity.transfer, "PQ")
    XCTAssertEqual(identity.range, "Full range")
  }
}

@MainActor
@objcMembers final class StructuredFormatUILabelTests: XCTestCase {
  func testSourceTimecodeTitleDescribesNativePreservation() {
    XCTAssertEqual(UITimecode.title(.source), "Source timecode")
    XCTAssertFalse(RecordingTimecodeMode.source.help.lowercased().contains("no timecode track"))
  }

  func testDeclaredFormatOverridesLegacyLabelAndRefreshesSnapshot() throws {
    let format = try SourceFormat(width: 1920, height: 1080, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    var update = CaptureUpdate(message: "")
    update.input = "stale legacy label"
    update.sourceFormat = format
    let expected = UISignal.live(format: FormatDisplayIdentity(format).detail)
    XCTAssertEqual(UIFormatLabels.signal(running: true, deviceAvailable: true, update: update), expected)
    var camera = UICameraSnapshot(id: "test", name: "Camera")
    camera.running = true
    camera.deviceAvailable = true
    UISessionBridge.applyCapture(update, to: &camera)
    XCTAssertEqual(camera.signal, expected)
    XCTAssertEqual(UIFormatLabels.signal(running: false, deviceAvailable: true, update: update), .none)
  }
}
