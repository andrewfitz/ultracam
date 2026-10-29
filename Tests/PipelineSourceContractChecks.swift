import CoreMedia
import XCTest

@objcMembers final class PipelineSourceContractChecks: XCTestCase {
  func testAllFrameRateTargetsHaveExactStableCadences() throws {
    XCTAssertEqual(Array(FrameRateTarget.allCases.prefix(8)).map(\.rawValue),
      ["fps60", "fps5994", "fps50", "fps30", "fps2997", "fps25", "fps24", "fps23976"])
    let expected: [(FrameRateTarget, Int64, Int32)] = [(.fps60, 1, 60), (.fps5994, 1001, 60000),
      (.fps50, 1, 50), (.fps30, 1, 30), (.fps2997, 1001, 30000), (.fps25, 1, 25),
      (.fps24, 1, 24), (.fps23976, 1001, 24000), (.fps47952, 1001, 48000),
      (.fps48, 1, 48), (.fps100, 1, 100), (.fps11988, 1001, 120000), (.fps120, 1, 120)]
    XCTAssertEqual(FrameRateTarget.allCases.count, expected.count)
    for (target, value, scale) in expected {
      XCTAssertEqual(target.duration.value, value)
      XCTAssertEqual(target.duration.timescale, scale)
      XCTAssertEqual(try JSONDecoder().decode(FrameRateTarget.self, from: JSONEncoder().encode(target)), target)
    }
  }

  func testDeclaredLUTOutputIsOptionalAndRetainsCompleteColourIdentity() {
    var configuration = PipelineConfiguration()
    XCTAssertNil(configuration.lutOutputColorimetry)
    let pq = Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
    configuration.applyLUT = true
    configuration.lutOutputColorimetry = pq
    XCTAssertEqual(configuration.lutOutputColorimetry, pq)
    XCTAssertFalse(configuration.untouched)
    var other = configuration; other.lutOutputColorimetry = .rec709Video
    XCTAssertNotEqual(configuration, other)
  }

  func testManualColourInterpretationIsOptionalAndRequiresProcessing() {
    var configuration = PipelineConfiguration(downscale: false, convertTo420: false)
    XCTAssertNil(configuration.sourceColorimetryOverride)
    XCTAssertTrue(configuration.untouched)
    configuration.sourceColorimetryOverride = .rec709Video
    XCTAssertEqual(configuration.sourceColorimetryOverride, .rec709Video)
    XCTAssertFalse(configuration.untouched, "Even matching tags require interpretation to be checked against the physical source")
    XCTAssertNotEqual(configuration, PipelineConfiguration(downscale: false, convertTo420: false))
    configuration.sourceColorimetryOverride = nil
    XCTAssertTrue(configuration.untouched)
  }

  func testScalingModeDefaultsToFitAndPreservesCodableIdentity() throws {
    var configuration = PipelineConfiguration()
    XCTAssertEqual(configuration.scalingMode, .fit)
    configuration.scalingMode = .crop
    XCTAssertNotEqual(configuration, PipelineConfiguration())
    XCTAssertEqual(try JSONDecoder().decode(ProgramScalingMode.self,
      from: JSONEncoder().encode(configuration.scalingMode)), .crop)
  }

  func testLegacyDefaultsRemainCompatible() {
    let configuration = PipelineConfiguration(downscale: false, convertTo420: false)
    XCTAssertEqual(configuration.width, 3840)
    XCTAssertEqual(configuration.height, 2160)
    XCTAssertEqual(configuration.duration, VideoContract.fastDuration)
    XCTAssertTrue(configuration.untouched)
  }

  func testSourceGeometryAndTimingReplaceLegacyFallback() throws {
    let configuration = PipelineConfiguration(downscale: false, convertTo420: false,
      sourceWidth: 1440, sourceHeight: 1080, sourceDuration: CMTime(value: 1, timescale: 25),
      sourcePixelAspect: try Rational(4, 3))
    XCTAssertEqual(configuration.width, 1440)
    XCTAssertEqual(configuration.height, 1080)
    XCTAssertEqual(configuration.duration, CMTime(value: 1, timescale: 25))
    XCTAssertFalse(configuration.untouched, "Non-square pixels need aspect conversion")
  }

  func testSourceTargetMapsPortraitToPublishedCanvas() {
    let configuration = PipelineConfiguration(convertTo420: false, resizeTarget: .source,
      sourceWidth: 1080, sourceHeight: 1920)
    XCTAssertEqual(configuration.width, 1920)
    XCTAssertEqual(configuration.height, 1080)
    XCTAssertFalse(configuration.untouched)
  }

  func testSourceSizeSelectionUsesOnlyPublishedCanvases() throws {
    for target in [ResizeTarget.hd720, .hd1080, .uhd4K, .dci4K] {
      XCTAssertEqual(try PublishedSourceSizeSelection.nearest(width: target.width, height: target.height), target)
    }
    XCTAssertEqual(try PublishedSourceSizeSelection.nearest(width: 128, height: 72), .hd720)
    XCTAssertEqual(try PublishedSourceSizeSelection.nearest(width: 479, height: 641), .hd720)
    XCTAssertEqual(try PublishedSourceSizeSelection.nearest(width: 1560, height: 960), .hd720,
      "Equal area and aspect distances keep stable catalog order")
    XCTAssertThrowsError(try PublishedSourceSizeSelection.nearest(width: Int.max, height: 2))
    XCTAssertThrowsError(try PublishedSourceSizeSelection.nearest(width: 0, height: 1080))
    let native = PipelineConfiguration(downscale: false, resizeTarget: .source,
      sourceWidth: 479, sourceHeight: 641)
    XCTAssertEqual(native.width, 479); XCTAssertEqual(native.height, 641)
    let output = PipelineConfiguration(resizeTarget: .source, sourceWidth: 128, sourceHeight: 72)
    XCTAssertEqual(output.width, 1280); XCTAssertEqual(output.height, 720)
  }

  func testUntouchedComparesActualSizeAndCadence() {
    var configuration = PipelineConfiguration(convertTo420: false, resizeTarget: .uhd4K,
      sourceWidth: 1920, sourceHeight: 1080)
    XCTAssertFalse(configuration.untouched)
    configuration.resizeTarget = .hd1080
    XCTAssertTrue(configuration.untouched)
    configuration.reduceFrameRate = true
    XCTAssertFalse(configuration.untouched)
    configuration.sourceDuration = VideoContract.slowDuration
    XCTAssertTrue(configuration.untouched)
  }

  func testDCITargetHasIndependentHeightAndSourceRateIsNeverRaised() {
    let configuration = PipelineConfiguration(reduceFrameRate: true, resizeTarget: .dci4K,
      frameRateTarget: .fps60, sourceDuration: CMTime(value: 1, timescale: 24))
    XCTAssertEqual(configuration.width, 4096)
    XCTAssertEqual(configuration.height, 2160)
    XCTAssertEqual(configuration.duration, CMTime(value: 1, timescale: 24))
  }
}
