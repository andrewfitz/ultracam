import CoreMedia
import CoreVideo
import XCTest

@objcMembers final class CameraBusyNegotiationChecks: XCTestCase {
  private func format() throws -> CMVideoFormatDescription {
    try VideoContract.formatDescription(width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
  }

  func testBusyMatchingContractAllowedWithoutSetters() throws {
    let format = try format()
    var writes = 0, reads = 0
    try CameraSink.negotiateInstalledContract(format: format, duration: VideoContract.fastDuration,
      controlled: { true }, set: { writes += 1 }, read: {
        reads += 1; return (format, 60_000.0 / 1001)
      })
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(reads, 1)
  }

  func testSuccessfulSetterStillRequiresMatchingReadableContract() throws {
    let format = try format()
    var wrote = false
    XCTAssertThrowsError(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { false }, set: { wrote = true },
      read: { XCTAssertTrue(wrote); return (format, 30_000.0 / 1001) }))
    XCTAssertThrowsError(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { false }, set: {},
      read: { throw VideoError.message("Unreadable") }))
    var changedColour: CMVideoFormatDescription?
    let tags = NSMutableDictionary(dictionary: try XCTUnwrap(CMFormatDescriptionGetExtensions(format)) as NSDictionary)
    tags[kCMFormatDescriptionExtension_ColorPrimaries] = kCVImageBufferColorPrimaries_ITU_R_2020
    XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil,
      codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 1920, height: 1080,
      extensions: tags as CFDictionary, formatDescriptionOut: &changedColour), noErr)
    let other = try XCTUnwrap(changedColour)
    XCTAssertThrowsError(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { false }, set: {},
      read: { (other, 60_000.0 / 1001) }))
    XCTAssertNoThrow(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { false }, set: {},
      read: { (format, 60_000.0 / 1001) }))
  }

  func testBusyUnsupportedCadenceRefused() throws {
    let format = try format()
    XCTAssertThrowsError(try CameraSink.negotiateInstalledContract(format: format,
      duration: CMTime(value: 1, timescale: 90), controlled: { true }, set: {},
      read: { (format, 60_000.0 / 1001) }))
    XCTAssertEqual(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { true }, set: {},
      read: { (format, 59.94) }), .firstSampleDecides,
      "Decimal approximation doesn't pass as the exact NTSC rational: the first sample sets it")
    XCTAssertThrowsError(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { false }, set: {},
      read: { (format, 59.94) }), "With nobody else holding the device, what was set has to stick")
  }

  func testControlAcquiredDuringSetterRequiresReadback() throws {
    let format = try format()
    var busy = false
    XCTAssertThrowsError(try CameraSink.negotiateInstalledContract(format: format,
      duration: CMTime(value: 1, timescale: 90), controlled: { busy }, set: {
        busy = true; throw VideoError.message("Device control changed")
      }, read: { (format, 60_000.0 / 1001) }))
    busy = false
    XCTAssertNoThrow(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { busy }, set: {
        busy = true; throw VideoError.message("Device control changed")
      }, read: { (format, 60_000.0 / 1001) }))
  }

  /// A client that got here first must not be left on black because it picked another
  /// format: the sink connects, and its first sample renegotiates inside the extension.
  func testBusyFormatMismatchConnectsAndUnreadableContractStaysRefused() throws {
    let format = try format()
    let other = try VideoContract.formatDescription(width: 3840, height: 2160,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    var writes = 0
    XCTAssertEqual(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { true }, set: { writes += 1 },
      read: { (other, 60_000.0 / 1001) }), .firstSampleDecides)
    XCTAssertEqual(writes, 0, "Its lease isn't ours to break")
    XCTAssertEqual(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { true }, set: {},
      read: { (format, 60_000.0 / 1001) }), .agreed)
    XCTAssertThrowsError(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { true }, set: {},
      read: { throw VideoError.message("No installed cadence readback") }))
  }
}
