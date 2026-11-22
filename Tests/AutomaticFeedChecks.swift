import CoreMedia
import CoreVideo
import XCTest

@objcMembers final class AutomaticFeedChecks: XCTestCase {
  func testProgramBypassPreservesDeclaredGeometryAndCadence() throws {
    var saved = PipelineConfiguration(applyLUT: true, downscale: true,
      convertTo420: true, reduceFrameRate: true)
    saved.sourceWidth = 4096
    saved.sourceHeight = 2160
    saved.sourcePixelAspect = try Rational(4, 3)
    saved.sourceDuration = CMTime(value: 1, timescale: 25)
    let detected = CMTime(value: 1001, timescale: 24_000)
    let bypass = FeedLifecycleDemandPolicy.programContract(configuration: saved,
      pipelineEnabled: false, detectedSourceDuration: detected)
    XCTAssertEqual(bypass.sourceWidth, saved.sourceWidth)
    XCTAssertEqual(bypass.sourceHeight, saved.sourceHeight)
    XCTAssertEqual(bypass.sourcePixelAspect, saved.sourcePixelAspect)
    XCTAssertEqual(bypass.sourceDuration, detected)
    XCTAssertEqual(bypass.duration, detected)
    XCTAssertFalse(bypass.applyLUT || bypass.downscale || bypass.convertTo420 || bypass.reduceFrameRate)
    let retained = FeedLifecycleDemandPolicy.programContract(configuration: saved,
      pipelineEnabled: true, detectedSourceDuration: nil)
    XCTAssertEqual(retained, saved)
  }

  func testProgramContractAcceptsExactSourceDurationsWithoutTwoRateInference() {
    let durations = [CMTime(value: 1001, timescale: 24_000),
      CMTime(value: 1, timescale: 25), CMTime(value: 1001, timescale: 120_000)]
    for duration in durations {
      let result = FeedLifecycleDemandPolicy.programContract(configuration: .init(),
        pipelineEnabled: false, detectedSourceDuration: duration)
      XCTAssertEqual(result.sourceDuration, duration)
      XCTAssertEqual(result.duration, duration)
    }
  }

  func testProgramUsesDeclaredPixelFormatAndChoosesItsOwnCanvasForSmallSource() throws {
    let duration = CMTime(value: 1, timescale: 30)
    let native = try SourceFormat(width: 1280, height: 720, pixel: .video420, rate: .constant(duration))
    let compatible = FeedLifecycleDemandPolicy.programContract(configuration: .init(), pipelineEnabled: false,
      detectedSourceDuration: nil, source: native)
    XCTAssertFalse(compatible.downscale)
    XCTAssertEqual(compatible.width, 1280)
    XCTAssertEqual(compatible.height, 720)
    XCTAssertEqual(compatible.duration, duration)
    let declaredPixel = try XCTUnwrap(compatible.sourcePixelFormat)
    XCTAssertEqual(ProgramOutputFormat(configuration: compatible, passthroughFormat: declaredPixel).pixelFormat,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

    let small = try SourceFormat(width: 640, height: 480, pixel: .video420, rate: .constant(duration))
    let program = FeedLifecycleDemandPolicy.programContract(configuration: .init(), pipelineEnabled: false,
      detectedSourceDuration: nil, source: small)
    XCTAssertTrue(program.downscale)
    XCTAssertEqual(program.resolvedResizeTarget, .hd720)
    XCTAssertEqual(program.resolvedSourceWidth, 640)
    XCTAssertEqual(program.resolvedSourceHeight, 480)
    XCTAssertEqual(program.scalingMode, .fit)
    XCTAssertFalse(program.allowUpscale)
  }

  func testProgramContractRejectsInvalidDetectedCadenceAndRetainsDeclaredDuration() {
    var configuration = PipelineConfiguration()
    configuration.sourceDuration = CMTime(value: 1, timescale: 25)
    for invalid in [CMTime.invalid, .zero, .indefinite, CMTime(value: -1, timescale: 30)] {
      let result = FeedLifecycleDemandPolicy.programContract(configuration: configuration,
        pipelineEnabled: false, detectedSourceDuration: invalid)
      XCTAssertEqual(result.sourceDuration, configuration.sourceDuration)
    }
  }

  func testUnboundPipelineUsesExplicitProvisionalDurationUntilDeclarationArrives() {
    var configuration = PipelineConfiguration()
    XCTAssertNil(configuration.sourceDuration)
    XCTAssertEqual(configuration.duration, VideoContract.provisionalSourceDuration)
    configuration.sourceDuration = CMTime(value: 1, timescale: 25)
    XCTAssertEqual(configuration.duration, CMTime(value: 1, timescale: 25))
  }

  func testNoCaptureWithoutCameraOrVisiblePreviewDemand() {
    var policy = AutomaticFeedPolicy()
    XCTAssertNil(policy.action(ready: true, running: false))
    XCTAssertEqual(policy.action(ready: true, running: true), .stop)
  }

  func testVisiblePreviewStartsWithoutACameraAppAndHidingStops() {
    var policy = AutomaticFeedPolicy()
    policy.previewDemand(true)
    XCTAssertFalse(policy.requested, "Local preview must not pretend a camera client is connected")
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
    policy.previewDemand(false)
    XCTAssertEqual(policy.action(ready: true, running: true), .stop)
    policy.previewDemand(true)
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
  }

  func testPreviewAndCameraDemandKeepEachOtherAlive() {
    var policy = AutomaticFeedPolicy()
    policy.previewDemand(true)
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
    policy.demand(true)
    policy.previewDemand(false)
    XCTAssertNil(policy.action(ready: true, running: true), "Hiding preview must preserve camera output")
    policy.previewDemand(true)
    policy.demand(false)
    XCTAssertNil(policy.action(ready: true, running: true), "Closing a camera app must preserve visible preview")
    policy.previewDemand(false)
    XCTAssertEqual(policy.action(ready: true, running: true), .stop)
  }

  func testFailedPreviewStartDoesNotRetryUntilNewDemandSession() {
    var policy = AutomaticFeedPolicy()
    policy.previewDemand(true)
    XCTAssertNil(policy.action(ready: false, running: false))
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
    policy.previewDemand(true)
    policy.demand(true)
    policy.demand(false)
    XCTAssertNil(policy.action(ready: true, running: false))
    policy.previewDemand(false)
    policy.previewDemand(true)
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
  }

  func testACameraClientCanHandOffToPreviewWithoutRearmingAnAttempt() {
    var policy = AutomaticFeedPolicy()
    policy.updateDemand(requested: true, previewRequested: false)
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
    policy.updateDemand(requested: false, previewRequested: true)
    XCTAssertNil(policy.action(ready: true, running: false))
  }

  func testWaitsForLUTAndStartsOncePerSession() {
    var policy = AutomaticFeedPolicy()
    policy.demand(true)
    XCTAssertNil(policy.action(ready: false, running: false))
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
    policy.demand(true)
    XCTAssertNil(policy.action(ready: true, running: true))
    XCTAssertNil(policy.action(ready: true, running: false), "Failed start must not spin on repeated notifications")
    policy.retry()
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
  }

  func testStopWhileLoadingAndNewSessionRecovery() {
    var policy = AutomaticFeedPolicy()
    policy.demand(true)
    policy.demand(false)
    XCTAssertNil(policy.action(ready: true, running: false), "Closed request cannot start after LUT finishes")
    policy.demand(true)
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
    policy.demand(false)
    XCTAssertEqual(policy.action(ready: false, running: true), .stop)
    policy.demand(true)
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
  }
}
