#if APP_SOURCE_INTEGRATION_CHECKS
import Foundation
import XCTest

@objcMembers final class AppSourceIntegrationChecks: XCTestCase {
  func testDirectorUsesActivityAcrossAllSourceChannels() {
    let model = IntegrationFixture()
    model.feedAudio(CaptureUpdate(mediaTime: 1, audioPacketTime: 2,
      audioPresent: true, audioActivityRMS: 0.75, audioActivityPeak: 0.9))
    XCTAssertEqual(model.autoSwitcherBridge?.rms, 0.75)
    XCTAssertEqual(model.autoSwitcherBridge?.peak, 0.9)
    XCTAssertEqual(model.autoSwitcherBridge?.audioTime, 2)
  }

  func testMissingAudioAdvancesDirectorWithoutInventingActivity() {
    let model = IntegrationFixture()
    model.feedAudio(CaptureUpdate(mediaTime: 3, audioPacketTime: nil,
      audioPresent: false, audioActivityRMS: 0.75, audioActivityPeak: 0.9))
    XCTAssertNil(model.autoSwitcherBridge?.rms)
    XCTAssertEqual(model.autoSwitcherBridge?.tickTime, 3)
    XCTAssertNil(model.autoSwitcherTimeline?.tickTime, "The bridge reports the tick in director order")
  }

  func testInterruptionClearsDirectorAudio() {
    let model = IntegrationFixture()
    model.feedAudio(CaptureUpdate(mediaTime: 1, audioPacketTime: 2,
      audioPresent: true, audioActivityRMS: 0.75, audioActivityPeak: 0.9))
    model.feedAudio(CaptureUpdate(mediaTime: 3, audioPacketTime: nil,
      audioPresent: false, audioActivityRMS: 0.75, audioActivityPeak: 0.9, audioInterrupted: true))
    XCTAssertEqual(model.autoSwitcherBridge?.present, false)
    XCTAssertEqual(model.autoSwitcherBridge?.rms, 0)
    XCTAssertEqual(model.autoSwitcherBridge?.peak, 0)
    XCTAssertEqual(model.autoSwitcherBridge?.audioTime, 3)
  }

  func testAudioRetriesDirectorAfterBackoff() {
    let model = IntegrationFixture()
    model.autoSwitcherBridge = nil
    model.nextDirectorAttempt = ProcessInfo.processInfo.systemUptime + 60
    let update = CaptureUpdate(mediaTime: 1, audioPacketTime: 2,
      audioPresent: true, audioActivityRMS: 0.75, audioActivityPeak: 0.9)

    model.feedAudio(update)
    XCTAssertNil(model.autoSwitcherBridge)

    model.nextDirectorAttempt = .leastNonzeroMagnitude
    model.feedAudio(update)
    XCTAssertEqual(model.autoSwitcherBridge?.audioTime, 2)
    XCTAssertEqual(model.autoSwitcherBridge?.rms, 0.75)
  }

  func testLinkedProcessingCopiesScalingAndKeepsCameraIdentity() {
    let model = IntegrationFixture()
    var source = model.feedDescriptors[0]
    source.scalingMode = "fill"
    source.allowUpscale = true
    source.resizeTarget = "1080p"
    source.programColorSpaceID = "rec2020-hlg"
    model.sync(source)
    XCTAssertEqual(model.feedDescriptors[1].scalingMode, "fill")
    XCTAssertTrue(model.feedDescriptors[1].allowUpscale)
    XCTAssertEqual(model.feedDescriptors[1].resizeTarget, "1080p")
    XCTAssertEqual(model.feedDescriptors[1].programColorSpaceID, "rec2020-hlg")
    XCTAssertEqual(model.feedDescriptors[2].programColorSpaceID, "rec709", "Disabled cameras keep their Program colour choice")
    XCTAssertEqual(model.feedDescriptors[1].selectedDevice, "second-device")
    XCTAssertEqual(model.feedDescriptors[2].scalingMode, "fit", "Disabled cameras keep their processing")
    XCTAssertFalse(model.feedDescriptors[2].allowUpscale)
  }
}
#endif
