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
      duration: CMTime(value: 1, timescale: 120), controlled: { true }, set: {},
      read: { (format, 60_000.0 / 1001) }))
    XCTAssertThrowsError(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { true }, set: {},
      read: { (format, 59.94) }), "Decimal approximation must not pass as the exact NTSC rational")
  }

  func testControlAcquiredDuringSetterRequiresReadback() throws {
    let format = try format()
    var busy = false
    XCTAssertThrowsError(try CameraSink.negotiateInstalledContract(format: format,
      duration: CMTime(value: 1, timescale: 120), controlled: { busy }, set: {
        busy = true; throw VideoError.message("Device control changed")
      }, read: { (format, 60_000.0 / 1001) }))
    busy = false
    XCTAssertNoThrow(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { busy }, set: {
        busy = true; throw VideoError.message("Device control changed")
      }, read: { (format, 60_000.0 / 1001) }))
  }

  func testBusyFormatMismatchAndUnreadableContractRefused() throws {
    let format = try format()
    let other = try VideoContract.formatDescription(width: 3840, height: 2160,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    XCTAssertThrowsError(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { true }, set: {},
      read: { (other, 60_000.0 / 1001) }))
    XCTAssertThrowsError(try CameraSink.negotiateInstalledContract(format: format,
      duration: VideoContract.fastDuration, controlled: { true }, set: {},
      read: { throw VideoError.message("No installed cadence readback") }))
  }
}
